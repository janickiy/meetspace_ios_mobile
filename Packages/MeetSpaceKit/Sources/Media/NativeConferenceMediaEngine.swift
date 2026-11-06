#if os(iOS)
import Foundation
import SwiftUI
import UIKit
import Network
import MeetSpaceBroadcast
@preconcurrency import AVFoundation
@preconcurrency import WebRTC

@MainActor final class NativeConferenceMediaEngine: NSObject, ConferenceMediaEngine {
    let events: AsyncStream<ConferenceMediaEvent>
    let localVideoTrackID = "camera-" + UUID().uuidString.lowercased()
    private(set) var localScreenVideoTrackID = "screen-" + UUID().uuidString.lowercased()
    private let continuation: AsyncStream<ConferenceMediaEvent>.Continuation
    private var configuration: ConferenceMediaConfiguration?
    private var peer: NativePeer?
    private var capturer: RTCCameraVideoCapturer?
    private var screenCapturer: RTCVideoCapturer?
    private var screenPool: CVPixelBufferPool?
    private var screenDimensions: (width: Int, height: Int)?
    private var screenSessionID: UUID?
    private var screenTimestamp: Int64?
    private var screenEnabled = false
    private var remoteTracks: [String: RTCVideoTrack] = [:]
    private var remoteReferences: [String: ConferenceVideoTrack] = [:]
    private let renderers = ConferenceRendererRegistry()
    private var generation = UUID()
    private var cameraGeneration = UUID()
    private var microphoneGeneration = UUID()
    private var permissionsGeneration = UUID()
    private var closed = false
    private var closing: Task<Void, Never>?
    private var audioActivated = false
    private let callAudioOwner = UUID()
    private var ownsCallAudio = false
    private var microphoneEnabled = false
    private var cameraEnabled = false
    private var speakerEnabled = true
    private var frontCamera = true
    private var interrupted = false
    private var pathMonitor: NWPathMonitor?
    private var previousPath: String?

    override init() {
        let pair = AsyncStream.makeStream(of: ConferenceMediaEvent.self, bufferingPolicy: .bufferingNewest(512))
        events = pair.stream; continuation = pair.continuation
        super.init()
    }

    func configure(_ configuration: ConferenceMediaConfiguration) async throws {
        guard !closed, peer == nil, (2...32).contains(configuration.maxPeers),
              ["all", "relay"].contains(configuration.iceTransportPolicy),
              (1...3840).contains(configuration.maxWidth), (1...2160).contains(configuration.maxHeight),
              (1...60).contains(configuration.maxFrameRate), configuration.iceServers.count <= 32,
              configuration.iceServers.allSatisfy({ server in
                  !server.urls.isEmpty && server.urls.count <= 16 && server.urls.allSatisfy { url in
                      ["stun:", "stuns:", "turn:", "turns:"].contains(where: url.lowercased().hasPrefix) &&
                      url.utf8.count <= 2048 && !url.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) })
                  }
              }) else { throw ConferenceMediaError.invalidConfiguration }
        try Task.checkCancellation()
        self.configuration = configuration
        let audio = RTCAudioSession.sharedInstance()
        audio.useManualAudio = true; audio.isAudioEnabled = false
        audio.add(self)
        if configuration.audioActivation == .callKit {
            CallAudioSessionBridge.acquire(callAudioOwner); ownsCallAudio = true
        }
        do {
            try activateAudio()
            let peer = try NativePeer(configuration: configuration, videoTrackID: localVideoTrackID,
                emit: { [weak self] event in self?.emit(event) },
                receivedVideo: { [weak self] track, reference in self?.receive(track, reference: reference) },
                removedVideo: { [weak self] id in self?.removeVideo(id) })
            self.peer = peer
            peer.videoSource.adaptOutputFormat(toWidth: Int32(configuration.maxWidth),
                                               height: Int32(configuration.maxHeight), fps: Int32(configuration.maxFrameRate))
            enableAudioIfAllowed()
            emit(.videoTrackAdded(ConferenceVideoTrack(id: localVideoTrackID, mid: nil,
                streamID: configuration.mediaPeerID.uuidString.lowercased(), isLocal: true)))
            captureChanged(); emitRoute(); observeNetwork()
        } catch {
            await close()
            if error is ConferenceMediaError { throw error }
            throw ConferenceMediaError.audioSession
        }
    }

    func makeOffer(iceRestart: Bool) async throws -> ConferenceMediaOffer {
        guard !closed, let peer else { throw ConferenceMediaError.notConfigured }
        return try await peer.makeOffer(iceRestart: iceRestart)
    }

    func applyAnswer(_ sdp: String) async throws {
        guard !closed, let peer else { throw ConferenceMediaError.notConfigured }
        try await peer.applyAnswer(sdp)
    }

    func rollbackLocalOffer() async throws {
        guard !closed, let peer else { throw ConferenceMediaError.notConfigured }
        try await peer.rollbackLocalOffer()
    }

    func addRemoteCandidate(_ candidate: ConferenceICECandidate) async throws {
        guard !closed, let peer else { throw ConferenceMediaError.notConfigured }
        try await peer.addRemoteCandidate(candidate)
    }

    func setPublicationPermissions(microphone: Bool, camera: Bool, screen: Bool) async throws {
        guard !closed, let peer else { throw ConferenceMediaError.notConfigured }
        permissionsGeneration = UUID(); let operation = permissionsGeneration
        configuration?.microphoneAllowed = microphone; configuration?.cameraAllowed = camera
        configuration?.screenAllowed = screen && camera
        // Publish directions must change even while muted; SFU validates every sending SDP section.
        // A direction update failure must never skip stopping the other forbidden capture.
        var stoppedCleanly = true
        if !microphone {
            do { try await setMicrophoneEnabled(false) } catch { stoppedCleanly = false }
        }
        if !camera {
            do { try await setCameraEnabled(false) } catch { stoppedCleanly = false }
        }
        if !screen || !camera {
            do { try await setScreenEnabled(false) } catch { stoppedCleanly = false }
        }
        guard !closed, self.peer === peer, permissionsGeneration == operation else { throw CancellationError() }
        guard stoppedCleanly else { throw ConferenceMediaError.negotiation }
        do { try peer.setPublicationPermissions(microphone: microphone, camera: camera, screen: screen) }
        catch { throw ConferenceMediaError.negotiation }
    }

    func setScreenEnabled(_ enabled: Bool) async throws {
        guard !closed, let peer else { throw ConferenceMediaError.notConfigured }
        if enabled && screenEnabled { return }
        if !enabled {
            let wasEnabled = screenEnabled
            screenEnabled = false; screenSessionID = nil; screenTimestamp = nil
            screenCapturer = nil; screenPool = nil; screenDimensions = nil
            renderers.detach(trackID: localScreenVideoTrackID)
            let removal = Result { try peer.setScreenEnabled(false, trackID: nil) }
            if wasEnabled { emit(.videoTrackRemoved(localScreenVideoTrackID)); emit(.screenCaptureState(false)) }
            try removal.get()
            return
        }
        guard configuration?.screenAllowed == true, configuration?.cameraAllowed == true else {
            throw ConferenceMediaError.publicationBlocked
        }
        guard !interrupted else { throw ConferenceMediaError.interrupted }
        try Task.checkCancellation()
        localScreenVideoTrackID = "screen-" + UUID().uuidString.lowercased()
        try peer.setScreenEnabled(true, trackID: localScreenVideoTrackID)
        screenCapturer = RTCVideoCapturer(delegate: peer.screenSource)
        screenEnabled = true; screenSessionID = nil; screenTimestamp = nil
        emit(.videoTrackAdded(ConferenceVideoTrack(id: localScreenVideoTrackID, mid: nil,
            streamID: configuration!.mediaPeerID.uuidString.lowercased() + "-screen", isLocal: true)))
        emit(.screenCaptureState(true))
    }

    func pushScreenFrame(_ frame: ScreenBroadcastFrame) throws {
        guard !closed, screenEnabled, let peer, let screenCapturer else { throw ConferenceMediaError.screenUnavailable }
        guard !interrupted, configuration?.screenAllowed == true, configuration?.cameraAllowed == true else {
            throw ConferenceMediaError.publicationBlocked
        }
        guard (1...1280).contains(frame.width), (1...1280).contains(frame.height),
              frame.width * frame.height <= 1280 * 720, frame.rowBytes == frame.width * 4,
              frame.pixels.count == frame.rowBytes * frame.height, frame.timestampNs >= 0,
              screenSessionID == nil || screenSessionID == frame.sessionID else {
            throw ConferenceMediaError.invalidScreenFrame
        }
        if let last = screenTimestamp, frame.timestampNs <= last || frame.timestampNs - last < 100_000_000 { return }
        if screenDimensions?.width != frame.width || screenDimensions?.height != frame.height {
            screenPool = nil
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: frame.width, kCVPixelBufferHeightKey as String: frame.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &screenPool) == kCVReturnSuccess else {
                throw ConferenceMediaError.capture
            }
            screenDimensions = (frame.width, frame.height)
            peer.screenSource.adaptOutputFormat(toWidth: Int32(frame.width), height: Int32(frame.height), fps: 10)
        }
        guard let screenPool else { throw ConferenceMediaError.capture }
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, screenPool,
            [kCVPixelBufferPoolAllocationThresholdKey as String: 3] as CFDictionary, &buffer)
        if result == kCVReturnWouldExceedAllocationThreshold { return } // Encoder backpressure: no frame backlog.
        guard result == kCVReturnSuccess, let buffer,
              CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { throw ConferenceMediaError.capture }
        guard let destination = CVPixelBufferGetBaseAddress(buffer) else {
            CVPixelBufferUnlockBaseAddress(buffer, []); throw ConferenceMediaError.capture
        }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        frame.pixels.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress else { return }
            for row in 0..<frame.height {
                memcpy(destination.advanced(by: row * stride), source.advanced(by: row * frame.rowBytes), frame.rowBytes)
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        screenSessionID = frame.sessionID; screenTimestamp = frame.timestampNs
        peer.captureScreen(RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0,
                                        timeStampNs: frame.timestampNs), capturer: screenCapturer)
    }

    func setMicrophoneEnabled(_ enabled: Bool) async throws {
        microphoneGeneration = UUID(); let operation = microphoneGeneration, current = generation
        guard !closed, let peer else { throw ConferenceMediaError.notConfigured }
        if !enabled {
            peer.audioTrack.isEnabled = false; microphoneEnabled = false; captureChanged()
            try peer.setMicrophoneEnabled(false); return
        }
        guard configuration?.microphoneAllowed == true else { throw ConferenceMediaError.publicationBlocked }
        guard !interrupted else { throw ConferenceMediaError.interrupted }
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        try Task.checkCancellation()
        guard !closed, generation == current, microphoneGeneration == operation, self.peer === peer else { throw CancellationError() }
        guard allowed else { throw ConferenceMediaError.microphonePermissionDenied }
        guard configuration?.microphoneAllowed == true else { throw ConferenceMediaError.publicationBlocked }
        guard !interrupted else { throw ConferenceMediaError.interrupted }
        try activateAudio()
        enableAudioIfAllowed()
        do {
            try peer.setMicrophoneEnabled(true); microphoneEnabled = true; captureChanged()
        } catch {
            peer.audioTrack.isEnabled = false; try? peer.setMicrophoneEnabled(false)
            microphoneEnabled = false; captureChanged()
            throw ConferenceMediaError.negotiation
        }
    }

    func setCameraEnabled(_ enabled: Bool) async throws {
        cameraGeneration = UUID(); let operation = cameraGeneration, current = generation
        guard !closed, let peer else { throw ConferenceMediaError.notConfigured }
        if enabled && cameraEnabled { return }
        if !enabled {
            peer.videoTrack.isEnabled = false; cameraEnabled = false; captureChanged()
            let removal = Result { try peer.setCameraEnabled(false) }
            if let capturer { await stopCapture(capturer) }
            try removal.get()
            return
        }
        guard configuration?.cameraAllowed == true else { throw ConferenceMediaError.publicationBlocked }
        guard !interrupted else { throw ConferenceMediaError.interrupted }
        let allowed = await AVCaptureDevice.requestAccess(for: .video)
        try Task.checkCancellation()
        guard !closed, generation == current, cameraGeneration == operation, self.peer === peer else { throw CancellationError() }
        guard allowed else { throw ConferenceMediaError.cameraPermissionDenied }
        guard configuration?.cameraAllowed == true else { throw ConferenceMediaError.publicationBlocked }
        guard !interrupted else { throw ConferenceMediaError.interrupted }
        // Constructing RTCCameraVideoCapturer creates an AVCaptureSession. Keep it entirely absent
        // until explicit enable passes permission and lifecycle checks, including on the simulator.
        let capturer = self.capturer ?? RTCCameraVideoCapturer(delegate: peer.videoSource)
        self.capturer = capturer
        do {
            try await startCapture(capturer)
            try Task.checkCancellation()
            guard !closed, generation == current, cameraGeneration == operation, self.peer === peer,
                  !interrupted, configuration?.cameraAllowed == true else {
                throw CancellationError()
            }
            try peer.setCameraEnabled(true); cameraEnabled = true; captureChanged()
        } catch {
            // A newer disable/close owns its queued stop. An obsolete completion must not stop a
            // subsequently enabled capture on this same capturer.
            if cameraGeneration == operation {
                peer.videoTrack.isEnabled = false; cameraEnabled = false; captureChanged()
                try? peer.setCameraEnabled(false)
                await stopCapture(capturer)
            }
            throw error
        }
    }

    func switchCamera() async throws {
        guard !closed, let peer else { throw ConferenceMediaError.notConfigured }
        let desired: AVCaptureDevice.Position = frontCamera ? .back : .front
        if cameraEnabled && !RTCCameraVideoCapturer.captureDevices().contains(where: { $0.position == desired }) {
            throw ConferenceMediaError.cameraUnavailable
        }
        cameraGeneration = UUID(); let operation = cameraGeneration, current = generation
        let wasEnabled = cameraEnabled
        frontCamera.toggle(); peer.videoTrack.isEnabled = false; cameraEnabled = false; captureChanged()
        let removal = Result { try peer.setCameraEnabled(false) }
        if let capturer { await stopCapture(capturer) }
        try removal.get()
        guard !closed, generation == current, cameraGeneration == operation else { throw CancellationError() }
        if wasEnabled { try await setCameraEnabled(true) }
    }

    func setSpeakerEnabled(_ enabled: Bool) throws {
        guard !closed, peer != nil else { throw ConferenceMediaError.notConfigured }
        let audio = RTCAudioSession.sharedInstance()
        audio.lockForConfiguration(); defer { audio.unlockForConfiguration() }
        let previous = speakerEnabled; speakerEnabled = enabled
        do {
            // `.none` restores the category default. Remove defaultToSpeaker as well when the
            // user requests the receiver/system route; otherwise the toggle stays on speaker.
            try configureAudioCategory(audio)
            try audio.overrideOutputAudioPort(enabled ? .speaker : .none)
        } catch {
            speakerEnabled = previous; try? configureAudioCategory(audio)
            throw ConferenceMediaError.audioSession
        }
        emitRoute()
    }

    /// Capture never resumes implicitly after an interruption or background transition.
    func suspend() async {
        cameraGeneration = UUID(); microphoneGeneration = UUID()
        peer?.audioTrack.isEnabled = false; peer?.videoTrack.isEnabled = false
        try? peer?.setMicrophoneEnabled(false); try? peer?.setCameraEnabled(false)
        microphoneEnabled = false; cameraEnabled = false; captureChanged()
        try? await setScreenEnabled(false)
        RTCAudioSession.sharedInstance().isAudioEnabled = false
        if let capturer { await stopCapture(capturer) }
    }

    func close() async {
        if let closing { await closing.value; return }
        closed = true; generation = UUID(); cameraGeneration = UUID(); microphoneGeneration = UUID()
        let task = Task { @MainActor in await self.finishClose() }
        closing = task
        await task.value
    }

    private func finishClose() async {
        pathMonitor?.cancel(); pathMonitor = nil
        peer?.audioTrack.isEnabled = false; peer?.videoTrack.isEnabled = false
        microphoneEnabled = false; cameraEnabled = false
        screenEnabled = false; screenSessionID = nil; screenTimestamp = nil
        screenCapturer = nil; screenPool = nil; screenDimensions = nil
        renderers.detachAll()
        peer?.close(); peer = nil
        let audio = RTCAudioSession.sharedInstance()
        audio.isAudioEnabled = false; audio.remove(self)
        if ownsCallAudio { CallAudioSessionBridge.release(callAudioOwner); ownsCallAudio = false }
        if let capturer { await stopCapture(capturer) }
        self.capturer = nil
        audio.lockForConfiguration()
        if audioActivated { try? audio.setActive(false); audioActivated = false }
        audio.unlockForConfiguration()
        for id in remoteTracks.keys { continuation.yield(.videoTrackRemoved(id)) }
        remoteTracks.removeAll(); remoteReferences.removeAll(); configuration = nil
        continuation.yield(.videoTrackRemoved(localVideoTrackID))
        continuation.yield(.videoTrackRemoved(localScreenVideoTrackID)); continuation.yield(.screenCaptureState(false))
        continuation.yield(.captureState(microphone: false, camera: false, frontCamera: frontCamera))
        continuation.yield(.connectionState(.closed)); continuation.finish()
    }

    func videoView(trackID: String, mirrored: Bool) -> AnyView {
        videoView(trackID: trackID, mirrored: mirrored, fit: trackID == localScreenVideoTrackID)
    }

    func videoView(trackID: String, mirrored: Bool, fit: Bool) -> AnyView {
        let track = trackID == localVideoTrackID ? peer?.videoTrack :
            (trackID == localScreenVideoTrackID ? peer?.screenTrack : remoteTracks[trackID])
        // A new engine must also get a new UIView/coordinator, whose registry owns the attachment.
        return AnyView(ConferenceVideoRenderer(track: track, mirrored: mirrored, fit: fit, registry: renderers)
            .id(ObjectIdentifier(renderers)))
    }

    private func emit(_ event: ConferenceMediaEvent) {
        guard !closed else { return }
        if case .dropped = continuation.yield(event) {
            // Losing signaling is unsafe. The consumer must replace this attempt with fresh state.
            continuation.yield(.failure(.negotiation))
        }
    }

    private func captureChanged() {
        emit(.captureState(microphone: microphoneEnabled, camera: cameraEnabled, frontCamera: frontCamera))
    }

    private func activateAudio() throws {
        let audio = RTCAudioSession.sharedInstance()
        audio.lockForConfiguration(); defer { audio.unlockForConfiguration() }
        do {
            try configureAudioCategory(audio)
            if configuration?.audioActivation != .callKit, !audioActivated {
                try audio.setActive(true); audioActivated = true
            }
        } catch { throw ConferenceMediaError.audioSession }
    }

    private func configureAudioCategory(_ audio: RTCAudioSession) throws {
        var options: AVAudioSession.CategoryOptions = [.allowBluetooth]
        if speakerEnabled { options.insert(.defaultToSpeaker) }
        try audio.setCategory(AVAudioSession.Category.playAndRecord, mode: AVAudioSession.Mode.voiceChat, options: options)
    }

    private func enableAudioIfAllowed() {
        RTCAudioSession.sharedInstance().isAudioEnabled =
            configuration?.audioActivation == .callKit ? CallAudioSessionBridge.isActive : true
    }

    private func startCapture(_ capturer: RTCCameraVideoCapturer) async throws {
        guard let configuration else { throw ConferenceMediaError.notConfigured }
        let position: AVCaptureDevice.Position = frontCamera ? .front : .back
        guard let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == position }) else {
            throw ConferenceMediaError.cameraUnavailable
        }
        let targetPixels = configuration.maxWidth * configuration.maxHeight
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        guard let format = formats.min(by: { first, second in
            let a = CMVideoFormatDescriptionGetDimensions(first.formatDescription)
            let b = CMVideoFormatDescriptionGetDimensions(second.formatDescription)
            return abs(Int(a.width) * Int(a.height) - targetPixels) < abs(Int(b.width) * Int(b.height) - targetPixels)
        }), let frameRange = format.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) else {
            throw ConferenceMediaError.cameraUnavailable
        }
        let fps = max(Int(frameRange.minFrameRate.rounded(.up)), min(configuration.maxFrameRate, Int(frameRange.maxFrameRate)))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            capturer.startCapture(with: device, format: format, fps: fps) { @Sendable error in
                if error == nil { continuation.resume() }
                else { continuation.resume(throwing: ConferenceMediaError.capture) }
            }
        }
    }

    private func stopCapture(_ capturer: RTCCameraVideoCapturer) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            capturer.stopCapture { @Sendable in continuation.resume() }
        }
    }

    private func receive(_ track: RTCVideoTrack, reference: ConferenceVideoTrack) {
        guard !closed else { return }
        let previous = remoteReferences[reference.id]
        // Preserve an msid learned by didAddReceiver when a later answer supplies only a MID.
        let next = ConferenceVideoTrack(id: reference.id, mid: reference.mid ?? previous?.mid,
                                       streamID: reference.streamID ?? previous?.streamID, isLocal: false)
        remoteTracks[reference.id] = track; remoteReferences[reference.id] = next
        emit(.videoTrackAdded(next))
    }

    private func removeVideo(_ id: String) {
        renderers.detach(trackID: id); remoteTracks[id] = nil; remoteReferences[id] = nil
        emit(.videoTrackRemoved(id))
    }

    private func emitRoute() {
        // Report a stable port type rather than a potentially personal Bluetooth device name.
        let port = RTCAudioSession.sharedInstance().currentRoute.outputs.first?.portType.rawValue ?? ""
        emit(.audioRoute(port))
    }

    private func observeNetwork() {
        let monitor = NWPathMonitor(); pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let status = String(describing: path.status)
            let interfaces = [NWInterface.InterfaceType.wifi, .cellular, .wiredEthernet].filter(path.usesInterfaceType)
            let signature = status + ":" + interfaces.map { String(describing: $0) }.joined(separator: ",")
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { return }
                defer { self.previousPath = signature }
                if let previous = self.previousPath, previous != signature { self.emit(.networkPathChanged) }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.meetspace.media.path"))
    }
}

extension NativeConferenceMediaEngine: RTCAudioSessionDelegate {
    nonisolated func audioSessionDidBeginInterruption(_ session: RTCAudioSession) {
        Task { @MainActor [weak self] in
            guard let self, !self.closed else { return }
            self.interrupted = true; self.emit(.interrupted(true)); await self.suspend()
        }
    }

    nonisolated func audioSessionDidEndInterruption(_ session: RTCAudioSession, shouldResumeSession: Bool) {
        Task { @MainActor [weak self] in
            guard let self, !self.closed else { return }
            self.interrupted = false
            if shouldResumeSession {
                do { try self.activateAudio(); self.enableAudioIfAllowed() }
                catch { self.emit(.failure(.audioSession)) }
            }
            self.emit(.interrupted(false))
        }
    }

    nonisolated func audioSessionDidChangeRoute(_ session: RTCAudioSession, reason: AVAudioSession.RouteChangeReason,
                                              previousRoute: AVAudioSessionRouteDescription) {
        let lostInput = reason == .oldDeviceUnavailable
        Task { @MainActor [weak self] in
            guard let self, !self.closed else { return }
            if lostInput {
                // Removing a headset must not silently start publishing the built-in microphone.
                self.microphoneGeneration = UUID(); self.peer?.audioTrack.isEnabled = false
                try? self.peer?.setMicrophoneEnabled(false)
                self.microphoneEnabled = false; self.captureChanged()
            }
            self.emitRoute()
        }
    }

    nonisolated func audioSessionMediaServerTerminated(_ session: RTCAudioSession) {
        Task { @MainActor [weak self] in
            guard let self, !self.closed else { return }
            await self.suspend(); self.emit(.failure(.audioSession))
        }
    }

    nonisolated func audioSessionMediaServerReset(_ session: RTCAudioSession) {
        Task { @MainActor [weak self] in
            guard let self, !self.closed else { return }
            await self.suspend(); self.emit(.failure(.audioSession))
        }
    }
}
#endif
