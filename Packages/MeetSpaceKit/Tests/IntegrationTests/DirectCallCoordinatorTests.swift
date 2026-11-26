import Foundation
import SwiftUI
import Testing
import MeetSpaceCore
import MeetSpaceAPI
import MeetSpaceMedia
import MeetSpaceBroadcast
import MeetSpaceRealtime
import MeetSpaceCalling
@testable import MeetSpaceFeatures

@MainActor private final class StressCallReferences {
    weak var coordinator: DirectCallCoordinator?
    weak var engine: CallEngine?
}

/// Exercises the production coordinator and session, not native CallKit/audio hardware.
@Test @MainActor func stage08ThirtyDirectCallAnswerEndCyclesReleaseResources() async throws {
    func cycle() async throws -> StressCallReferences {
        let service = CallService(CallFixture.value(incoming: true)), system = CallSystem()
        let sockets = CallSockets(), engine = CallEngine()
        let calls = try coordinator(service, system: system, sockets: sockets, engine: engine)
        let references = StressCallReferences(); references.coordinator = calls; references.engine = engine
        await calls.reconcile(); await calls.answer()
        try await callEventually { await sockets.created.first?.ready != nil }
        let socket = try #require(await sockets.created.first)
        try await socket.acknowledge()
        let action = try #require(system.lastAnswer)
        // Session.phase changes before its coordinator callback Task runs. Wait for the
        // actual CallKit action result, not merely the preceding media state transition.
        try await callEventually { system.completed.contains { $0.0 == action.id } }
        #expect(calls.mediaSession?.phase == .connected)
        #expect(system.completed.filter { $0.0 == action.id }.map(\.1) == [true])
        await calls.end()
        try await callEventually { let ends = await service.ends; return calls.mediaSession == nil && engine.closed && ends == 1 }
        await calls.close()
        #expect(system.completed.filter { $0.0 == action.id }.map(\.1) == [true])
        #expect(!engine.microphone && !engine.camera && !system.invalidated)
        #expect(await socket.closes == 1)
        return references
    }
    for _ in 0..<30 {
        let references = try await cycle()
        try await callEventually { references.coordinator == nil && references.engine == nil }
    }
}

private enum CallFixture {
    static let user = UUID(), peer = UUID(), device = UUID(), room = UUID(), member = UUID(), call = UUID(), conversation = UUID()
    static let origin = try! ServerOrigin("https://direct-call.fixture.example")
    static let person = DirectCallPeer(id: peer, displayName: "Собеседник")
    /// Готовит модель входящего или исходящего тестового звонка.
    /// - Parameters:
    ///   - status: Состояние звонка.
    ///   - version: Версия состояния.
    ///   - incoming: Считать звонок входящим.
    ///   - device: Устройство инициатора.
    ///   - acceptedDevice: Устройство, принявшее звонок.
    static func value(_ status: DirectCallStatus = .ringing, version: Int64 = 1, incoming: Bool = false,
                      device: UUID = CallFixture.device, acceptedDevice: UUID = CallFixture.device) -> DirectCall {
        let start = Date().addingTimeInterval(-60), accepted = status == .accepted || status == .ended
        return DirectCall(id: call, conversationId: conversation, conferenceId: accepted ? room : nil,
            callerUserId: incoming ? peer : user, calleeUserId: incoming ? user : peer,
            callerClientId: device.uuidString.lowercased(), acceptedByClientId: accepted ? acceptedDevice.uuidString.lowercased() : nil,
            status: status, version: version, createdAt: start, expiresAt: start.addingTimeInterval(180),
            acceptedAt: accepted ? start.addingTimeInterval(10) : nil, endedAt: status.isTerminal ? Date() : nil,
            caller: DirectCallPeer(id: incoming ? peer : user, displayName: incoming ? "Собеседник" : "Вы"),
            callee: DirectCallPeer(id: incoming ? user : peer, displayName: incoming ? "Вы" : "Собеседник"))
    }
    static var membership: ConferenceParticipant {
        ConferenceParticipant(id: member, conferenceId: room, userId: user, displayName: "Вы")
    }
    /// Кодирует тестовый JSON-объект в байты для сетевого ответа.
    /// - Parameter value: Содержимое JSON.
    static func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    /// Преобразует модель через кодировщик API в JSON-объект тестового ответа.
    /// - Parameter value: Модель для сериализации.
    static func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: WireJSON.encoder().encode(value)) }
    /// Кодирует событие сигналинга для тестового сокета.
    /// - Parameters:
    ///   - type: Тип события.
    ///   - value: Поля полезной нагрузки.
    ///   - reply: Идентификатор исходного запроса для события-ответа.
    static func event(_ type: String, _ value: [String: Any], reply: UUID? = nil) throws -> Data {
        var data: [String: Any] = ["version": 1, "id": UUID().uuidString, "conferenceId": room.uuidString,
            "timestamp": "2026-11-06T12:00:00Z", "type": type, "data": value]
        if let reply { data["replyTo"] = reply.uuidString }; return try json(data)
    }
    /// Готовит репозиторий конференций с тестовым аккаунтом и транспортом.
    /// - Parameter transport: Транспорт запросов к API встреч.
    static func conference(_ transport: CallConferenceTransport = CallConferenceTransport()) throws -> ConferenceRepository {
        let user = try WireJSON.decoder().decode(AccountUser.self, from: json(["id": Self.user.uuidString,
            "email": "fixture@example.test", "displayName": "Вы", "isAdmin": false,
            "createdAt": "2026-11-06T12:00:00Z", "updatedAt": "2026-11-06T12:00:00Z"]))
        return ConferenceRepository(client: AuthenticatedClient(account: AccountRecord(server: origin, user: user),
            credentials: SessionCredentials(accessToken: "fixture", sessionCookie: nil, expiresAt: Date().addingTimeInterval(3600)),
            secureStore: CallSecrets(), transport: transport))
    }
}
private actor CallSecrets: SecureStore {
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
private actor CallGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var started = false
    /// Приостанавливает операцию до явного разрешения теста.
    func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
    /// Возобновляет операцию, приостановленную тестом.
    func release() { continuation?.resume(); continuation = nil }
}
private final class CallClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    /// Возвращает текущее время управляемых тестом часов.
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    /// Передвигает тестовые часы на заданный интервал.
    /// - Parameter seconds: Смещение времени в секундах.
    func advance(_ seconds: TimeInterval) { lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock() }
}
private actor CallService: DirectCallsServing {
    nonisolated let origin = CallFixture.origin
    nonisolated let userID = CallFixture.user
    var value: DirectCall?
    var createIDs: [UUID] = []
    var createsFail = 0
    var cancelFails = false
    var accepts = 0, cancels = 0, ends = 0, declines = 0, heartbeats = 0, reads = 0
    var acceptGate: CallGate?
    var createRequestGate: CallGate?
    var createReplyGate: CallGate?
    var createStatus = DirectCallStatus.ringing
    var heartbeatGate: CallGate?
    /// Задаёт звонок, возвращаемый тестовым сервисом.
    /// - Parameter value: Текущее состояние звонка или `nil` для его отсутствия.
    init(_ value: DirectCall? = nil) { self.value = value }
    /// Задаёт звонок, возвращаемый тестовым сервисом.
    /// - Parameter value: Текущее состояние звонка или `nil` для его отсутствия.
    func set(_ value: DirectCall?) { self.value = value }
    /// Настраивает ошибку первой попытки создания звонка.
    func failCreate() { createsFail = 1 }
    /// Включает имитацию тайм-аута отмены вызова.
    func failCancel() { cancelFails = true }
    /// Восстанавливает успешную отмену тестовых вызовов.
    func allowCancel() { cancelFails = false }
    /// Задерживает принятие звонка до разрешения теста.
    /// - Parameter gate: Точка ожидания подтверждения.
    func blockAccept(_ gate: CallGate) { acceptGate = gate }
    /// Задерживает ответ на создание звонка.
    /// - Parameter gate: Точка ожидания ответа сервера.
    func blockCreateReply(_ gate: CallGate) { createReplyGate = gate }
    /// Задерживает обработку запроса создания звонка.
    /// - Parameter gate: Точка ожидания перед обработкой запроса.
    func blockCreateRequest(_ gate: CallGate) { createRequestGate = gate }
    /// Задаёт статус, с которым сервис создаёт звонок.
    /// - Parameter status: Статус нового звонка.
    func setCreateStatus(_ status: DirectCallStatus) { createStatus = status }
    /// Задерживает ответ на heartbeat звонка.
    /// - Parameter gate: Точка синхронизации запроса.
    func blockHeartbeat(_ gate: CallGate) { heartbeatGate = gate }
    /// Имитирует создание исходящего звонка и учитывает повторные запросы.
    /// - Parameters:
    ///   - targetUserID: Идентификатор получателя.
    ///   - clientRequestID: Ключ повторной отправки запроса.
    ///   - clientID: Идентификатор устройства инициатора.
    func create(targetUserID: UUID, clientRequestID: UUID, clientID: UUID) async throws -> DirectCall {
        createIDs.append(clientRequestID)
        if createsFail > 0 { createsFail -= 1; throw APIError.timeout }
        if let createRequestGate { await createRequestGate.wait() }
        let call = CallFixture.value(createStatus, version: createStatus == .ringing ? 1 : 2, device: clientID); value = call
        if let createReplyGate { await createReplyGate.wait() }
        return call
    }
    /// Возвращает звонок, только пока он активен в тестовом сервисе.
    func active() -> DirectCall? { value?.isActive == true ? value : nil }
    /// Возвращает сохранённый тестовый звонок или ошибку отсутствия.
    /// - Parameter id: Идентификатор запрошенного звонка.
    func read(_ id: UUID) throws -> DirectCall { reads += 1; guard let value else { throw APIError.httpStatus(404) }; return value }
    /// Имитирует принятие входящего звонка выбранным устройством.
    /// - Parameters:
    ///   - id: Идентификатор звонка.
    ///   - clientID: Устройство, принимающее звонок.
    func accept(_ id: UUID, clientID: UUID) async -> DirectCall {
        accepts += 1
        if let acceptGate { await acceptGate.wait() }
        let call = CallFixture.value(.accepted, version: 2, incoming: true, acceptedDevice: clientID); value = call; return call
    }
    /// Имитирует отказ от входящего звонка.
    /// - Parameters:
    ///   - id: Идентификатор звонка.
    ///   - clientID: Идентификатор устройства клиента.
    func decline(_ id: UUID, clientID: UUID) -> DirectCall {
        declines += 1; let call = CallFixture.value(.declined, version: 3, incoming: true); value = call; return call
    }
    /// Имитирует отмену исходящего звонка или заданный тайм-аут.
    /// - Parameters:
    ///   - id: Идентификатор звонка.
    ///   - clientID: Идентификатор устройства клиента.
    func cancel(_ id: UUID, clientID: UUID) throws -> DirectCall {
        cancels += 1
        if cancelFails { throw APIError.timeout }
        let call = CallFixture.value(.cancelled, version: 3, device: clientID); value = call; return call
    }
    /// Имитирует завершение звонка клиентским устройством.
    /// - Parameters:
    ///   - id: Идентификатор звонка.
    ///   - clientID: Идентификатор устройства клиента.
    func end(_ id: UUID, clientID: UUID) -> DirectCall {
        ends += 1; let call = CallFixture.value(.ended, version: 3, incoming: value?.calleeUserId == userID, device: clientID, acceptedDevice: clientID); value = call; return call
    }
    /// Учитывает heartbeat и возвращает тестовое состояние звонка.
    /// - Parameters:
    ///   - id: Идентификатор звонка.
    ///   - clientID: Идентификатор устройства клиента.
    func heartbeat(_ id: UUID, clientID: UUID) async throws -> DirectCall {
        heartbeats += 1
        if let heartbeatGate { await heartbeatGate.wait() }
        return try read(id)
    }
}
@MainActor private final class CallSystem: SystemCalling {
    let events: AsyncStream<SystemCallEvent>
    let continuation: AsyncStream<SystemCallEvent>.Continuation
    let isAvailable: Bool
    var incoming: [UUID] = [], starts: [UUID] = [], completed: [(UUID, Bool)] = []
    var ended: [(UUID, SystemCallEndReason)] = [], connected: [UUID] = []
    var invalidated = false, failStart = false
    var startRequests = 0
    var startGate: CallGate?
    var lastAnswer: SystemCallAction?
    /// Готовит тестовый источник системных событий звонков.
    /// - Parameter available: Считать ли системные звонки доступными.
    init(available: Bool = true) { isAvailable = available; (events, continuation) = AsyncStream.makeStream() }
    /// Регистрирует входящий вызов в имитации CallKit.
    /// - Parameters:
    ///   - descriptor: Описание входящего звонка.
    ///   - completion: Обработчик результата регистрации в системе.
    func reportIncoming(_ descriptor: SystemCallDescriptor, completion: @escaping @Sendable (Result<Void, SystemCallingError>) -> Void) {
        incoming.append(descriptor.id); completion(.success(()))
    }
    /// Имитирует запрос CallKit на исходящий звонок с настраиваемым результатом.
    /// - Parameter descriptor: Описание исходящего звонка.
    func requestStart(_ descriptor: SystemCallDescriptor) async throws {
        startRequests += 1
        if let startGate { await startGate.wait() }
        if failStart { throw SystemCallingError.requestRejected }
        starts.append(descriptor.id); emit(.action(action(.start, id: descriptor.id)))
    }
    /// Выдаёт системное действие ответа на входящий вызов.
    /// - Parameter callID: Идентификатор звонка.
    func requestAnswer(callID: UUID) {
        let value = action(.answer, id: callID); lastAnswer = value; emit(.action(value))
    }
    /// Выдаёт системное действие завершения вызова.
    /// - Parameter callID: Идентификатор звонка.
    func requestEnd(callID: UUID) { emit(.action(action(.end, id: callID))) }
    /// Выдаёт системное действие изменения состояния микрофона.
    /// - Parameters:
    ///   - muted: Требуется ли отключить звук микрофона.
    ///   - callID: Идентификатор звонка.
    func requestMuted(_ muted: Bool, callID: UUID) { emit(.action(action(.setMuted(muted), id: callID))) }
    /// Запоминает результат выполнения действия CallKit.
    /// - Parameters:
    ///   - id: Идентификатор действия.
    ///   - succeeded: Успешно ли действие выполнено.
    func completeAction(id: UUID, succeeded: Bool) { completed.append((id, succeeded)) }
    /// Принимает уведомление о начале подключения без обращения к CallKit.
    /// - Parameters:
    ///   - callID: Идентификатор звонка.
    ///   - date: Время начала подключения.
    func reportConnecting(callID: UUID, at date: Date?) {}
    /// Записывает идентификатор подключённого звонка для проверки.
    /// - Parameters:
    ///   - callID: Идентификатор звонка.
    ///   - date: Время начала разговора.
    func reportConnected(callID: UUID, at date: Date?) { connected.append(callID) }
    /// Запоминает завершённый звонок и причину его завершения.
    /// - Parameters:
    ///   - callID: Идентификатор звонка.
    ///   - reason: Причина завершения.
    ///   - date: Время завершения.
    func reportEnded(callID: UUID, reason: SystemCallEndReason, at date: Date?) { ended.append((callID, reason)) }
    /// Принимает обновление описания звонка без обращения к CallKit.
    /// - Parameter descriptor: Актуальное описание вызова.
    func updateCall(_ descriptor: SystemCallDescriptor) {}
    /// Отмечает завершение работы тестового системного провайдера.
    func invalidate() { invalidated = true }
    /// Формирует действие пользователя с тестовым сроком исполнения.
    /// - Parameters:
    ///   - kind: Тип действия.
    ///   - id: Идентификатор звонка.
    func action(_ kind: SystemCallAction.Kind, id: UUID = CallFixture.call) -> SystemCallAction {
        SystemCallAction(id: UUID(), callID: id, kind: kind, deadline: Date().addingTimeInterval(30))
    }
    /// Передаёт подготовленное системное событие координатору звонков.
    /// - Parameter event: Событие для доставки.
    func emit(_ event: SystemCallEvent) { continuation.yield(event) }
}
private actor CallConferenceTransport: RequestTransport {
    var paths: [String] = []
    var ticketClients: [String] = []
    /// Обрабатывает запрос к API конференции и возвращает ответ для текущего сценария.
    /// - Parameters:
    ///   - request: Запрос проверяемого клиента.
    ///   - limit: Лимит ответа из контракта транспорта.
    ///   - uploadFile: Необязательный файл для отправки.
    ///   - progress: Обработчик прогресса из контракта транспорта.
    func send(_ request: URLRequest, limit: Int, uploadFile: URL?, progress: TransferProgress?) throws -> NetworkResponse {
        let path = request.url!.path; paths.append(path)
        let value: Any
        if path.hasSuffix("/participants/me") { value = ["item": try CallFixture.object(CallFixture.membership)] }
        else if path.hasSuffix("/webrtc/config") { value = ["iceServers": [["urls": ["stun:fixture.example:3478"]]], "iceTransportPolicy": "all"] }
        else if path.hasSuffix("/ws-ticket") {
            let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String])
            ticketClients.append(try #require(body["clientId"]))
            value = ["ticket": String(repeating: "a", count: 43), "expiresAt": "2099-11-06T12:00:00Z"]
        } else if path.hasSuffix("/media") { value = ["item": try CallFixture.object(CallFixture.membership)] }
        else { throw APIError.httpStatus(404) }
        return NetworkResponse(status: 200, headers: ["content-type": "application/json"], data: try CallFixture.json(value))
    }
}
private actor CallSocket: ConferenceSocket {
    let stream: AsyncThrowingStream<Data, Error>
    let continuation: AsyncThrowingStream<Data, Error>.Continuation
    let peer = UUID()
    var ready: UUID?
    var closes = 0
    /// Создаёт управляемый тестом поток входящих сообщений сокета.
    init() { (stream, continuation) = AsyncThrowingStream.makeStream() }
    /// Имитирует начальное событие состояния конференции при подключении.
    func begin() throws {
        continuation.yield(try CallFixture.event("conference.state", ["connectionId": UUID().uuidString,
            "participantId": CallFixture.member.uuidString, "status": "active", "participants": [CallFixture.object(CallFixture.membership)]]))
    }
    /// Обрабатывает команды клиента и подготавливает ответы тестового сигналинга.
    /// - Parameter data: Данные команды конференции.
    func send(_ data: Data) throws {
        let event = try ConferenceEnvelope.decode(data, conferenceID: CallFixture.room)
        if event.type == "media.join" {
            continuation.yield(try CallFixture.event("media.joined", ["mediaPeerId": peer.uuidString,
                "maxPeers": 2, "tracks": [], "videoCapture": ["maxWidth": 1280, "maxHeight": 720, "maxFrameRate": 30]], reply: event.id))
        } else if event.type == "media.offer" {
            struct Offer: Decodable { let negotiationId: UUID }
            continuation.yield(try CallFixture.event("media.answer", ["mediaPeerId": peer.uuidString,
                "negotiationId": event.payload(Offer.self).negotiationId.uuidString,
                "sdp": "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:0\r\n"], reply: event.id))
        } else if event.type == "media.ready" { ready = event.id }
    }
    /// Подтверждает получение команды готовности тестового медиасоединения.
    func acknowledge() throws {
        continuation.yield(try CallFixture.event("ack", ["type": "media.ready"], reply: #require(ready)))
    }
    /// Ожидает очередное сообщение из входящего потока тестового сокета.
    func receive() async throws -> Data {
        var iterator = stream.makeAsyncIterator()
        guard let value = try await iterator.next() else { throw RealtimeError.disconnected }; return value
    }
    /// Закрывает поток сообщений и учитывает закрытие тестового соединения.
    func close() { closes += 1; continuation.finish() }
}
private actor CallSockets: ConferenceSocketFactory {
    var created: [CallSocket] = []
    /// Создаёт тестовое соединение и отправляет начальное состояние конференции.
    /// - Parameters:
    ///   - origin: Сервер звонка.
    ///   - conferenceID: Идентификатор конференции.
    ///   - ticket: Билет подключения.
    func connect(origin: ServerOrigin, conferenceID: UUID, ticket: String) async throws -> any ConferenceSocket {
        let socket = CallSocket(); created.append(socket); try await socket.begin(); return socket
    }
}
@MainActor private final class CallEngine: ConferenceMediaEngine {
    let events: AsyncStream<ConferenceMediaEvent>
    let continuation: AsyncStream<ConferenceMediaEvent>.Continuation
    let localVideoTrackID = "fixture-camera"
    var microphone = false, camera = false, closed = false
    var cameraFailures = 0, cameraAttempts = 0
    var configuration: ConferenceMediaConfiguration?
    /// Готовит поток событий тестового медиадвижка.
    init() { (events, continuation) = AsyncStream.makeStream() }
    var localScreenVideoTrackID: String { "fixture-screen" }
    /// Принимает откат SDP без изменения тестового медиасоединения.
    func rollbackLocalOffer() async throws {}
    /// Принимает команду публикации экрана в заглушке звонка.
    /// - Parameter enabled: Запрошенное состояние демонстрации.
    func setScreenEnabled(_ enabled: Bool) async throws {}
    /// Принимает кадр экрана в заглушке без видеокодирования.
    /// - Parameter frame: Кадр тестовой демонстрации.
    func pushScreenFrame(_ frame: ScreenBroadcastFrame) throws {}
    /// Запоминает конфигурацию подключения тестового медиадвижка.
    /// - Parameter configuration: Параметры медиасоединения.
    func configure(_ configuration: ConferenceMediaConfiguration) { self.configuration = configuration }
    /// Формирует тестовое предложение SDP для переговоров.
    /// - Parameter iceRestart: Запрошен ли перезапуск ICE.
    func makeOffer(iceRestart: Bool) -> ConferenceMediaOffer { ConferenceMediaOffer(sdp: "v=0\r\n", publications: []) }
    /// Имитирует установление соединения после получения ответа SDP.
    /// - Parameter sdp: Описание медиа удалённой стороны.
    func applyAnswer(_ sdp: String) { continuation.yield(.connectionState(.connected)) }
    /// Принимает ICE-кандидата без установки сетевого соединения.
    /// - Parameter candidate: Кандидат удалённой стороны.
    func addRemoteCandidate(_ candidate: ConferenceICECandidate) {}
    /// Принимает политику публикаций в заглушке звонка.
    /// - Parameters:
    ///   - microphone: Разрешение микрофона.
    ///   - camera: Разрешение камеры.
    ///   - screen: Разрешение демонстрации экрана.
    func setPublicationPermissions(microphone: Bool, camera: Bool, screen: Bool) {}
    /// Меняет состояние тестового микрофона и сообщает о захвате.
    /// - Parameter enabled: Запрошенное состояние микрофона.
    func setMicrophoneEnabled(_ enabled: Bool) { microphone = enabled; capture() }
    /// Имитирует смену состояния камеры с учётом разрешения тестовой сессии.
    /// - Parameter enabled: Запрошенное состояние камеры.
    func setCameraEnabled(_ enabled: Bool) throws {
        if enabled {
            cameraAttempts += 1
            if cameraFailures > 0 { cameraFailures -= 1; throw ConferenceMediaError.cameraPermissionDenied }
        }
        camera = enabled; capture()
    }
    /// Принимает команду переключения камеры без обращения к устройству.
    func switchCamera() {}
    /// Принимает переключение громкой связи без изменения системного аудиомаршрута.
    /// - Parameter enabled: Желаемое состояние громкой связи.
    func setSpeakerEnabled(_ enabled: Bool) throws {}
    /// Приостанавливает тестовые микрофон и камеру и сообщает об изменении состояния.
    func suspend() { microphone = false; camera = false; capture() }
    /// Закрывает медиадвижок и завершает тестовый поток событий.
    func close() { closed = true; microphone = false; camera = false; continuation.finish() }
    /// Возвращает прозрачную заглушку видеоплитки.
    /// - Parameters:
    ///   - trackID: Идентификатор запрошенной дорожки.
    ///   - mirrored: Запрошено ли зеркальное отображение.
    func videoView(trackID: String, mirrored: Bool) -> AnyView { AnyView(Color.clear) }
    /// Публикует текущие флаги тестового микрофона и камеры.
    func capture() { continuation.yield(.captureState(microphone: microphone, camera: camera, frontCamera: true)) }
}
@MainActor private func callEventually(_ predicate: @escaping @MainActor () async -> Bool) async throws {
    for _ in 0..<300 { if await predicate() { return }; try await Task.sleep(for: .milliseconds(4)) }
    throw APIError.timeout
}
@MainActor private func coordinator(_ service: CallService, system: CallSystem, sockets: CallSockets = CallSockets(),
    transport: CallConferenceTransport = CallConferenceTransport(), engine: CallEngine = CallEngine(),
    canUse: @escaping @MainActor () -> Bool = { true }, now: @escaping @Sendable () -> Date = { Date() }) throws -> DirectCallCoordinator {
    DirectCallCoordinator(repository: service, conferenceRepository: try CallFixture.conference(transport), system: system,
        sockets: sockets, makeMedia: { engine }, canUseMedia: canUse, clientID: CallFixture.device, now: now)
}

@Test @MainActor func directCallRetriesUnknownCreateWithSameIdempotencyKey() async throws {
    let service = CallService(), system = CallSystem(), calls = try coordinator(service, system: system)
    await service.failCreate()
    await calls.startOutgoing(peer: CallFixture.person)
    #expect(calls.uncertain && calls.pendingPeer != nil)
    await calls.startOutgoing(peer: CallFixture.person)
    let keys = await service.createIDs
    #expect(keys.count == 2 && keys[0] == keys[1])
    #expect(!calls.uncertain && calls.currentCall?.status == .ringing)
    await calls.close(); #expect(!system.invalidated)
}

@Test @MainActor func directCallEndDuringCreateCancelsLateCallWithoutStartingSystemOrMedia() async throws {
    let service = CallService(), system = CallSystem(), sockets = CallSockets(), request = CallGate()
    await service.blockCreateRequest(request)
    let calls = try coordinator(service, system: system, sockets: sockets)
    let creation = Task { await calls.startOutgoing(peer: CallFixture.person, isVideo: true) }
    try await callEventually { await request.started }
    await calls.end()
    #expect(calls.ending && calls.busy && calls.pendingPeer != nil)
    #expect(!calls.microphoneWanted && !calls.cameraWanted)
    await request.release(); await creation.value
    #expect(calls.currentCall?.status == .cancelled && calls.pendingPeer == nil)
    #expect(await service.cancels == 1)
    #expect(await service.createIDs.count == 1)
    #expect(system.startRequests == 0 && calls.mediaSession == nil)
    #expect(await sockets.created.isEmpty)
    await calls.close()
}

@Test @MainActor func directCallEndAfterUnknownCreateResolvesAcceptedCallWithOriginalKeyWithoutCapture() async throws {
    let service = CallService(), system = CallSystem(), sockets = CallSockets()
    let calls = try coordinator(service, system: system, sockets: sockets)
    await service.failCreate(); await calls.startOutgoing(peer: CallFixture.person, isVideo: true)
    #expect(calls.uncertain && calls.pendingPeer != nil)
    await service.failCreate(); await calls.end()
    #expect(calls.ending && calls.uncertain && calls.pendingPeer != nil)
    #expect(!calls.microphoneWanted && !calls.cameraWanted)
    await service.setCreateStatus(.accepted)
    await calls.end()
    let keys = await service.createIDs
    #expect(keys.count == 3 && Set(keys).count == 1)
    #expect(await service.ends == 1)
    #expect(calls.currentCall?.status == .ended && calls.pendingPeer == nil)
    #expect(system.startRequests == 0 && calls.mediaSession == nil)
    #expect(await sockets.created.isEmpty)
    await calls.close()
}

@Test @MainActor func directCallCancelledCreationStaysCaptureOffAcrossUnknownCancelAndAcceptance() async throws {
    let service = CallService(), system = CallSystem(), sockets = CallSockets(), request = CallGate()
    await service.blockCreateRequest(request); await service.failCancel()
    let calls = try coordinator(service, system: system, sockets: sockets)
    let creation = Task { await calls.startOutgoing(peer: CallFixture.person) }
    try await callEventually { await request.started }
    await calls.end(); await request.release(); await creation.value
    #expect(calls.ending && calls.uncertain)
    await calls.reconcile(); await calls.reconcile()
    #expect(await service.cancels == 1)
    await service.set(CallFixture.value(.accepted, version: 2)); await calls.reconcile()
    #expect(await service.ends == 1)
    #expect(calls.currentCall?.status == .ended)
    #expect(system.startRequests == 0 && calls.mediaSession == nil)
    #expect(await sockets.created.isEmpty)
    await calls.close()
}

@Test @MainActor func directCallRepeatedEndRetriesUnknownCancellationAtSameServerVersion() async throws {
    let service = CallService(), system = CallSystem(), sockets = CallSockets()
    let calls = try coordinator(service, system: system, sockets: sockets)
    await service.failCreate(); await calls.startOutgoing(peer: CallFixture.person)
    await service.failCancel(); await calls.end()
    #expect(calls.ending && calls.uncertain && calls.currentCall?.status == .ringing)
    #expect(calls.pendingPeer == nil && calls.currentCall?.version == 1)
    await calls.reconcile()
    #expect(await service.cancels == 1)
    await service.allowCancel(); await calls.end()
    #expect(await service.cancels == 2)
    #expect(calls.currentCall?.status == .cancelled && !calls.ending && !calls.uncertain)
    let keys = await service.createIDs
    #expect(keys.count == 2 && Set(keys).count == 1)
    #expect(system.startRequests == 0 && calls.mediaSession == nil)
    #expect(await sockets.created.isEmpty)
    await calls.close()
}

@Test @MainActor func directCallReconcilesLostCreateResponseIntoOneSystemStartBeforeMedia() async throws {
    let service = CallService(), system = CallSystem(), sockets = CallSockets()
    let calls = try coordinator(service, system: system, sockets: sockets)
    await service.failCreate(); await calls.startOutgoing(peer: CallFixture.person)
    #expect(calls.uncertain && calls.pendingPeer != nil && system.starts.isEmpty)
    await service.set(CallFixture.value(.accepted, version: 2)); await calls.reconcile()
    try await callEventually { await sockets.created.count == 1 }
    #expect(system.starts == [CallFixture.call])
    #expect(!calls.uncertain && calls.pendingPeer == nil)
    await calls.reconcile()
    #expect(system.starts.count == 1)
    await calls.close()
}

@Test @MainActor func directCallRejectsMeetingConflictBeforeCreatingOrAccepting() async throws {
    let service = CallService(CallFixture.value(incoming: true)), system = CallSystem()
    let calls = try coordinator(service, system: system, canUse: { false })
    await calls.startOutgoing(peer: CallFixture.person)
    #expect(await service.createIDs.isEmpty)
    await calls.reconcile(); await calls.answer()
    #expect(await service.accepts == 0)
    #expect(calls.error != nil)
    await calls.close()
}

@Test @MainActor func directCallIncomingMultiDeviceAcceptanceClosesOnlyLocalCallKit() async throws {
    let service = CallService(CallFixture.value(incoming: true)), system = CallSystem(), sockets = CallSockets()
    let calls = try coordinator(service, system: system, sockets: sockets)
    await calls.reconcile()
    #expect(system.incoming == [CallFixture.call])
    await service.set(CallFixture.value(.accepted, version: 2, incoming: true, acceptedDevice: UUID()))
    await calls.reconcile()
    #expect(calls.otherDevice && calls.mediaSession == nil)
    #expect(system.ended.contains { $0.1 == .answeredElsewhere })
    #expect(await sockets.created.isEmpty)
    await calls.end()
    #expect(await service.ends == 0)
    await calls.close()
}

@Test @MainActor func directCallDoesNotTrustSocketDTOAndRejectsOlderRESTVersion() async throws {
    let service = CallService(CallFixture.value(.cancelled, version: 4)), system = CallSystem()
    let calls = try coordinator(service, system: system)
    await calls.receive(CallFixture.value(.accepted, version: 9))
    #expect(calls.mediaSession == nil && calls.currentCall == nil)
    await service.set(CallFixture.value(version: 3)); await calls.reconcile()
    await service.set(CallFixture.value(.cancelled, version: 4)); await calls.reconcile()
    #expect(calls.currentCall?.status == .cancelled)
    await service.set(CallFixture.value(version: 2)); await calls.reconcile()
    #expect(calls.currentCall?.status == .cancelled)
    await calls.close()
}

@Test @MainActor func directCallStartRejectionCancelsOwnedRing() async throws {
    let service = CallService(), system = CallSystem(); system.failStart = true
    let calls = try coordinator(service, system: system)
    await calls.startOutgoing(peer: CallFixture.person)
    #expect(await service.cancels == 1)
    #expect(calls.currentCall?.status == .cancelled && calls.mediaSession == nil)
    await calls.close()
}

@Test @MainActor func directCallStartRejectionPreservesUnknownServerCancellation() async throws {
    let service = CallService(), system = CallSystem(); system.failStart = true
    await service.failCancel()
    let calls = try coordinator(service, system: system)
    await calls.startOutgoing(peer: CallFixture.person)
    #expect(await service.cancels == 1)
    #expect(calls.uncertain && calls.ending && calls.pendingPeer == nil)
    #expect(calls.currentCall?.status == .ringing && calls.mediaSession == nil)
    await calls.reconcile()
    #expect(calls.uncertain && calls.ending && system.starts.isEmpty)
    await calls.close()
}

@Test @MainActor func directCallPOSTAndReconciliationAwaitTheSameRejectedSystemStart() async throws {
    let service = CallService(), system = CallSystem(), createReply = CallGate(), systemReply = CallGate()
    await service.blockCreateReply(createReply)
    system.failStart = true; system.startGate = systemReply
    let calls = try coordinator(service, system: system)
    var returned = false
    var returnedStatus: DirectCallStatus?
    let creation = Task { @MainActor in
        await calls.startOutgoing(peer: CallFixture.person)
        returnedStatus = calls.currentCall?.status; returned = true
    }
    try await callEventually { await createReply.started }
    // The server has committed; the startup poll owns a blocked CallKit request before POST returns.
    let reconciliation = Task { await calls.reconcile() }
    try await callEventually { await systemReply.started }
    await createReply.release()
    // Let the released POST continuation run while the explicit system gate stays closed.
    // A completed create here would skip the lifecycle result that it promises its caller.
    for _ in 0..<30 { await Task.yield() }
    #expect(!returned && calls.busy)
    await systemReply.release()
    await creation.value; await reconciliation.value
    #expect(returnedStatus == .cancelled)
    #expect(await service.cancels == 1)
    #expect(calls.currentCall?.status == .cancelled && calls.mediaSession == nil)
    await calls.close()
}

@Test @MainActor func directCallAnswerWaitsForSFUReadyWithoutWaitingForSystemAudioActivation() async throws {
    let service = CallService(CallFixture.value(incoming: true)), system = CallSystem()
    let sockets = CallSockets(), transport = CallConferenceTransport(), engine = CallEngine()
    let calls = try coordinator(service, system: system, sockets: sockets, transport: transport, engine: engine)
    await calls.reconcile(); await calls.answer()
    try await callEventually { await sockets.created.first?.ready != nil }
    let action = try #require(system.lastAnswer), socket = try #require(await sockets.created.first)
    #expect(!system.completed.contains { $0.0 == action.id })
    try await socket.acknowledge()
    try await callEventually { system.completed.contains { $0.0 == action.id && $0.1 } }
    #expect(calls.mediaSession?.phase == .connected)
    #expect(await transport.ticketClients == [CallFixture.device.uuidString.lowercased()])
    #expect(engine.configuration?.audioActivation == .callKit)
    #expect(!engine.camera)
    await calls.setForeground(false)
    #expect(!engine.closed && calls.mediaSession?.phase == .connected)
    await calls.end()
    try await callEventually { await service.ends == 1 }
    #expect(engine.closed)
    let paths = await transport.paths
    #expect(!paths.contains { $0.hasSuffix("/join") || $0.hasSuffix("/leave") || $0.hasSuffix("/messages") })
    #expect(!paths.contains("/api/v1/conferences/" + CallFixture.room.uuidString.lowercased()))
    await calls.close()
}

@Test @MainActor func directCallLateAcceptAfterAccountCloseNeverCreatesMediaAndCompensates() async throws {
    let gate = CallGate(), service = CallService(CallFixture.value(incoming: true)), system = CallSystem(), sockets = CallSockets()
    await service.blockAccept(gate)
    let calls = try coordinator(service, system: system, sockets: sockets)
    await calls.reconcile(); await calls.answer()
    try await callEventually { await gate.started }
    await calls.close(); await gate.release()
    try await callEventually { await service.ends == 1 }
    #expect(await sockets.created.isEmpty)
    #expect(calls.mediaSession == nil && !system.invalidated)
}

@Test @MainActor func directCallAnswerTimeoutStopsCaptureAndDoesNotLaterFulfill() async throws {
    let service = CallService(CallFixture.value(incoming: true)), system = CallSystem(), sockets = CallSockets(), engine = CallEngine()
    let calls = try coordinator(service, system: system, sockets: sockets, engine: engine)
    await calls.reconcile(); await calls.answer()
    try await callEventually { await sockets.created.first?.ready != nil }
    let action = try #require(system.lastAnswer)
    system.emit(.timedOut(action))
    try await callEventually { engine.closed }
    #expect(!system.completed.contains { $0.0 == action.id && $0.1 })
    #expect(calls.mediaSession == nil)
    await calls.close()
}

@Test @MainActor func directCallHeartbeatWatchdogClosesCaptureWhileRenewalIsHung() async throws {
    let service = CallService(CallFixture.value(.accepted, version: 2)), system = CallSystem(available: false)
    let engine = CallEngine(), sockets = CallSockets(), clock = CallClock(), gate = CallGate()
    await service.blockHeartbeat(gate)
    let calls = try coordinator(service, system: system, sockets: sockets, engine: engine, now: { clock.now() })
    await calls.reconcile()
    try await callEventually { await sockets.created.first?.ready != nil }
    clock.advance(11); await calls.tick()
    try await callEventually { await gate.started }
    clock.advance(25); await calls.tick()
    #expect(calls.ending && calls.mediaSession == nil && engine.closed)
    await gate.release()
    await calls.close()
}

@Test @MainActor func directCallDuplicateSystemActionCompletesExactlyOnce() async throws {
    let service = CallService(CallFixture.value(.accepted, version: 2)), system = CallSystem()
    let calls = try coordinator(service, system: system)
    await calls.reconcile()
    let action = system.action(.setMuted(true))
    system.emit(.action(action)); system.emit(.action(action))
    try await callEventually { system.completed.contains { $0.0 == action.id } }
    system.emit(.timedOut(action))
    try await Task.sleep(for: .milliseconds(20))
    #expect(system.completed.filter { $0.0 == action.id }.count == 1)
    #expect(!calls.microphoneWanted && !calls.ending)
    await calls.close()
}

@Test @MainActor func directCallInitialInactiveAudioSnapshotPreservesOutgoingVideoIntent() async throws {
    let service = CallService(), system = CallSystem(), calls = try coordinator(service, system: system)
    await calls.startOutgoing(peer: CallFixture.person, isVideo: true)
    system.emit(.audioActivationChanged(false))
    try await Task.sleep(for: .milliseconds(20))
    #expect(calls.cameraWanted && calls.mediaSession == nil)
    await calls.close()
}

@Test @MainActor func directCallCameraRetryUsesActualCaptureAfterInitialPermissionDenial() async throws {
    let service = CallService(), system = CallSystem(available: false), engine = CallEngine(), sockets = CallSockets()
    engine.cameraFailures = 1
    let calls = try coordinator(service, system: system, sockets: sockets, engine: engine)
    await calls.startOutgoing(peer: CallFixture.person, isVideo: true)
    await service.set(CallFixture.value(.accepted, version: 2)); await calls.reconcile()
    try await callEventually { engine.cameraAttempts == 1 }
    #expect(calls.cameraWanted && !engine.camera)
    await calls.toggleCamera()
    try await callEventually { calls.mediaSession?.camera == true }
    #expect(engine.cameraAttempts == 2 && calls.cameraWanted)
    await calls.close()
}
