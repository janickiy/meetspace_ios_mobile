#if os(iOS)
import Foundation
@preconcurrency import WebRTC

/// The ObjC SDK is thread safe; all mutations are serialized by MainActor. Delegate arguments cross
/// to MainActor in this narrow box only. They are never exposed to Features or other application tasks.
private final class RTCReference<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

@MainActor final class NativePeer: NSObject {
    private static let sslInitialized: Void = {
        // Preserve M156's verified default with no log sinks. Its legacy LogToDebug wrapper enables
        // stderr output even for `.none`; do not install debug/callback/file loggers in production.
        _ = RTCInitializeSSL()
    }()
    let audioTrack: RTCAudioTrack
    let videoTrack: RTCVideoTrack
    let videoSource: RTCVideoSource
    private let factory: RTCPeerConnectionFactory
    private var connection: RTCPeerConnection?
    private var microphone: RTCRtpTransceiver?
    private var camera: RTCRtpTransceiver?
    private var pendingCandidates: [ConferenceICECandidate] = []
    private var hasRemoteDescription = false
    private var makingOffer = false
    private var publicationRevision = 0
    private let streamID: String
    private let emit: @MainActor (ConferenceMediaEvent) -> Void
    private let receivedVideo: @MainActor (RTCVideoTrack, ConferenceVideoTrack) -> Void
    private let removedVideo: @MainActor (String) -> Void

    init(configuration: ConferenceMediaConfiguration, videoTrackID: String,
         emit: @escaping @MainActor (ConferenceMediaEvent) -> Void,
         receivedVideo: @escaping @MainActor (RTCVideoTrack, ConferenceVideoTrack) -> Void,
         removedVideo: @escaping @MainActor (String) -> Void) throws {
        _ = Self.sslInitialized
        factory = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                          decoderFactory: RTCDefaultVideoDecoderFactory())
        streamID = configuration.mediaPeerID.uuidString.lowercased()
        audioTrack = factory.audioTrack(withTrackId: "microphone-" + streamID)
        videoSource = factory.videoSource()
        videoTrack = factory.videoTrack(with: videoSource, trackId: videoTrackID)
        audioTrack.isEnabled = false; videoTrack.isEnabled = false
        self.emit = emit; self.receivedVideo = receivedVideo; self.removedVideo = removedVideo
        super.init()
        let rtc = RTCConfiguration()
        rtc.sdpSemantics = .unifiedPlan; rtc.bundlePolicy = .maxBundle; rtc.rtcpMuxPolicy = .require
        rtc.iceTransportPolicy = configuration.iceTransportPolicy == "relay" ? .relay : .all
        rtc.iceServers = configuration.iceServers.map {
            RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential, tlsCertPolicy: .secure)
        }
        guard let connection = factory.peerConnection(with: rtc,
            constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self) else {
            throw ConferenceMediaError.negotiation
        }
        self.connection = connection
        do {
            // Match Android's offer shape: microphone/camera, screen video/audio, then remote slots.
            microphone = try transceiver(type: .audio, direction: .recvOnly)
            camera = try transceiver(type: .video, direction: .recvOnly)
            _ = try transceiver(type: .video, direction: .recvOnly)
            _ = try transceiver(type: .audio, direction: .recvOnly)
            for _ in 0..<(2 * (configuration.maxPeers - 1)) {
                _ = try transceiver(type: .audio, direction: .recvOnly)
                _ = try transceiver(type: .video, direction: .recvOnly)
            }
        } catch {
            connection.close(); self.connection = nil
            throw ConferenceMediaError.negotiation
        }
    }

    private func transceiver(track: RTCMediaStreamTrack? = nil, type: RTCRtpMediaType,
                             direction: RTCRtpTransceiverDirection) throws -> RTCRtpTransceiver {
        let options = RTCRtpTransceiverInit(); options.direction = direction; options.streamIds = [streamID]
        let value: RTCRtpTransceiver?
        if let track { value = connection?.addTransceiver(with: track, init: options) }
        else { value = connection?.addTransceiver(of: type, init: options) }
        guard let value else { throw ConferenceMediaError.negotiation }
        let kind = type == .audio ? "audio" : "video"
        let expected = type == .audio ? "opus" : "vp8"
        let supported = factory.rtpSenderCapabilities(forKind: kind).codecs.filter { $0.name.lowercased() == expected }
        guard !supported.isEmpty else { throw ConferenceMediaError.negotiation }
        // M156 exposes the throwing overload with an `error: ()` discriminator.
        try value.setCodecPreferences(supported, error: ())
        return value
    }

    func makeOffer(iceRestart: Bool) async throws -> ConferenceMediaOffer {
        guard let connection, !makingOffer, connection.signalingState == .stable else { throw ConferenceMediaError.negotiation }
        let publicationRevision = publicationRevision
        makingOffer = true; defer { makingOffer = false }
        let constraints = RTCMediaConstraints(mandatoryConstraints: iceRestart ? ["IceRestart": "true"] : nil,
                                               optionalConstraints: nil)
        let sdp: String = try await withCheckedThrowingContinuation { continuation in
            connection.offer(for: constraints) { description, error in
                if error == nil, let description { continuation.resume(returning: description.sdp) }
                else { continuation.resume(throwing: ConferenceMediaError.negotiation) }
            }
        }
        try Task.checkCancellation()
        guard self.connection === connection else { throw CancellationError() }
        guard self.publicationRevision == publicationRevision else { throw ConferenceMediaError.negotiation }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.setLocalDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { error in
                if error == nil { continuation.resume() }
                else { continuation.resume(throwing: ConferenceMediaError.negotiation) }
            }
        }
        try Task.checkCancellation()
        guard self.connection === connection, self.publicationRevision == publicationRevision else {
            throw ConferenceMediaError.negotiation
        }
        let localSDP = connection.localDescription?.sdp ?? sdp
        var publications: [ConferenceMediaPublication] = []
        if let microphone, microphone.direction == .sendRecv {
            guard !microphone.mid.isEmpty else { throw ConferenceMediaError.negotiation }
            publications.append(ConferenceMediaPublication(mid: microphone.mid, source: "microphone",
                trackId: try wireTrackID(mid: microphone.mid, sdp: localSDP)))
        }
        if let camera, camera.direction == .sendRecv {
            guard !camera.mid.isEmpty else { throw ConferenceMediaError.negotiation }
            publications.append(ConferenceMediaPublication(mid: camera.mid, source: "camera",
                trackId: try wireTrackID(mid: camera.mid, sdp: localSDP)))
        }
        return ConferenceMediaOffer(sdp: localSDP, publications: publications)
    }

    /// Replacing a nil sender track preserves the sender's generated SDP msid identity in M156.
    /// The SFU validates the wire track ID, which can differ from RTCMediaStreamTrack.trackId.
    private func wireTrackID(mid: String, sdp: String) throws -> String {
        let sections = sdp.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\nm=")
        for section in sections.dropFirst() {
            let lines = section.components(separatedBy: "\n")
            guard lines.contains("a=mid:" + mid) else { continue }
            let identities = lines.filter { $0.hasPrefix("a=msid:") }.map { $0.dropFirst(7).split(separator: " ") }
            guard identities.count == 1, let identity = identities.first, identity.count == 2,
                  String(identity[0]) == streamID, !identity[1].isEmpty else { throw ConferenceMediaError.negotiation }
            return String(identity[1])
        }
        throw ConferenceMediaError.negotiation
    }

    func setPublicationPermissions(microphone: Bool, camera: Bool) throws {
        guard connection != nil else { throw ConferenceMediaError.notConfigured }
        if !microphone { try setMicrophoneEnabled(false) }
        if !camera { try setCameraEnabled(false) }
    }

    func setMicrophoneEnabled(_ enabled: Bool) throws {
        audioTrack.isEnabled = enabled
        try setSource(microphone, track: enabled ? audioTrack : nil)
    }

    func setCameraEnabled(_ enabled: Bool) throws {
        videoTrack.isEnabled = enabled
        try setSource(camera, track: enabled ? videoTrack : nil)
    }

    private func setSource(_ transceiver: RTCRtpTransceiver?, track: RTCMediaStreamTrack?) throws {
        guard connection != nil, let transceiver else { throw ConferenceMediaError.notConfigured }
        let direction: RTCRtpTransceiverDirection = track == nil ? .recvOnly : .sendRecv
        if transceiver.sender.track?.trackId != track?.trackId || transceiver.direction != direction { publicationRevision += 1 }
        transceiver.sender.track = track
        transceiver.sender.streamIds = [streamID]
        var error: NSError?
        transceiver.setDirection(direction, error: &error)
        if error != nil { throw ConferenceMediaError.negotiation }
    }

    func applyAnswer(_ sdp: String) async throws {
        guard let connection, connection.signalingState == .haveLocalOffer,
              !sdp.isEmpty, sdp.utf8.count <= 1_048_576 else { throw ConferenceMediaError.negotiation }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { error in
                if error == nil { continuation.resume() }
                else { continuation.resume(throwing: ConferenceMediaError.negotiation) }
            }
        }
        try Task.checkCancellation()
        guard self.connection === connection else { throw CancellationError() }
        hasRemoteDescription = true
        let queued = pendingCandidates; pendingCandidates.removeAll()
        for candidate in queued { try await addRemoteCandidate(candidate) }
        // Unified Plan may reuse a receiver/MID. Refresh references after every answer as well.
        for transceiver in connection.transceivers {
            if let track = transceiver.receiver.track as? RTCVideoTrack {
                receivedVideo(track, ConferenceVideoTrack(id: track.trackId, mid: transceiver.mid, streamID: nil, isLocal: false))
            }
        }
    }

    func addRemoteCandidate(_ candidate: ConferenceICECandidate) async throws {
        guard let connection else { throw ConferenceMediaError.notConfigured }
        guard !candidate.candidate.isEmpty, candidate.candidate.utf8.count <= 8192,
              candidate.sdpMLineIndex >= 0, candidate.sdpMLineIndex <= 1024,
              (candidate.sdpMid?.utf8.count ?? 0) <= 128 else { throw ConferenceMediaError.invalidCandidate }
        if !hasRemoteDescription {
            guard pendingCandidates.count < 256 else { throw ConferenceMediaError.invalidCandidate }
            pendingCandidates.append(candidate); return
        }
        let value = RTCIceCandidate(sdp: candidate.candidate, sdpMLineIndex: candidate.sdpMLineIndex, sdpMid: candidate.sdpMid)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.add(value) { error in
                if error == nil { continuation.resume() }
                else { continuation.resume(throwing: ConferenceMediaError.invalidCandidate) }
            }
        }
        try Task.checkCancellation()
        guard self.connection === connection else { throw CancellationError() }
    }

    func close() {
        audioTrack.isEnabled = false; videoTrack.isEnabled = false
        let old = connection; connection = nil
        old?.delegate = nil; old?.close()
        microphone = nil; camera = nil; pendingCandidates.removeAll(); hasRemoteDescription = false
    }

    private func accepts(_ identity: ObjectIdentifier) -> Bool { connection.map(ObjectIdentifier.init) == identity }
}

extension NativePeer: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) { }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) { }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) { }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) { }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        guard newState == .complete else { return }
        let identity = ObjectIdentifier(peerConnection)
        Task { @MainActor [weak self] in
            guard let self, self.accepts(identity) else { return }
            self.emit(.iceGatheringComplete)
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) { }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        dataChannel.close() // Conference control/chat use the authenticated signaling protocol.
    }

    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        let identity = ObjectIdentifier(peerConnection)
        Task { @MainActor [weak self] in
            guard let self, self.accepts(identity) else { return }
            self.emit(.negotiationNeeded)
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let identity = ObjectIdentifier(peerConnection)
        let candidate = ConferenceICECandidate(candidate: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex)
        Task { @MainActor [weak self] in
            guard let self, self.accepts(identity) else { return }
            self.emit(.candidate(candidate))
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        let identity = ObjectIdentifier(peerConnection)
        let state: ConferenceMediaConnectionState
        switch newState {
        case .new: state = .new
        case .connecting: state = .connecting
        case .connected: state = .connected
        case .disconnected: state = .disconnected
        case .failed: state = .failed
        case .closed: state = .closed
        @unknown default: state = .failed
        }
        Task { @MainActor [weak self] in
            guard let self, self.accepts(identity) else { return }
            self.emit(.connectionState(state))
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver,
                                  streams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        let identity = ObjectIdentifier(peerConnection), reference = RTCReference(track)
        let mid = peerConnection.transceivers.first { $0.receiver.receiverId == rtpReceiver.receiverId }?.mid
        let value = ConferenceVideoTrack(id: track.trackId, mid: mid, streamID: streams.first?.streamId, isLocal: false)
        Task { @MainActor [weak self] in
            guard let self, self.accepts(identity) else { return }
            self.receivedVideo(reference.value, value)
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove rtpReceiver: RTCRtpReceiver) {
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        let identity = ObjectIdentifier(peerConnection), trackID = track.trackId
        Task { @MainActor [weak self] in
            guard let self, self.accepts(identity) else { return }
            self.removedVideo(trackID)
        }
    }
}
#endif
