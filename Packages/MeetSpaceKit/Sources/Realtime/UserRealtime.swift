import Foundation
import MeetSpaceCore
import MeetSpaceAPI

public enum RealtimeError: Error, Sendable { case invalidEvent, disconnected }
public struct UserEvent: Sendable {
    public let id: UUID
    public let type: String
    public let conversationID: UUID?
    public let userID: UUID?
    public let message: ChatMessage?
    public let notificationsEnabled: Bool?
    public let readState: ReadState?
    public let call: DirectCall?
    private struct Envelope: Decodable {
        let version: Int
        let id: UUID
        let type: String
        let data: Payload
    }
    private struct Payload: Decodable {
        let conversationId: UUID?
        let userId: UUID?
        let message: ChatMessage?
        let notificationsEnabled: Bool?
        let state: ReadState?
        let call: DirectCall?
    }
    /// Декодирует пользовательское событие и проверяет заголовок и размер сообщения.
    /// - Parameter bytes: Байты входящего сообщения.
    public static func decode(_ bytes: Data) throws -> UserEvent? {
        guard bytes.count <= 1_048_576 else { throw RealtimeError.invalidEvent }
        // Decode the header before data: unsupported event payloads are not protocol failures.
        struct Header: Decodable { let version: Int; let type: String }
        let header = try WireJSON.decoder().decode(Header.self, from: bytes)
        guard header.version == 1 else { throw RealtimeError.invalidEvent }
        let supported = ["message.created", "message.updated", "message.deleted",
            "conversation.updated", "conversation.member.added", "conversation.member.removed",
            "conversation.member.updated", "conversation.read.updated", "conversation.preferences.updated",
            "conversation.history.cleared", "conversation.hidden", "conversation.pin.updated", "conversation.pins.updated", "call.updated"]
        guard supported.contains(header.type) else { return nil }
        let envelope = try WireJSON.decoder().decode(Envelope.self, from: bytes)
        // Call events are account-wide and have no conversationId in their envelope.
        // Validate the account and reconcile the authoritative REST state in the coordinator.
        if envelope.type == "call.updated" {
            guard let call = envelope.data.call else { throw RealtimeError.invalidEvent }
            return UserEvent(id: envelope.id, type: envelope.type, conversationID: nil, userID: nil,
                             message: nil, notificationsEnabled: nil, readState: nil, call: call)
        }
        guard let scope = envelope.data.conversationId else { throw RealtimeError.invalidEvent }
        if envelope.type.hasPrefix("message.") {
            guard let message = envelope.data.message, message.conversationId == scope else { throw RealtimeError.invalidEvent }
        }
        return UserEvent(id: envelope.id, type: envelope.type, conversationID: scope, userID: envelope.data.userId,
                         message: envelope.data.message, notificationsEnabled: envelope.data.notificationsEnabled,
                         readState: envelope.data.state, call: nil)
    }
}

public struct EventDeduplicator: Sendable {
    private var identifiers: Set<UUID> = []
    private var order: [UUID] = []
    private let capacity: Int
    /// Создаёт ограниченный кеш идентификаторов уже полученных событий.
    /// - Parameter capacity: Максимальное число последних идентификаторов событий для дедупликации.
    public init(capacity: Int = 512) { self.capacity = max(1, capacity) }
    /// Принимает новый идентификатор и возвращает false для недавно встречавшегося события.
    /// - Parameter id: Идентификатор полученного события.
    public mutating func accept(_ id: UUID) -> Bool {
        guard identifiers.insert(id).inserted else { return false }
        order.append(id)
        if order.count > capacity { identifiers.remove(order.removeFirst()) }
        return true
    }
}
public enum ReconnectPolicy {
    /// Рассчитывает задержку перед повторным подключением с учётом номера попытки и разброса.
    /// - Parameters:
    ///   - attempt: Номер попытки переподключения, начиная с нуля.
    ///   - jitter: Множитель разброса задержки между попытками подключения.
    public static func delay(attempt: Int, jitter: Double = Double.random(in: 0.8...1.2)) -> Double {
        min(30, pow(2, Double(min(5, max(0, attempt)))) * min(1.2, max(0.8, jitter)))
    }
}
public enum UserRealtimeUpdate: Sendable {
    case state(RealtimeState), event(UserEvent), authenticationRequired
}

public protocol RealtimeSocket: Sendable {
    /// Получает следующее WebSocket-сообщение и возвращает его байты.
    func receive() async throws -> Data
    /// Закрывает сокет пользовательских событий.
    func close() async
}
public protocol RealtimeSocketFactory: Sendable {
    /// Подключается к указанному адресу пользовательских событий по защищённому WebSocket.
    /// - Parameter url: Защищённый WebSocket-адрес потока пользовательских событий.
    func connect(_ url: URL) async throws -> any RealtimeSocket
}

private final class SocketDelegate: NSObject, URLSessionWebSocketDelegate, Sendable {
    let opened: AsyncThrowingStream<Void, Error>
    private let continuation: AsyncThrowingStream<Void, Error>.Continuation
    /// Создаёт поток для уведомления об открытии WebSocket-соединения.
    override init() {
        (opened, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        super.init()
    }
    /// Уведомляет ожидающую задачу об открытии пользовательского WebSocket.
    /// - Parameters:
    ///   - session: Сетевая сессия, которой принадлежит задача.
    ///   - webSocketTask: WebSocket-задача, для которой получено событие.
    ///   - protocol: Имя подпротокола, согласованного с сервером.
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        continuation.yield(()); continuation.finish()
    }
    /// Завершает ожидание соединения при закрытии сокета сервером.
    /// - Parameters:
    ///   - session: Сетевая сессия, которой принадлежит задача.
    ///   - webSocketTask: WebSocket-задача, для которой получено событие.
    ///   - closeCode: Код закрытия WebSocket, полученный от сетевой сессии.
    ///   - reason: Необязательное тело сообщения о причине закрытия WebSocket.
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        continuation.finish(throwing: RealtimeError.disconnected)
    }
    /// Передаёт ошибку завершения сетевой задачи ожидающему коду.
    /// - Parameters:
    ///   - session: Сетевая сессия, которой принадлежит задача.
    ///   - task: Сетевая задача, для которой получено событие.
    ///   - error: Ошибка сетевой задачи, если она завершилась неуспешно.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        continuation.finish(throwing: error ?? RealtimeError.disconnected)
    }
    /// Отклоняет перенаправление при открытии потока пользовательских событий.
    /// - Parameters:
    ///   - session: Сетевая сессия, которой принадлежит задача.
    ///   - task: Сетевая задача, для которой получено событие.
    ///   - response: Ответ сервера с перенаправлением.
    ///   - request: Запрос, предложенный URLSession при перенаправлении.
    ///   - completionHandler: Обработчик URLSession, которому передаётся решение о перенаправлении.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
private final class SessionSocket: RealtimeSocket, Sendable {
    let task: URLSessionWebSocketTask
    let session: URLSession
    /// Связывает пользовательский сокет с задачей и её сетевой сессией.
    /// - Parameters:
    ///   - task: Сетевая задача, для которой получено событие.
    ///   - session: Сетевая сессия, которой принадлежит задача.
    init(task: URLSessionWebSocketTask, session: URLSession) { self.task = task; self.session = session }
    /// Закрывает сокет и сетевую сессию при освобождении соединения.
    deinit { task.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
    /// Получает следующее WebSocket-сообщение и возвращает его байты.
    func receive() async throws -> Data {
        let value = try await task.receive()
        switch value {
        case .data(let data): return data
        case .string(let text): return Data(text.utf8)
        @unknown default: throw RealtimeError.invalidEvent
        }
    }
    /// Закрывает сокет пользовательских событий.
    func close() async { task.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
}
public struct URLSessionSocketFactory: RealtimeSocketFactory {
    /// Создаёт фабрику защищённых соединений для пользовательских событий.
    public init() {}
    /// Подключается к указанному адресу пользовательских событий по защищённому WebSocket.
    /// - Parameter url: Защищённый WebSocket-адрес потока пользовательских событий.
    public func connect(_ url: URL) async throws -> any RealtimeSocket {
        guard url.scheme == "wss", url.user == nil, url.password == nil else { throw APIError.tls }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        let delegate = SocketDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 1_048_576
        let socket = SessionSocket(task: task, session: session)
        task.resume()
        do {
            return try await withTaskCancellationHandler {
                for try await _ in delegate.opened { try Task.checkCancellation(); return socket }
                throw RealtimeError.disconnected
            } onCancel: { task.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
        } catch {
            await socket.close(); throw error
        }
    }
}

public actor UserRealtime {
    public nonisolated let updates: AsyncStream<UserRealtimeUpdate>
    private let continuation: AsyncStream<UserRealtimeUpdate>.Continuation
    private let origin: ServerOrigin
    private let ticket: @Sendable () async throws -> String
    private let sockets: any RealtimeSocketFactory
    private let sleep: @Sendable (Double) async throws -> Void
    private var loop: Task<Void, Never>?
    private var socket: (any RealtimeSocket)?
    private var generation = UUID()
    private var finished = false

    /// Настраивает получение билетов и переподключение к потоку событий пользователя.
    /// - Parameters:
    ///   - origin: Базовый HTTPS-адрес сервера MeetSpace.
    ///   - ticket: Функция получения нового билета доступа к потоку событий.
    ///   - sockets: Фабрика соединений с пользовательским потоком событий.
    ///   - sleep: Функция ожидания перед следующей попыткой, принимает задержку в секундах.
    public init(origin: ServerOrigin, ticket: @escaping @Sendable () async throws -> String,
                sockets: any RealtimeSocketFactory = URLSessionSocketFactory(),
                sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.origin = origin; self.ticket = ticket; self.sockets = sockets; self.sleep = sleep
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(256))
    }
    /// Запускает чтение потока событий, если цикл ещё не выполняется.
    public func start() {
        guard loop == nil, !finished else { return }
        let epoch = generation
        loop = Task { await run(epoch) }
    }
    /// Останавливает цикл переподключения и закрывает его активный сокет.
    public func stop() async {
        generation = UUID()
        let stoppedGeneration = generation
        let previous = loop; loop = nil; previous?.cancel()
        let previousSocket = socket; socket = nil
        await previousSocket?.close()
        await previous?.value
        if generation == stoppedGeneration && loop == nil { continuation.yield(.state(.disconnected)) }
    }
    /// Останавливает соединение и окончательно завершает поток обновлений.
    public func finish() async { finished = true; await stop(); continuation.finish() }
    /// Читает события текущего подключения и при необходимости восстанавливает связь.
    /// - Parameter epoch: Идентификатор поколения соединения, которому принадлежит цикл чтения.
    private func run(_ epoch: UUID) async {
        var attempt = 0
        var deduplication = EventDeduplicator()
        var ownedSocket: (any RealtimeSocket)?
        while generation == epoch && !Task.isCancelled {
            continuation.yield(.state(attempt == 0 ? .connecting : .reconnecting))
            var limited = false
            var connectedAt: Date?
            do {
                let value = try await ticket() // New single-use ticket on every attempt.
                try Task.checkCancellation()
                let url = try RealtimeEndpoint.url(origin: origin, scope: .user, ticket: value)
                let connection = try await sockets.connect(url)
                guard generation == epoch && !Task.isCancelled else { await connection.close(); return }
                socket = connection; ownedSocket = connection; connectedAt = Date()
                continuation.yield(.state(.connected)) // Consumer reconciles REST after subscription is live.
                while !Task.isCancelled && generation == epoch {
                    let bytes = try await connection.receive()
                    try Task.checkCancellation()
                    if let event = try UserEvent.decode(bytes), deduplication.accept(event.id) {
                        // Overflow requires a fresh REST snapshot instead of silently losing updates.
                        if case .dropped = continuation.yield(.event(event)) { throw RealtimeError.disconnected }
                    }
                }
            } catch is CancellationError { break }
            catch ClientError.sessionExpired { continuation.yield(.authenticationRequired); break }
            catch ClientError.accountMismatch { continuation.yield(.authenticationRequired); break }
            catch APIError.httpStatus(let status) { limited = status == 429 }
            catch { /* Never log ticket-bearing URLs or server payloads. */ }
            await ownedSocket?.close(); ownedSocket = nil
            if generation == epoch { socket = nil }
            guard generation == epoch && !Task.isCancelled else { break }
            if let connectedAt, Date().timeIntervalSince(connectedAt) >= 30 { attempt = 0 }
            continuation.yield(.state(.reconnecting))
            do { try await sleep(limited ? 60 : ReconnectPolicy.delay(attempt: attempt)) }
            catch { break }
            attempt += 1
        }
        await ownedSocket?.close()
        if generation == epoch { socket = nil }
    }
}
