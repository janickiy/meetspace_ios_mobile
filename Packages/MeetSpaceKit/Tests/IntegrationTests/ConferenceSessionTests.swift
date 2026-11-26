import Foundation
import SwiftUI
import Testing
import MeetSpaceCore
import MeetSpaceAPI
@testable import MeetSpaceMedia
import MeetSpaceBroadcast
import MeetSpaceRealtime
@testable import MeetSpaceFeatures

@MainActor private final class StressSessionReferences {
    weak var session: ConferenceSession?
    weak var engine: SessionEngine?
    weak var broadcast: SessionBroadcast?
}

/// Real session orchestration; signaling, capture and ReplayKit are explicit doubles.
@Test @MainActor func stage08ThirtyConferenceScreenCyclesReleaseResources() async throws {
    func cycle() async throws -> StressSessionReferences {
        let (session, engine, socket, broadcast) = try await screenSession()
        let references = StressSessionReferences()
        references.session = session; references.engine = engine; references.broadcast = broadcast
        await session.prepareScreenShare()
        let lease = try #require(broadcast.sessionID)
        broadcast.event.yield(.started(lease))
        try await sessionEventually { let offers = await socket.count("media.offer"); return engine.screen && offers > 1 }
        broadcast.sendFrame(lease)
        try await sessionEventually { engine.screenFrames == 1 }
        try await acknowledgeLatestScreenOffer(socket)
        try await sessionEventually { session.screenSharing }
        #expect(await session.awaitDeparture())
        #expect(engine.closeCount == 1 && !engine.microphone && !engine.camera && !engine.screen)
        #expect(broadcast.sessionID == nil && broadcast.stops == 1)
        #expect(session.phase == .ended && session.videoTracks.isEmpty && session.participants.isEmpty)
        #expect(await socket.closes == 1)
        // Stale queued extension frames cannot revive a detached media engine.
        broadcast.sendFrame(lease, timestamp: 200_000_001)
        await Task.yield()
        #expect(engine.screenFrames == 1)
        return references
    }
    for _ in 0..<30 {
        let references = try await cycle()
        try await sessionEventually { references.session == nil && references.engine == nil && references.broadcast == nil }
    }
}

private actor SessionPermissionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var started = false
    /// Приостанавливает операцию до явного разрешения теста.
    func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
    /// Возобновляет операцию, приостановленную тестом.
    func release() { continuation?.resume(); continuation = nil }
}
private actor SessionSecrets: SecureStore {
    /// Возвращает отсутствие учётных данных в тесте с заранее авторизованным клиентом.
    /// - Parameter key: Ключ запрошенной записи.
    func read(_ key: CredentialKey) -> Data? { nil }
    /// Принимает запись учётных данных без сохранения в Keychain.
    /// - Parameters:
    ///   - value: Байты учётных данных.
    ///   - key: Ключ записи.
    func write(_ value: Data, for key: CredentialKey) {}
    /// Принимает запрос удаления без обращения к Keychain.
    /// - Parameter key: Ключ записи.
    func delete(_ key: CredentialKey) {}
}
private enum SessionFixture {
    static let room = UUID(), user = UUID(), person = UUID(), peer = UUID(), connection = UUID()
    static let origin = try! ServerOrigin("https://session.fixture.example")
    static var member: ConferenceParticipant {
        ConferenceParticipant(id: person, conferenceId: room, userId: user, displayName: "Fixture")
    }
    /// Преобразует модель через кодировщик API в JSON-объект тестового ответа.
    /// - Parameter value: Модель для сериализации.
    static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: WireJSON.encoder().encode(value))
    }
    /// Кодирует тестовый JSON-объект в байты для сетевого ответа.
    /// - Parameter value: Содержимое JSON.
    static func bytes(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    /// Возвращает HTTP 200 с JSON-телом для тестового запроса.
    /// - Parameter value: Поля тела ответа.
    static func response(_ value: [String: Any]) throws -> NetworkResponse {
        NetworkResponse(status: 200, headers: ["content-type": "application/json"], data: try bytes(value))
    }
    /// Кодирует событие сигналинга для тестового сокета.
    /// - Parameters:
    ///   - type: Тип события.
    ///   - data: Поля полезной нагрузки.
    ///   - reply: Идентификатор исходного запроса для события-ответа.
    static func event(_ type: String, _ data: [String: Any], reply: UUID? = nil) throws -> Data {
        var value: [String: Any] = ["version": 1, "id": UUID().uuidString, "type": type,
            "conferenceId": room.uuidString, "timestamp": "2026-11-05T12:00:00Z", "data": data]
        if let reply { value["replyTo"] = reply.uuidString }
        return try bytes(value)
    }
    static var policy: [String: Any] {
        ["version": 1, "microphoneBlocked": false, "cameraBlocked": false, "screenBlocked": false, "kicked": false]
    }
    /// Формирует снимок состава конференции с основным и дополнительными участниками.
    /// - Parameter additionalMembers: Участники, добавляемые к основному.
    static func roster(with additionalMembers: [ConferenceParticipant] = []) throws -> Data {
        let members = try ([member] + additionalMembers).map { participant in
            var payload = try #require(object(participant) as? [String: Any])
            payload["online"] = true
            return payload
        }
        return try event("conference.state", ["connectionId": connection.uuidString,
            "participantId": person.uuidString, "status": "active", "participants": members])
    }
    /// Готовит репозиторий конференций с тестовым аккаунтом и транспортом.
    /// - Parameter transport: Транспорт запросов к API встреч.
    static func repository(transport: SessionTransport = SessionTransport()) throws -> ConferenceRepository {
        let user = try WireJSON.decoder().decode(AccountUser.self, from: bytes([
            "id": Self.user.uuidString, "email": "fixture@example.test", "displayName": "Fixture", "isAdmin": false,
            "createdAt": "2026-11-05T12:00:00Z", "updatedAt": "2026-11-05T12:00:00Z"]))
        let account = AccountRecord(server: origin, user: user)
        let client = AuthenticatedClient(account: account,
            credentials: SessionCredentials(accessToken: "fixture", sessionCookie: nil, expiresAt: Date().addingTimeInterval(3600)),
            secureStore: SessionSecrets(), transport: transport)
        return ConferenceRepository(client: client)
    }
}
private actor SessionTransport: RequestTransport {
    var tickets = 0
    var leaves = 0
    var joins = 0
    var selfReads = 0
    var member: ConferenceParticipant = SessionFixture.member
    var leaveGate: SessionPermissionGate?
    var conferenceStatus = "active"
    var failure: (String, Int)?
    var ice = ICEConfiguration(iceServers: [ICEServer(urls: ["stun:fixture.example:3478"])])
    /// Настраивает задержку ответа на выход из встречи.
    /// - Parameter gate: Точка синхронизации для обработчика выхода.
    func blockLeave(_ gate: SessionPermissionGate) { leaveGate = gate }
    /// Заменяет участника в последующих ответах тестового сервера.
    /// - Parameter value: Актуальные данные участника.
    func setMember(_ value: ConferenceParticipant) { member = value }
    /// Задаёт состояние встречи в ответах сервера.
    /// - Parameter value: Серверное состояние конференции.
    func setConferenceStatus(_ value: String) { conferenceStatus = value }
    /// Настраивает ошибку для выбранного пути API.
    /// - Parameters:
    ///   - path: Путь запроса.
    ///   - status: Код ошибки HTTP.
    func fail(_ path: String, status: Int) { failure = (path, status) }
    /// Подменяет конфигурацию ICE для следующего ответа.
    /// - Parameter value: Конфигурация для подключения тестового клиента.
    func setICE(_ value: ICEConfiguration) { ice = value }
    /// Обрабатывает запрос к API конференции и возвращает ответ для текущего сценария.
    /// - Parameters:
    ///   - request: Запрос проверяемого клиента.
    ///   - limit: Лимит ответа из контракта транспорта.
    ///   - uploadFile: Необязательный файл для отправки.
    ///   - progress: Обработчик прогресса из контракта транспорта.
    func send(_ request: URLRequest, limit: Int, uploadFile: URL?, progress: TransferProgress?) async throws -> NetworkResponse {
        let path = request.url!.path
        if path.hasSuffix("/participants/me") { selfReads += 1 }
        if let (suffix, status) = failure, path.hasSuffix(suffix) { return NetworkResponse(status: status) }
        if path.hasSuffix("/webrtc/config") {
            return NetworkResponse(status: 200, headers: ["content-type": "application/json"], data: try WireJSON.encoder().encode(ice))
        }
        if path.hasSuffix("/ws-ticket") {
            tickets += 1
            return try SessionFixture.response(["ticket": String(repeating: "a", count: 42) + String(tickets), "expiresAt": "2099-11-05T12:00:00Z"])
        }
        if path.hasSuffix("/messages") { return try SessionFixture.response(["items": [], "unreadCount": 0]) }
        if path.hasSuffix("/join") { joins += 1; member = SessionFixture.member }
        if path.hasSuffix("/leave") { leaves += 1; if let leaveGate { await leaveGate.wait() } }
        if path.hasSuffix("/participants/me") || path.hasSuffix("/media") || path.hasSuffix("/leave") || path.hasSuffix("/join") {
            return try SessionFixture.response(["status": "success", "item": SessionFixture.object(member)])
        }
        if path == "/api/v1/conferences/" + SessionFixture.room.uuidString.lowercased() {
            let conference = Conference(id: SessionFixture.room, ownerId: SessionFixture.user, title: "Fixture", status: conferenceStatus)
            return try SessionFixture.response(["status": "success", "item": SessionFixture.object(conference)])
        }
        throw APIError.httpStatus(404)
    }
}
private actor SessionSocket: ConferenceSocket {
    let stream: AsyncThrowingStream<Data, Error>
    let continuation: AsyncThrowingStream<Data, Error>.Continuation
    var sent: [ConferenceEnvelope] = []
    var closes = 0
    /// Создаёт управляемый тестом поток входящих сообщений сокета.
    init() { (stream, continuation) = AsyncThrowingStream.makeStream() }
    /// Декодирует и сохраняет исходящую команду конференции для последующей проверки.
    /// - Parameter data: Байты команды сигналинга.
    func send(_ data: Data) throws { sent.append(try ConferenceEnvelope.decode(data, conferenceID: SessionFixture.room)) }
    /// Ожидает очередное сообщение из входящего потока тестового сокета.
    func receive() async throws -> Data {
        var iterator = stream.makeAsyncIterator()
        guard let result = try await iterator.next() else { throw ConferenceSignalError.disconnected(retryable: true) }
        return result
    }
    /// Закрывает поток сообщений и учитывает закрытие тестового соединения.
    func close() { closes += 1; continuation.finish() }
    /// Помещает сообщение во входящий поток тестового сокета.
    /// - Parameter data: Байты входящего сообщения.
    func emit(_ data: Data) { continuation.yield(data) }
    /// Возвращает последнюю отправленную команду заданного типа.
    /// - Parameter type: Тип команды сигналинга.
    func last(_ type: String) -> ConferenceEnvelope? { sent.last { $0.type == type } }
    /// Подсчитывает отправленные команды одного типа.
    /// - Parameter type: Тип команды сигналинга.
    func count(_ type: String) -> Int { sent.filter { $0.type == type }.count }
}
private actor SessionSockets: ConferenceSocketFactory {
    var sockets: [SessionSocket] = []
    var calls = 0
    let fail: Bool?
    /// Настраивает фабрику сокетов на успешное или неуспешное подключение.
    /// - Parameter fail: Признак возможности повтора ошибки подключения или `nil` для успеха.
    init(fail: Bool? = nil) { self.fail = fail }
    /// Создаёт и учитывает сокет конференции или выбрасывает настроенную ошибку.
    /// - Parameters:
    ///   - origin: Сервер встречи.
    ///   - conferenceID: Идентификатор встречи.
    ///   - ticket: Билет подключения.
    func connect(origin: ServerOrigin, conferenceID: UUID, ticket: String) throws -> any ConferenceSocket {
        calls += 1
        if let fail { throw ConferenceSignalError.disconnected(retryable: fail) }
        let socket = SessionSocket(); sockets.append(socket); return socket
    }
}
@MainActor private final class SessionEngine: ConferenceMediaEngine {
    let events: AsyncStream<ConferenceMediaEvent>
    let continuation: AsyncStream<ConferenceMediaEvent>.Continuation
    let localVideoTrackID = UUID().uuidString
    var configuration: ConferenceMediaConfiguration?
    var microphone = false, camera = false, closed = false
    var microphoneAllowed = true, cameraAllowed = true, screenAllowed = false
    var screen = false, rollbacks = 0, screenFrames = 0
    var closeCount = 0, offers = 0
    var microphoneGate: SessionPermissionGate?
    var sampledLevels = ConferenceMicrophoneLevels()
    /// Готовит поток событий тестового медиадвижка.
    init() { (events, continuation) = AsyncStream.makeStream() }
    var localScreenVideoTrackID: String { "fixture-screen" }
    /// Учитывает откат локального предложения SDP.
    func rollbackLocalOffer() async throws { rollbacks += 1 }
    /// Имитирует изменение публикации экрана с проверкой разрешений.
    /// - Parameter enabled: Запрошенное состояние публикации.
    func setScreenEnabled(_ enabled: Bool) async throws {
        guard !enabled || (screenAllowed && cameraAllowed) else { throw ConferenceMediaError.publicationBlocked }
        screen = enabled; continuation.yield(.screenCaptureState(enabled))
        continuation.yield(.negotiationNeeded)
    }
    /// Учитывает кадр демонстрации, переданный тестовому движку.
    /// - Parameter frame: Полученный кадр.
    func pushScreenFrame(_ frame: ScreenBroadcastFrame) throws { screenFrames += 1 }
    /// Запоминает конфигурацию подключения тестового медиадвижка.
    /// - Parameter configuration: Параметры медиасоединения.
    func configure(_ configuration: ConferenceMediaConfiguration) {
        self.configuration = configuration
        microphoneAllowed = configuration.microphoneAllowed; cameraAllowed = configuration.cameraAllowed
    }
    /// Формирует тестовое предложение SDP для переговоров.
    /// - Parameter iceRestart: Запрошен ли перезапуск ICE.
    func makeOffer(iceRestart: Bool) throws -> ConferenceMediaOffer {
        guard !closed else { throw CancellationError() }; offers += 1
        return ConferenceMediaOffer(sdp: "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:0\r\na=recvonly\r\n", publications: screen ? [.init(mid: "2", source: "video/screen", trackId: localScreenVideoTrackID)] : [])
    }
    /// Принимает ответ SDP, пока тестовое соединение открыто.
    /// - Parameter sdp: Описание медиа от удалённой стороны.
    func applyAnswer(_ sdp: String) throws { if closed { throw CancellationError() } }
    /// Принимает ICE-кандидата без установки сетевого соединения.
    /// - Parameter candidate: Кандидат удалённой стороны.
    func addRemoteCandidate(_ candidate: MeetSpaceMedia.ConferenceICECandidate) {}
    /// Применяет к тестовой сессии права на публикацию источников.
    /// - Parameters:
    ///   - microphone: Разрешение микрофона.
    ///   - camera: Разрешение камеры.
    ///   - screen: Разрешение демонстрации экрана.
    func setPublicationPermissions(microphone: Bool, camera: Bool, screen: Bool) {
        microphoneAllowed = microphone; cameraAllowed = camera; screenAllowed = screen && camera
        if !microphone { self.microphone = false }; if !camera { self.camera = false }
        capture()
    }
    /// Меняет состояние тестового микрофона и сообщает о захвате.
    /// - Parameter enabled: Запрошенное состояние микрофона.
    func setMicrophoneEnabled(_ enabled: Bool) async throws {
        if enabled, let microphoneGate { await microphoneGate.wait() }
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        guard !enabled || microphoneAllowed else { throw ConferenceMediaError.publicationBlocked }
        microphone = enabled; capture(); continuation.yield(.negotiationNeeded)
    }
    /// Имитирует смену состояния камеры с учётом разрешения тестовой сессии.
    /// - Parameter enabled: Запрошенное состояние камеры.
    func setCameraEnabled(_ enabled: Bool) throws {
        guard !closed, !enabled || cameraAllowed else { throw ConferenceMediaError.publicationBlocked }
        camera = enabled; capture(); continuation.yield(.negotiationNeeded)
    }
    /// Принимает команду переключения камеры без обращения к устройству.
    func switchCamera() {}
    /// Возвращает подготовленные уровни звука участников конференции.
    func microphoneLevels() async -> ConferenceMicrophoneLevels { sampledLevels }
    /// Принимает переключение громкой связи без изменения системного аудиомаршрута.
    /// - Parameter enabled: Желаемое состояние громкой связи.
    func setSpeakerEnabled(_ enabled: Bool) {}
    /// Приостанавливает тестовые микрофон и камеру и сообщает об изменении состояния.
    func suspend() { microphone = false; camera = false; capture() }
    /// Закрывает медиадвижок и завершает тестовый поток событий.
    func close() { closed = true; microphone = false; camera = false; closeCount += 1; continuation.finish() }
    /// Возвращает прозрачную заглушку видеоплитки.
    /// - Parameters:
    ///   - trackID: Идентификатор запрошенной дорожки.
    ///   - mirrored: Запрошено ли зеркальное отображение.
    func videoView(trackID: String, mirrored: Bool) -> AnyView { AnyView(Color.clear) }
    /// Передаёт событие медиадвижка в тестируемую сессию.
    /// - Parameter value: Медиасобытие для доставки.
    func emit(_ value: ConferenceMediaEvent) { continuation.yield(value) }
    /// Публикует текущие флаги тестового микрофона и камеры.
    private func capture() { continuation.yield(.captureState(microphone: microphone, camera: camera, frontCamera: true)) }
}
@MainActor private func sessionEventually(_ predicate: @escaping @MainActor () async -> Bool) async throws {
    for _ in 0..<250 {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(4))
    }
    throw APIError.timeout
}
@MainActor private func joinSession(_ session: ConferenceSession, sockets: SessionSockets,
                                   catalog: [[String: Any]] = [], workerICE: [ICEServer]? = nil) async throws -> SessionSocket {
    session.start()
    try await sessionEventually { await sockets.sockets.count == 1 }
    let socket = try #require(await sockets.sockets.first)
    await socket.emit(try SessionFixture.roster())
    try await sessionEventually { await socket.last("media.join") != nil }
    let request = try #require(await socket.last("media.join"))
    var joined: [String: Any] = ["mediaPeerId": SessionFixture.peer.uuidString,
        "maxPeers": 8, "tracks": catalog, "policy": SessionFixture.policy,
        "videoCapture": ["maxWidth": 1280, "maxHeight": 720, "maxFrameRate": 30]]
    if let workerICE { joined["iceServers"] = try SessionFixture.object(workerICE) }
    await socket.emit(try SessionFixture.event("media.joined", joined, reply: request.id))
    try await sessionEventually { await socket.last("media.offer") != nil }
    return socket
}
@MainActor private func answerSession(_ socket: SessionSocket, sdp: String = "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:0\r\n") async throws -> ConferenceEnvelope {
    let offer = try #require(await socket.last("media.offer"))
    struct Offer: Decodable { let negotiationId: String }
    await socket.emit(try SessionFixture.event("media.answer", ["mediaPeerId": SessionFixture.peer.uuidString,
        "negotiationId": offer.payload(Offer.self).negotiationId, "sdp": sdp], reply: offer.id))
    try await sessionEventually { await socket.last("media.ready") != nil }
    return try #require(await socket.last("media.ready"))
}

@Test @MainActor func conferenceSessionAppliesCameraChosenBeforeJoining() async throws {
    let sockets = SessionSockets(), engine = SessionEngine()
    let session = ConferenceSession(repository: try SessionFixture.repository(), title: "Fixture",
                                    participant: SessionFixture.member, sockets: sockets, makeMedia: { engine })
    session.choosePrejoinCamera(.back)
    #expect(session.media == nil)
    _ = try await joinSession(session, sockets: sockets)
    #expect(engine.configuration?.preferFrontCamera == false)
    await session.leave()
}

@Test @MainActor func conferenceSessionWaitsForReadyAcknowledgementAndRTCConnection() async throws {
    let sockets = SessionSockets(), engine = SessionEngine()
    let session = ConferenceSession(repository: try SessionFixture.repository(), title: "Fixture", participant: SessionFixture.member,
        sockets: sockets, makeMedia: { engine })
    let socket = try await joinSession(session, sockets: sockets)
    engine.emit(.connectionState(.connected))
    let ready = try await answerSession(socket)
    #expect(session.phase == .connecting)
    await socket.emit(try SessionFixture.event("ack", ["type": "media.ready"], reply: UUID()))
    try await Task.sleep(for: .milliseconds(15))
    #expect(session.phase == .connecting)
    await socket.emit(try SessionFixture.event("ack", ["type": "media.ready"], reply: ready.id))
    try await sessionEventually { session.phase == .connected }
    #expect(engine.configuration?.iceServers.first?.urls == ["stun:fixture.example:3478"])
    await session.leave()
    #expect(engine.closed && session.videoTracks.isEmpty && session.phase == .ended)
}

@MainActor private final class SessionBroadcast: ScreenBroadcastController {
    let events: AsyncStream<ScreenBroadcastEvent>
    let event: AsyncStream<ScreenBroadcastEvent>.Continuation
    let frames: AsyncStream<ScreenBroadcastFrame>
    let frame: AsyncStream<ScreenBroadcastFrame>.Continuation
    var isAvailable = true
    let extensionBundleID: String? = "fixture.broadcast"
    var sessionID: UUID?
    var stops = 0
    /// Готовит отдельные потоки кадров и событий демонстрации.
    init() {
        (events, event) = AsyncStream.makeStream()
        (frames, frame) = AsyncStream.makeStream()
    }
    /// Выдаёт идентификатор новому тестовому сеансу трансляции.
    /// - Parameter configuration: Параметры подготовки трансляции.
    func prepare(configuration: ScreenBroadcastConfiguration) { sessionID = UUID() }
    /// Завершает тестовый сеанс трансляции и учитывает остановку.
    func stop() { stops += 1; sessionID = nil }
    /// Отправляет синтетический кадр в тестовый поток.
    /// - Parameters:
    ///   - id: Идентификатор сеанса трансляции.
    ///   - timestamp: Временная метка кадра в наносекундах.
    func sendFrame(_ id: UUID, timestamp: Int64 = 1) {
        frame.yield(ScreenBroadcastFrame(sessionID: id, width: 2, height: 2, rowBytes: 8,
            timestampNs: timestamp, pixels: Data(repeating: 0, count: 16)))
    }
}
@MainActor private func acknowledgeLatestScreenOffer(_ socket: SessionSocket) async throws {
    let before = await socket.count("media.ready")
    let offer = try #require(await socket.last("media.offer"))
    struct Offer: Decodable { let negotiationId: String }
    await socket.emit(try SessionFixture.event("media.answer", ["mediaPeerId": SessionFixture.peer.uuidString,
        "negotiationId": offer.payload(Offer.self).negotiationId, "sdp": "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:0\r\n"], reply: offer.id))
    try await sessionEventually { await socket.count("media.ready") > before }
    let ready = try #require(await socket.last("media.ready"))
    await socket.emit(try SessionFixture.event("ack", ["type": "media.ready"], reply: ready.id))
    try await Task.sleep(for: .milliseconds(15))
}
@MainActor private func screenSession() async throws -> (ConferenceSession, SessionEngine, SessionSocket, SessionBroadcast) {
    let sockets = SessionSockets(), engine = SessionEngine(), broadcast = SessionBroadcast()
    let session = ConferenceSession(repository: try SessionFixture.repository(), title: "Fixture", participant: SessionFixture.member,
        sockets: sockets, makeMedia: { engine }, makeBroadcast: { broadcast })
    let socket = try await joinSession(session, sockets: sockets)
    engine.emit(.connectionState(.connected))
    try await acknowledgeLatestScreenOffer(socket)
    try await sessionEventually { session.phase == .connected }
    return (session, engine, socket, broadcast)
}

@Test @MainActor func screenConsentFrameAndServerAckAreAllRequiredAndStopFencesFrames() async throws {
    let (session, engine, socket, broadcast) = try await screenSession()
    await session.prepareScreenShare()
    let id = try #require(broadcast.sessionID)
    #expect(session.screenShareState == .awaitingSystem && !engine.screen)
    broadcast.event.yield(.started(id))
    try await sessionEventually { let count = await socket.count("media.offer"); return engine.screen && count > 1 }
    broadcast.sendFrame(id)
    try await sessionEventually { engine.screenFrames == 1 }
    #expect(!session.screenSharing)
    try await acknowledgeLatestScreenOffer(socket)
    try await sessionEventually { session.screenSharing }
    for _ in 0..<3 {
        let offers = await socket.count("media.offer"), answers = await socket.count("media.ready")
        if offers > answers { try await acknowledgeLatestScreenOffer(socket) }
    }
    let offers = await socket.count("media.offer")
    await session.stopScreenShare()
    #expect(!engine.screen && !session.screenSharing && broadcast.stops == 1)
    broadcast.sendFrame(id, timestamp: 200_000_001)
    try await Task.sleep(for: .milliseconds(20))
    #expect(engine.screenFrames == 1)
    try await sessionEventually { await socket.count("media.offer") > offers }
    try await acknowledgeLatestScreenOffer(socket)
    // An already queued negotiationNeeded may require one final coalesced empty offer.
    if session.screenShareState == .stopping { try await acknowledgeLatestScreenOffer(socket) }
    try await sessionEventually { session.screenShareState == .idle }
    await session.leave()
}

@Test @MainActor func screenConflictRollsBackOnlyScreenAndKeepsConversation() async throws {
    let (session, engine, socket, broadcast) = try await screenSession()
    engine.microphone = true; engine.camera = true
    engine.emit(.captureState(microphone: true, camera: true, frontCamera: true))
    await session.prepareScreenShare()
    let id = try #require(broadcast.sessionID)
    broadcast.event.yield(.started(id))
    try await sessionEventually { let count = await socket.count("media.offer"); return engine.screen && count > 1 }
    let rejected = try #require(await socket.last("media.offer"))
    await socket.emit(try SessionFixture.event("error", ["code": "screen_sharing_conflict", "message": "Screen busy"], reply: rejected.id))
    try await sessionEventually { engine.rollbacks == 1 && !engine.screen && broadcast.stops == 1 }
    #expect(engine.microphone && engine.camera && !engine.closed && session.phase == .connected)
    #expect(session.screenShareError != nil)
    await session.leave()
}

@Test @MainActor func screenStopDuringPendingStartWaitsForRemovalAcknowledgement() async throws {
    let (session, engine, socket, broadcast) = try await screenSession()
    await session.prepareScreenShare()
    let id = try #require(broadcast.sessionID)
    broadcast.event.yield(.started(id))
    try await sessionEventually { let count = await socket.count("media.offer"); return engine.screen && count > 1 }
    let startOffer = try #require(await socket.last("media.offer"))
    await session.stopScreenShare()
    #expect(session.screenShareState == .stopping && !engine.screen && broadcast.stops == 1)
    #expect(!session.canStartScreenShare)
    try await acknowledgeLatestScreenOffer(socket)
    try await sessionEventually { await socket.last("media.offer")?.id != startOffer.id }
    #expect(session.screenShareState == .stopping && !session.screenSharing)
    try await acknowledgeLatestScreenOffer(socket)
    try await sessionEventually { session.screenShareState == .idle }
    await session.leave()
}

@Test @MainActor func screenPolicyAndOldLeaseCannotResumeCapture() async throws {
    let (session, engine, socket, broadcast) = try await screenSession()
    await session.prepareScreenShare()
    let id = try #require(broadcast.sessionID)
    broadcast.event.yield(.started(id))
    try await sessionEventually { engine.screen }
    var policy = SessionFixture.policy; policy["version"] = 2; policy["screenBlocked"] = true
    await socket.emit(try SessionFixture.event("media.policy", ["mediaPeerId": SessionFixture.peer.uuidString, "policy": policy]))
    try await sessionEventually { session.screenBlocked && !engine.screen && broadcast.stops == 1 }
    broadcast.event.yield(.resumed(id)); broadcast.sendFrame(id)
    try await Task.sleep(for: .milliseconds(20))
    #expect(!engine.screen && engine.screenFrames == 0 && !session.canStartScreenShare)
    await session.leave()
}

@Test @MainActor func screenKeepsTransportInBackgroundAndLeaveRevokesLease() async throws {
    let (session, engine, socket, broadcast) = try await screenSession()
    await session.prepareScreenShare()
    let id = try #require(broadcast.sessionID)
    broadcast.event.yield(.started(id))
    try await sessionEventually { engine.screen }
    await session.setForeground(false)
    #expect(!engine.closed && !engine.microphone && !engine.camera)
    await session.leave()
    let closes = await socket.closes
    #expect(engine.closed && broadcast.stops == 1 && closes == 1)
    broadcast.sendFrame(id)
    #expect(engine.screenFrames == 0)
}

@Test @MainActor func conferenceSessionProcessesModerationDuringPendingPermission() async throws {
    let sockets = SessionSockets(), engine = SessionEngine(), gate = SessionPermissionGate()
    engine.microphoneGate = gate
    let session = ConferenceSession(repository: try SessionFixture.repository(), title: "Fixture", participant: SessionFixture.member,
        sockets: sockets, makeMedia: { engine })
    session.wantsMicrophone = true
    let socket = try await joinSession(session, sockets: sockets)
    try await sessionEventually { await gate.started }
    var policy = SessionFixture.policy; policy["version"] = 2; policy["microphoneBlocked"] = true
    await socket.emit(try SessionFixture.event("media.policy", ["mediaPeerId": SessionFixture.peer.uuidString, "policy": policy]))
    try await sessionEventually { session.microphoneBlocked && !engine.microphoneAllowed }
    await gate.release()
    try await Task.sleep(for: .milliseconds(15))
    #expect(!engine.microphone && !session.microphone && !session.wantsMicrophone)
    await session.leave()
}

@Test @MainActor func conferenceSessionBackgroundInvalidatesPendingPermissionAndUsesFreshEngine() async throws {
    let sockets = SessionSockets(), gate = SessionPermissionGate()
    var engines: [SessionEngine] = []
    let session = ConferenceSession(repository: try SessionFixture.repository(), title: "Fixture", participant: SessionFixture.member,
        sockets: sockets, makeMedia: { let engine = SessionEngine(); if engines.isEmpty { engine.microphoneGate = gate }; engines.append(engine); return engine })
    session.wantsMicrophone = true
    _ = try await joinSession(session, sockets: sockets)
    try await sessionEventually { await gate.started }
    await session.setForeground(false)
    #expect(session.phase == .suspended && engines[0].closed)
    await session.setForeground(true)
    try await sessionEventually { await sockets.sockets.count == 2 }
    await gate.release()
    try await Task.sleep(for: .milliseconds(15))
    #expect(!engines[0].microphone && !session.microphone && !session.wantsMicrophone)
    #expect(session.phase == .connecting)
    #expect(await sockets.calls == 2)
    await session.leave()
}

@Test @MainActor func conferenceSessionRetriesAreBoundedAndAuthorizationFailureIsTerminal() async throws {
    for retryable in [true, false] {
        let sockets = SessionSockets(fail: retryable)
        let session = ConferenceSession(repository: try SessionFixture.repository(), title: "Fixture", participant: SessionFixture.member,
            sockets: sockets, makeMedia: { SessionEngine() }, sleep: { _ in try await Task.sleep(for: .milliseconds(1)) })
        session.start()
        try await sessionEventually { session.phase == .failed }
        let calls = await sockets.calls
        #expect(calls == (retryable ? 4 : 1))
        await session.leave()
    }
}

@Test @MainActor func conferenceSessionReadyWithoutICEConnectionTimesOutAndCleansMedia() async throws {
    let sockets = SessionSockets(), engine = SessionEngine()
    let session = ConferenceSession(repository: try SessionFixture.repository(), title: "Fixture", participant: SessionFixture.member,
        sockets: sockets, makeMedia: { engine }, sleep: { seconds in
            try await Task.sleep(for: .seconds(seconds == 30 ? 0.03 : seconds))
        })
    let socket = try await joinSession(session, sockets: sockets)
    let ready = try await answerSession(socket)
    await socket.emit(try SessionFixture.event("ack", ["type": "media.ready"], reply: ready.id))
    try await sessionEventually { engine.closed }
    #expect(session.phase == .reconnecting && !session.microphone && !session.camera)
    await session.leave()
}

@Test @MainActor func conferenceSessionMapsNativeTrackThroughSDPMidAndCatalog() async throws {
    let sockets = SessionSockets(), engine = SessionEngine(), trackID = UUID(), owner = UUID(), remotePeer = UUID()
    let catalog: [[String: Any]] = [["id": trackID.uuidString, "streamId": remotePeer.uuidString.lowercased(),
        "mediaPeerId": remotePeer.uuidString, "participantId": owner.uuidString, "kind": "video", "source": "camera"]]
    let session = ConferenceSession(repository: try SessionFixture.repository(), title: "Fixture", participant: SessionFixture.member,
        sockets: sockets, makeMedia: { engine })
    let socket = try await joinSession(session, sockets: sockets, catalog: catalog)
    let native = ConferenceVideoTrack(id: "native-reused-receiver", mid: "1", streamID: nil, isLocal: false)
    engine.emit(.videoTrackAdded(native))
    #expect(session.videoTracks.isEmpty)
    _ = try await answerSession(socket, sdp: "v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\na=mid:1\r\na=sendonly\r\na=msid:\(remotePeer.uuidString.lowercased()) \(trackID.uuidString.lowercased())\r\n")
    try await sessionEventually { session.videoTracks.count == 1 }
    #expect(session.videoTracks[0].id == native.id && session.participantID(for: native) == owner)
    await socket.emit(try SessionFixture.event("media.tracks", ["mediaPeerId": SessionFixture.peer.uuidString, "revision": 2, "tracks": []]))
    try await sessionEventually { session.videoTracks.isEmpty }
    await session.leave()
}

@Test func conferenceAudioSampleUsesIntervalEnergyAndRejectsStaleLevels() {
    let previous = ConferenceAudioSample(level: 0.9, energy: 1, duration: 10, packets: 20)
    let current = ConferenceAudioSample(level: 0.9, energy: 1.25, duration: 11, packets: 21)
    #expect(current.rms(since: previous) == 0.5)
    let silent = ConferenceAudioSample(level: 0.9, energy: 1.25, duration: 12, packets: 22)
    #expect(silent.rms(since: current) == 0)
    let stale = ConferenceAudioSample(level: 0.9, energy: 1.5, duration: 12, packets: 21)
    #expect(stale.rms(since: current) == 0)
    let instantaneous = ConferenceAudioSample(level: 0.25, energy: nil, duration: nil, packets: nil)
    #expect(instantaneous.rms(since: nil) == 0.25)
}

@Test @MainActor func conferenceMetersOnlySpeakingMicrophoneTracksAndClearsSilence() async throws {
    let sockets = SessionSockets(), engine = SessionEngine()
    let remote = ConferenceParticipant(id: UUID(), conferenceId: SessionFixture.room, userId: UUID(),
                                       displayName: "Remote", microphoneEnabled: true)
    let peer = UUID().uuidString.lowercased()
    let voice = UUID().uuidString.lowercased(), screen = UUID().uuidString.lowercased()
    let catalog: [[String: Any]] = [
        ["id": voice, "streamId": peer, "mediaPeerId": peer, "participantId": remote.id.uuidString,
         "kind": "audio", "source": "microphone"],
        ["id": screen, "streamId": peer + "-screen", "mediaPeerId": peer, "participantId": remote.id.uuidString,
         "kind": "audio", "source": "audio/screen"]
    ]
    let session = ConferenceSession(repository: try SessionFixture.repository(), title: "Fixture",
                                    participant: SessionFixture.member, sockets: sockets, makeMedia: { engine })
    let socket = try await joinSession(session, sockets: sockets, catalog: catalog)
    await socket.emit(try SessionFixture.roster(with: [remote]))
    engine.emit(.connectionState(.connected))
    let sdp = "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:1\r\na=sendonly\r\na=msid:\(peer) \(voice)\r\n"
        + "m=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:2\r\na=sendonly\r\na=msid:\(peer)-screen \(screen)\r\n"
    let ready = try await answerSession(socket, sdp: sdp)
    await socket.emit(try SessionFixture.event("ack", ["type": "media.ready"], reply: ready.id))
    try await sessionEventually { session.phase == .connected }

    engine.sampledLevels = .init(local: 0.5, remoteByMID: ["1": 0.04, "2": 1, "unknown": 1])
    try await sessionEventually { session.microphoneLevels[remote.id] != nil }
    let quietVoice = try #require(session.microphoneLevels[remote.id])
    #expect(session.microphoneLevels[SessionFixture.person] == nil)
    engine.sampledLevels = .init(local: 0.5, remoteByMID: ["1": 0.3, "2": 1, "unknown": 1])
    try await sessionEventually { (session.microphoneLevels[remote.id] ?? 0) > quietVoice }

    engine.emit(.captureState(microphone: true, camera: false, frontCamera: true))
    try await sessionEventually {
        session.microphoneLevels[SessionFixture.person] != nil && session.microphoneLevels[remote.id] != nil
    }
    // The remote microphone still sends audio packets, but now carries only room noise.
    engine.sampledLevels = .init(local: 0.5, remoteByMID: ["1": 0.001, "2": 1, "unknown": 1])
    try await sessionEventually {
        session.microphoneLevels[SessionFixture.person] != nil && session.microphoneLevels[remote.id] == nil
    }
    engine.emit(.captureState(microphone: false, camera: false, frontCamera: true))
    engine.sampledLevels = .init(local: 0.5, remoteByMID: ["1": 0.3])
    try await sessionEventually {
        session.microphoneLevels[SessionFixture.person] == nil && session.microphoneLevels[remote.id] != nil
    }

    await socket.emit(try SessionFixture.event("media.tracks", ["mediaPeerId": SessionFixture.peer.uuidString,
        "revision": 2, "tracks": []]))
    try await sessionEventually { session.tracks.isEmpty && session.microphoneLevels.isEmpty }
    await session.leave()
    #expect(session.microphoneLevels.isEmpty)
}

@Test @MainActor func conferenceSessionLeaveReleasesCaptureBeforeUnresponsiveServer() async throws {
    let transport = SessionTransport(), leaveGate = SessionPermissionGate(), sockets = SessionSockets(), engine = SessionEngine()
    await transport.blockLeave(leaveGate)
    let session = ConferenceSession(repository: try SessionFixture.repository(transport: transport), title: "Fixture", participant: SessionFixture.member,
        sockets: sockets, makeMedia: { engine })
    _ = try await joinSession(session, sockets: sockets)
    await session.leave()
    #expect(session.phase == .ended && engine.closed && session.media == nil)
    try await sessionEventually { await leaveGate.started }
    await leaveGate.release()
}

@Test @MainActor func conferenceSessionKickClosesPendingCaptureWithoutAnotherRESTRead() async throws {
    let sockets = SessionSockets(), engine = SessionEngine(), gate = SessionPermissionGate()
    engine.microphoneGate = gate
    let session = ConferenceSession(repository: try SessionFixture.repository(), title: "Fixture", participant: SessionFixture.member,
        sockets: sockets, makeMedia: { engine })
    session.wantsMicrophone = true
    let socket = try await joinSession(session, sockets: sockets)
    try await sessionEventually { await gate.started }
    let kicked = ConferenceParticipant(id: SessionFixture.person, conferenceId: SessionFixture.room,
        userId: SessionFixture.user, displayName: "Fixture", status: "kicked", mediaPolicyVersion: 2)
    await socket.emit(try SessionFixture.event("participant.kicked", ["participant": SessionFixture.object(kicked)]))
    try await sessionEventually { session.phase == .ended && engine.closed }
    await gate.release()
    try await Task.sleep(for: .milliseconds(15))
    #expect(!engine.microphone && !session.microphone && session.media == nil)
    #expect(await sockets.calls == 1)
}

@Test @MainActor func conferenceSessionUsesAssignedWorkerICEAndKeepsRESTPolicy() async throws {
    let transport = SessionTransport(), sockets = SessionSockets(), engine = SessionEngine()
    await transport.setICE(ICEConfiguration(iceServers: [ICEServer(urls: ["turn:rest.fixture.example:3478"])],
        iceTransportPolicy: "relay", expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970))
    let worker = ICEServer(urls: ["turns:worker.fixture.example:5349"], username: "ephemeral", credential: "fixture")
    let session = ConferenceSession(repository: try SessionFixture.repository(transport: transport), title: "Fixture",
        participant: SessionFixture.member, sockets: sockets, makeMedia: { engine })
    _ = try await joinSession(session, sockets: sockets, workerICE: [worker])
    #expect(engine.configuration?.iceServers == [worker])
    #expect(engine.configuration?.iceTransportPolicy == "relay")
    #expect(await session.awaitDeparture())
}

@Test @MainActor func conferenceSessionDepartureWaitsForRESTCompletion() async throws {
    let transport = SessionTransport(), gate = SessionPermissionGate()
    await transport.blockLeave(gate)
    let session = ConferenceSession(repository: try SessionFixture.repository(transport: transport), title: "Fixture",
        participant: SessionFixture.member)
    await session.leave()
    var completed = false
    let barrier = Task { let result = await session.awaitDeparture(); completed = true; return result }
    try await sessionEventually { await gate.started }
    try await Task.sleep(for: .milliseconds(15))
    #expect(!completed && session.phase == .ended && !session.departureUncertain)
    #expect(await transport.leaves == 1)
    await gate.release()
    #expect(await barrier.value)
    #expect(await session.awaitDeparture())
    #expect(await transport.leaves == 1)
}

@Test @MainActor func conferenceSessionUnresponsiveDepartureStaysUnsafeAfterLateCompletion() async throws {
    let transport = SessionTransport(), gate = SessionPermissionGate()
    await transport.blockLeave(gate)
    let session = ConferenceSession(repository: try SessionFixture.repository(transport: transport), title: "Fixture",
        participant: SessionFixture.member, sleep: { _ in try await Task.sleep(for: .milliseconds(20)) })
    await session.leave()
    try await sessionEventually { await gate.started }
    #expect(await session.awaitDeparture() == false)
    #expect(session.departureUncertain && session.phase == .ended)
    await gate.release()
    try await Task.sleep(for: .milliseconds(15))
    #expect(await session.awaitDeparture() == false)
    #expect(await transport.leaves == 1)
}

@Test @MainActor func conferenceSessionScheduledMembershipRejoinsAfterRoomStarts() async throws {
    let transport = SessionTransport(), sockets = SessionSockets()
    let left = ConferenceParticipant(id: SessionFixture.person, conferenceId: SessionFixture.room,
        userId: SessionFixture.user, displayName: "Fixture", status: "left")
    await transport.setMember(left); await transport.setConferenceStatus("scheduled")
    let session = ConferenceSession(repository: try SessionFixture.repository(transport: transport), title: "Fixture",
        participant: left, sockets: sockets, makeMedia: { SessionEngine() })
    session.start()
    try await sessionEventually { session.phase == .prejoin }
    #expect(await transport.joins == 0)
    #expect(await sockets.calls == 0)
    await transport.setConferenceStatus("active")
    session.start()
    try await sessionEventually { await sockets.calls == 1 }
    #expect(await transport.joins == 1)
    #expect(session.participant.canParticipate)
    #expect(await session.awaitDeparture())
}

@Test @MainActor func conferenceSessionLobbyStopsOnTerminalAuthorizationFailure() async throws {
    let transport = SessionTransport()
    await transport.fail("/participants/me", status: 403)
    let waiting = ConferenceParticipant(id: SessionFixture.person, conferenceId: SessionFixture.room,
        userId: SessionFixture.user, displayName: "Fixture", status: "waiting", admissionState: "waiting")
    let session = ConferenceSession(repository: try SessionFixture.repository(transport: transport), title: "Fixture",
        participant: waiting, sleep: { _ in try await Task.sleep(for: .milliseconds(1)) })
    session.observeLobby()
    try await sessionEventually { session.phase == .failed }
    try await Task.sleep(for: .milliseconds(15))
    #expect(await transport.selfReads == 1)
    await session.leave()
}

@Test @MainActor func conferenceSessionWorkerMediaErrorIsPeerScopedAndTerminal() async throws {
    let sockets = SessionSockets(), engine = SessionEngine()
    let session = ConferenceSession(repository: try SessionFixture.repository(), title: "Fixture", participant: SessionFixture.member,
        sockets: sockets, makeMedia: { engine })
    let socket = try await joinSession(session, sockets: sockets)
    await socket.emit(try SessionFixture.event("media.error", ["mediaPeerId": UUID().uuidString, "code": "unsupported_codec_or_simulcast"]))
    try await Task.sleep(for: .milliseconds(15))
    #expect(session.phase == .connecting && !engine.closed)
    await socket.emit(try SessionFixture.event("media.error", ["mediaPeerId": SessionFixture.peer.uuidString, "code": "unsupported_codec_or_simulcast"]))
    try await sessionEventually { session.phase == .failed && engine.closed }
    #expect(await sockets.calls == 1)
    await session.leave()
}

@Test @MainActor func conferenceSessionDoesNotRetryHTTPValidationFailure() async throws {
    let transport = SessionTransport(), sockets = SessionSockets()
    await transport.fail("/participants/me", status: 422)
    let session = ConferenceSession(repository: try SessionFixture.repository(transport: transport), title: "Fixture",
        participant: SessionFixture.member, sockets: sockets, sleep: { _ in try await Task.sleep(for: .milliseconds(1)) })
    session.start()
    try await sessionEventually { session.phase == .failed }
    try await Task.sleep(for: .milliseconds(15))
    #expect(await transport.selfReads == 1)
    #expect(await sockets.calls == 0)
    await session.leave()
}
