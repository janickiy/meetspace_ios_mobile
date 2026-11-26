#if os(iOS)
import Foundation
import MeetSpaceCore
@preconcurrency import WebRTC

/// The ObjC SDK is thread safe; all mutations are serialized by MainActor. Delegate arguments cross
/// to MainActor in this narrow box only. They are never exposed to Features or other application tasks.
private final class RTCReference<Value>: @unchecked Sendable {
    let value: Value
    /// Удерживает объект Objective-C для передачи из обратного вызова WebRTC на главный актор.
    /// - Parameter value: Объект SDK, ссылку на который нужно передать.
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
    let screenSource: RTCVideoSource
    private(set) var screenTrack: RTCVideoTrack?
    private var screenSenderReady = false
    private let factory: RTCPeerConnectionFactory
    private var connection: RTCPeerConnection?
    private var microphone: RTCRtpTransceiver?
    private var camera: RTCRtpTransceiver?
    private var screen: RTCRtpTransceiver?
    private var pendingCandidates: [ConferenceICECandidate] = []
    private var hasRemoteDescription = false
    private var makingOffer = false
    private var publicationRevision = 0
    private var speakerVolume: Double
    private var audioReceivers: [String: RTCRtpReceiver] = [:]
    private var previousAudioSamples: [String: ConferenceAudioSample] = [:]
    private var answerRevision = 0
    private let streamID: String
    private let receiveVideo: Bool
    private let emit: @MainActor (ConferenceMediaEvent) -> Void
    private let receivedVideo: @MainActor (RTCVideoTrack, ConferenceVideoTrack) -> Void
    private let removedVideo: @MainActor (String) -> Void

    /// Создаёт соединение Unified Plan с отключёнными локальными дорожками и каналами приёма для участников.
    /// - Parameters:
    ///   - configuration: Параметры ICE, видео и лимит участников.
    ///   - videoTrackID: Идентификатор дорожки локальной камеры.
    ///   - emit: Обработчик событий сигналинга и состояния соединения.
    ///   - receivedVideo: Обработчик новой входящей видеодорожки и её привязки к потоку.
    ///   - removedVideo: Обработчик удаления входящей видеодорожки по идентификатору.
    init(configuration: ConferenceMediaConfiguration, videoTrackID: String,
         emit: @escaping @MainActor (ConferenceMediaEvent) -> Void,
         receivedVideo: @escaping @MainActor (RTCVideoTrack, ConferenceVideoTrack) -> Void,
         removedVideo: @escaping @MainActor (String) -> Void) throws {
        _ = Self.sslInitialized
        factory = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                          decoderFactory: RTCDefaultVideoDecoderFactory())
        streamID = configuration.mediaPeerID.uuidString.lowercased()
        receiveVideo = configuration.receiveVideo
        let preferences = DeviceAudioPreferences.load()
        speakerVolume = Double(preferences.speakerVolume)
        let noise = preferences.noiseSuppression ? "true" : "false"
        let source = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: ["googNoiseSuppression": noise]))
        audioTrack = factory.audioTrack(with: source, trackId: "microphone-" + streamID)
        videoSource = factory.videoSource()
        screenSource = factory.videoSource(forScreenCast: true)
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
            let videoDirection: RTCRtpTransceiverDirection = receiveVideo ? .recvOnly : .inactive
            camera = try transceiver(type: .video, direction: videoDirection)
            screen = try transceiver(type: .video, direction: videoDirection)
            _ = try transceiver(type: .audio, direction: .recvOnly)
            for _ in 0..<(2 * (configuration.maxPeers - 1)) {
                _ = try transceiver(type: .audio, direction: .recvOnly)
                _ = try transceiver(type: .video, direction: videoDirection)
            }
        } catch {
            connection.close(); self.connection = nil
            throw ConferenceMediaError.negotiation
        }
    }

    /// Добавляет RTP-трансивер и настраивает для него Opus или VP8 в зависимости от типа медиа.
    /// - Parameters:
    ///   - track: Локальная дорожка для привязки при создании, если имеется.
    ///   - type: Вид медиа: звук или видео.
    ///   - direction: Начальное направление приёма и передачи RTP.
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

    /// Создаёт локальное предложение SDP и список объявляемых серверу публикаций.
    /// - Parameter iceRestart: Запрашивать ли новый цикл ICE для соединения.
    func makeOffer(iceRestart: Bool) async throws -> ConferenceMediaOffer {
        guard let connection, !makingOffer, connection.signalingState == .stable else { throw ConferenceMediaError.negotiation }
        let publicationRevision = publicationRevision
        makingOffer = true; defer { makingOffer = false }
        let constraints = RTCMediaConstraints(mandatoryConstraints: iceRestart ? ["IceRestart": "true"] : nil,
                                               optionalConstraints: nil)
        let sdp: String = try await withCheckedThrowingContinuation { continuation in
            // ObjC completions run on WebRTC's signaling thread. Explicit @Sendable prevents
            // inheriting MainActor isolation and trapping in Swift 6's runtime executor check.
            connection.offer(for: constraints) { @Sendable description, error in
                if error == nil, let description { continuation.resume(returning: description.sdp) }
                else { continuation.resume(throwing: ConferenceMediaError.negotiation) }
            }
        }
        try Task.checkCancellation()
        guard self.connection === connection else { throw CancellationError() }
        guard self.publicationRevision == publicationRevision else { throw ConferenceMediaError.negotiation }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.setLocalDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { @Sendable error in
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
        if let camera, camera.direction == .sendRecv || camera.direction == .sendOnly {
            guard !camera.mid.isEmpty else { throw ConferenceMediaError.negotiation }
            publications.append(ConferenceMediaPublication(mid: camera.mid, source: "camera",
                trackId: try wireTrackID(mid: camera.mid, sdp: localSDP)))
        }
        if let screen, screen.direction == .sendRecv || screen.direction == .sendOnly, let screenTrack {
            guard !screen.mid.isEmpty else { throw ConferenceMediaError.negotiation }
            // The server treats this as an opaque capture-generation identifier, independent
            // of WebRTC's stable sender msid. A new capture must never reuse the old generation.
            publications.append(ConferenceMediaPublication(mid: screen.mid, source: "video/screen",
                                                            trackId: screenTrack.trackId))
        }
        return ConferenceMediaOffer(sdp: localSDP, publications: publications)
    }

    /// Извлекает проверяемый SFU идентификатор дорожки из msid предложения SDP. В M156 он сохраняется при замене дорожки отправителя и может отличаться от trackId объекта WebRTC.
    /// - Parameters:
    ///   - mid: Идентификатор искомой медиа-секции.
    ///   - sdp: Локальное SDP, содержащее описание дорожки отправителя.
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

    /// Отключает источники, публикация которых запрещена обновлённой политикой.
    /// - Parameters:
    ///   - microphone: Разрешена ли передача звука микрофона.
    ///   - camera: Разрешена ли передача видео с камеры.
    ///   - screen: Разрешена ли передача видео экрана.
    func setPublicationPermissions(microphone: Bool, camera: Bool, screen: Bool) throws {
        guard connection != nil else { throw ConferenceMediaError.notConfigured }
        if !microphone { try setMicrophoneEnabled(false) }
        if !camera { try setCameraEnabled(false) }
        if !screen || !camera { try setScreenEnabled(false, trackID: nil) }
    }

    /// Подключает микрофон к RTP-отправителю или отсоединяет его. При нулевом усилении дорожка остаётся беззвучной.
    /// - Parameters:
    ///   - enabled: Требуется ли публикация микрофона.
    ///   - inputGain: Настроенный уровень входа, где ноль соответствует тишине.
    func setMicrophoneEnabled(_ enabled: Bool, inputGain: Float = 1) throws {
        audioTrack.isEnabled = enabled && inputGain > 0
        try setSource(microphone, track: enabled ? audioTrack : nil)
    }

    /// Устанавливает громкость входящих аудиодорожек и сбрасывает измерения предыдущего уровня.
    /// - Parameter level: Новый коэффициент громкости воспроизведения.
    func setSpeakerVolume(_ level: Float) {
        let volume = Double(level)
        guard volume != speakerVolume else { return }
        speakerVolume = volume
        previousAudioSamples.removeAll()
        for transceiver in connection?.transceivers ?? [] {
            (transceiver.receiver.track as? RTCAudioTrack)?.source.volume = volume
        }
    }

    /// Измеряет локальный звук и звук входящих дорожек одним запросом статистики WebRTC без дополнительного захвата.
    func microphoneLevels() async -> ConferenceMicrophoneLevels {
        guard let connection, connection.connectionState == .connected, hasRemoteDescription else { return .init() }
        let revision = answerRevision
        let report = await withCheckedContinuation { continuation in
            connection.statistics { @Sendable report in continuation.resume(returning: RTCReference(report)) }
        }
        guard self.connection === connection, revision == answerRevision, !Task.isCancelled else { return .init() }

        var nextSamples: [String: ConferenceAudioSample] = [:]
        var local = 0.0, remote: [String: Double] = [:]
        for stat in report.value.statistics.values where stat.type == "media-source" || stat.type == "inbound-rtp" {
            let values = stat.values
            guard values["kind"] as? String == "audio" else { continue }
            let trackID = values["trackIdentifier"] as? String
            let sample = ConferenceAudioSample(level: (values["audioLevel"] as? NSNumber)?.doubleValue,
                                               energy: (values["totalAudioEnergy"] as? NSNumber)?.doubleValue,
                                               duration: (values["totalSamplesDuration"] as? NSNumber)?.doubleValue,
                                               packets: (values["packetsReceived"] as? NSNumber)?.uint64Value)
            let previous = previousAudioSamples[stat.id]
            nextSamples[stat.id] = sample
            if stat.type == "media-source" {
                if audioTrack.isEnabled, trackID == audioTrack.trackId { local = sample.rms(since: previous) }
                continue
            }
            let mid = (values["mid"] as? String) ?? audioReceivers.first { trackID != nil && $0.value.track?.trackId == trackID }?.key
            guard let mid, let receiver = audioReceivers[mid], trackID == nil || trackID == receiver.track?.trackId else { continue }
            // WebRTC reports inbound energy after per-track playback gain. RTP audio levels,
            // when negotiated, measure the source directly, even with a muted loudspeaker.
            var level = speakerVolume > 0 ? min(1, sample.rms(since: previous) / speakerVolume) : 0
            if let packets = sample.packets, let oldPackets = previous?.packets, packets > oldPackets,
               let ssrc = (values["ssrc"] as? NSNumber)?.uint32Value,
               let source = receiver.sources.first(where: { $0.sourceId == ssrc }),
               (0...0.3).contains(ProcessInfo.processInfo.systemUptime - source.timestampUs / 1_000_000),
               let packetLevel = source.audioLevel?.doubleValue, (0...1).contains(packetLevel) {
                level = packetLevel
            }
            remote[mid] = max(remote[mid] ?? 0, level)
        }
        previousAudioSamples = nextSamples
        return ConferenceMicrophoneLevels(local: local, remoteByMID: remote)
    }

    /// Подключает дорожку камеры к отправителю или отсоединяет её.
    /// - Parameter enabled: Значение true запрашивает передачу видео с камеры.
    func setCameraEnabled(_ enabled: Bool) throws {
        videoTrack.isEnabled = enabled
        try setSource(camera, track: enabled ? videoTrack : nil)
    }

    /// Создаёт дорожку нового сеанса демонстрации либо останавливает прежнюю публикацию.
    /// - Parameters:
    ///   - enabled: Требуется ли публикация экрана.
    ///   - trackID: Идентификатор новой дорожки захвата при включении демонстрации.
    func setScreenEnabled(_ enabled: Bool, trackID: String?) throws {
        screenTrack?.isEnabled = false; screenSenderReady = false
        if !enabled {
            screenTrack = nil
            try setSource(screen, track: nil, streamID: streamID + "-screen")
            return
        }
        guard let trackID else { throw ConferenceMediaError.invalidConfiguration }
        let track = factory.videoTrack(with: screenSource, trackId: trackID)
        track.isEnabled = false; screenTrack = track
        do {
            try setSource(screen, track: track, streamID: streamID + "-screen")
            try configureScreenSender()
        } catch {
            track.isEnabled = false; screenTrack = nil
            try? setSource(screen, track: nil, streamID: streamID + "-screen")
            throw error
        }
    }

    /// Ограничивает видеопоток экрана десятью кадрами в секунду и разрешает передачу после настройки кодировщика.
    private func configureScreenSender() throws {
        guard let screen, let screenTrack else { return }
        let parameters = screen.sender.parameters
        // M156 can expose no encodings until the first remote answer. Keep capture gated then.
        guard !parameters.encodings.isEmpty else { return }
        for encoding in parameters.encodings { encoding.maxFramerate = 10 }
        screen.sender.parameters = parameters
        guard screen.sender.parameters.encodings.allSatisfy({ $0.maxFramerate?.intValue == 10 }) else {
            throw ConferenceMediaError.negotiation
        }
        screenSenderReady = true; screenTrack.isEnabled = true
    }

    /// Передаёт готовому отправителю экрана очередной кадр демонстрации.
    /// - Parameters:
    ///   - frame: Кадр экрана с меткой времени в формате WebRTC.
    ///   - capturer: Захватчик, от имени которого кадр поступает источнику.
    func captureScreen(_ frame: RTCVideoFrame, capturer: RTCVideoCapturer) {
        guard screenSenderReady, screenTrack?.isEnabled == true else { return }
        screenSource.capturer(capturer, didCapture: frame)
    }

    /// Назначает RTP-отправителю дорожку и согласует направление передачи с настройками приёма.
    /// - Parameters:
    ///   - transceiver: Трансивер, на котором меняется публикация.
    ///   - track: Публикуемая дорожка или nil для остановки передачи.
    ///   - streamID: Идентификатор потока отправителя. При nil используется поток соединения.
    private func setSource(_ transceiver: RTCRtpTransceiver?, track: RTCMediaStreamTrack?, streamID: String? = nil) throws {
        guard connection != nil, let transceiver else { throw ConferenceMediaError.notConfigured }
        let direction: RTCRtpTransceiverDirection
        if transceiver.mediaType == .audio || receiveVideo {
            direction = track == nil ? .recvOnly : .sendRecv
        } else {
            direction = track == nil ? .inactive : .sendOnly
        }
        if transceiver.sender.track?.trackId != track?.trackId || transceiver.direction != direction { publicationRevision += 1 }
        transceiver.sender.track = track
        transceiver.sender.streamIds = [streamID ?? self.streamID]
        var error: NSError?
        transceiver.setDirection(direction, error: &error)
        if error != nil { throw ConferenceMediaError.negotiation }
    }

    /// Применяет SDP-ответ, добавляет отложенные ICE-кандидаты и обновляет привязки входящих дорожек.
    /// - Parameter sdp: SDP-ответ на текущее локальное предложение.
    func applyAnswer(_ sdp: String) async throws {
        guard let connection, connection.signalingState == .haveLocalOffer,
              !sdp.isEmpty, sdp.utf8.count <= 1_048_576 else { throw ConferenceMediaError.negotiation }
        answerRevision += 1
        audioReceivers.removeAll()
        previousAudioSamples.removeAll()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { @Sendable error in
                if error == nil { continuation.resume() }
                else { continuation.resume(throwing: ConferenceMediaError.negotiation) }
            }
        }
        try Task.checkCancellation()
        guard self.connection === connection else { throw CancellationError() }
        hasRemoteDescription = true
        try configureScreenSender()
        let queued = pendingCandidates; pendingCandidates.removeAll()
        for candidate in queued { try await addRemoteCandidate(candidate) }
        // Unified Plan may reuse a receiver/MID. Refresh references after every answer as well.
        for transceiver in connection.transceivers {
            if let audio = transceiver.receiver.track as? RTCAudioTrack {
                audio.source.volume = speakerVolume
                audioReceivers[transceiver.mid] = transceiver.receiver
            }
            if let track = transceiver.receiver.track as? RTCVideoTrack {
                receivedVideo(track, ConferenceVideoTrack(id: track.trackId, mid: transceiver.mid, streamID: nil, isLocal: false))
            }
        }
    }

    /// Отменяет ожидающее локальное предложение, возвращая соединение в стабильное состояние.
    func rollbackLocalOffer() async throws {
        guard let connection, !makingOffer else { throw ConferenceMediaError.negotiation }
        if connection.signalingState == .stable { return }
        guard connection.signalingState == .haveLocalOffer else { throw ConferenceMediaError.negotiation }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.setLocalDescription(RTCSessionDescription(type: .rollback, sdp: "")) { @Sendable error in
                if error == nil { continuation.resume() }
                else { continuation.resume(throwing: ConferenceMediaError.negotiation) }
            }
        }
        try Task.checkCancellation()
        guard self.connection === connection, connection.signalingState == .stable else {
            throw ConferenceMediaError.negotiation
        }
    }

    /// Проверяет и добавляет ICE-кандидат либо сохраняет его до установки удалённого SDP.
    /// - Parameter candidate: Сетевой кандидат и адресуемая секция SDP.
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
            connection.add(value) { @Sendable error in
                if error == nil { continuation.resume() }
                else { continuation.resume(throwing: ConferenceMediaError.invalidCandidate) }
            }
        }
        try Task.checkCancellation()
        guard self.connection === connection else { throw CancellationError() }
    }

    /// Останавливает локальные дорожки, отключает делегат и закрывает соединение WebRTC.
    func close() {
        audioTrack.isEnabled = false; videoTrack.isEnabled = false; screenTrack?.isEnabled = false
        screenTrack = nil; screenSenderReady = false
        audioReceivers.removeAll(); previousAudioSamples.removeAll()
        let old = connection; connection = nil
        old?.delegate = nil; old?.close()
        microphone = nil; camera = nil; screen = nil; pendingCandidates.removeAll(); hasRemoteDescription = false
    }

    /// Проверяет, принадлежит ли событие текущему экземпляру соединения.
    /// - Parameter identity: Объектный идентификатор соединения из обратного вызова WebRTC.
    private func accepts(_ identity: ObjectIdentifier) -> Bool { connection.map(ObjectIdentifier.init) == identity }
}

extension NativePeer: RTCPeerConnectionDelegate {
    /// Принимает уведомление о смене состояния сигналинга. Согласование ведётся при обработке SDP.
    /// - Parameters:
    ///   - peerConnection: Соединение, породившее событие.
    ///   - stateChanged: Новое состояние сигналинга WebRTC.
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) { }
    /// Принимает устаревший вызов добавления медиапотока. Дорожки Unified Plan обрабатываются через RTP-получатели.
    /// - Parameters:
    ///   - peerConnection: Соединение, принявшее поток.
    ///   - stream: Добавленный медиапоток WebRTC.
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) { }
    /// Принимает устаревший вызов удаления потока. Дорожки Unified Plan снимаются через RTP-получатели.
    /// - Parameters:
    ///   - peerConnection: Соединение, из которого удалён поток.
    ///   - stream: Удалённый медиапоток WebRTC.
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) { }
    /// Пропускает отдельное уведомление ICE. Сеанс получает общий статус соединения через делегат RTCPeerConnectionState.
    /// - Parameters:
    ///   - peerConnection: Соединение, сообщившее о смене состояния.
    ///   - newState: Новое состояние ICE-соединения.
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) { }
    /// Публикует событие о завершении сбора ICE-кандидатов для текущего соединения.
    /// - Parameters:
    ///   - peerConnection: Соединение, выполняющее сбор.
    ///   - newState: Текущее состояние сбора ICE-кандидатов.
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        guard newState == .complete else { return }
        let identity = ObjectIdentifier(peerConnection)
        Task { @MainActor [weak self] in
            guard let self, self.accepts(identity) else { return }
            self.emit(.iceGatheringComplete)
        }
    }
    /// Принимает уведомление об удалении кандидатов из набора ICE без отправки события сигналинга.
    /// - Parameters:
    ///   - peerConnection: Соединение, изменившее список кандидатов.
    ///   - candidates: Кандидаты, удалённые WebRTC.
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) { }
    /// Закрывает открытый канал данных: чат и управление конференцией используют авторизованный сигналинг.
    /// - Parameters:
    ///   - peerConnection: Соединение, открывшее канал.
    ///   - dataChannel: Канал данных WebRTC для закрытия.
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        dataChannel.close() // Conference control/chat use the authenticated signaling protocol.
    }

    /// Уведомляет конференцию о необходимости повторного согласования дорожек.
    /// - Parameter peerConnection: Соединение, запросившее согласование.
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        let identity = ObjectIdentifier(peerConnection)
        Task { @MainActor [weak self] in
            guard let self, self.accepts(identity) else { return }
            self.emit(.negotiationNeeded)
        }
    }

    /// Передаёт новый локальный ICE-кандидат в сигналинг текущей конференции.
    /// - Parameters:
    ///   - peerConnection: Соединение, обнаружившее кандидата.
    ///   - candidate: Новый кандидат с SDP и привязкой к медиа-секции.
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let identity = ObjectIdentifier(peerConnection)
        let candidate = ConferenceICECandidate(candidate: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex)
        Task { @MainActor [weak self] in
            guard let self, self.accepts(identity) else { return }
            self.emit(.candidate(candidate))
        }
    }

    /// Преобразует состояние WebRTC в событие подключения конференции.
    /// - Parameters:
    ///   - peerConnection: Соединение, предоставившее обновление.
    ///   - newState: Новое агрегированное состояние соединения.
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

    /// Применяет громкость к входящему звуку либо передаёт видеодорожку с идентификаторами потока и медиа-секции.
    /// - Parameters:
    ///   - peerConnection: Соединение, принявшее дорожку.
    ///   - rtpReceiver: RTP-получатель с аудио- или видеодорожкой.
    ///   - streams: Потоки, к которым WebRTC отнёс дорожку.
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver,
                                  streams: [RTCMediaStream]) {
        if let audio = rtpReceiver.track as? RTCAudioTrack {
            let identity = ObjectIdentifier(peerConnection), reference = RTCReference(audio)
            Task { @MainActor [weak self] in
                guard let self, self.accepts(identity) else { return }
                reference.value.source.volume = self.speakerVolume
            }
            return
        }
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        let identity = ObjectIdentifier(peerConnection), reference = RTCReference(track)
        let mid = peerConnection.transceivers.first { $0.receiver.receiverId == rtpReceiver.receiverId }?.mid
        let value = ConferenceVideoTrack(id: track.trackId, mid: mid, streamID: streams.first?.streamId, isLocal: false)
        Task { @MainActor [weak self] in
            guard let self, self.accepts(identity) else { return }
            self.receivedVideo(reference.value, value)
        }
    }

    /// Сообщает об удалении входящей видеодорожки текущего соединения.
    /// - Parameters:
    ///   - peerConnection: Соединение, удалившее дорожку.
    ///   - rtpReceiver: RTP-получатель удалённой дорожки.
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
