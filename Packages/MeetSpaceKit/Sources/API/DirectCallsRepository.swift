import Foundation
import MeetSpaceCore

public protocol DirectCallsServing: Sendable {
    var origin: ServerOrigin { get }
    var userID: UUID { get }
    /// Создаёт исходящий личный вызов для указанного пользователя.
    /// - Parameters:
    ///   - targetUserID: Идентификатор пользователя, которому адресован вызов.
    ///   - clientRequestID: Идентификатор запроса для устранения дубликатов при повторной отправке.
    ///   - clientID: Идентификатор экземпляра клиента на устройстве пользователя.
    func create(targetUserID: UUID, clientRequestID: UUID, clientID: UUID) async throws -> DirectCall
    /// Возвращает активный личный вызов текущего пользователя, если он есть.
    func active() async throws -> DirectCall?
    /// Загружает текущее состояние личного вызова.
    /// - Parameter id: Идентификатор личного вызова.
    func read(_ id: UUID) async throws -> DirectCall
    /// Принимает входящий вызов на выбранном клиенте.
    /// - Parameters:
    ///   - id: Идентификатор личного вызова.
    ///   - clientID: Идентификатор экземпляра клиента на устройстве пользователя.
    func accept(_ id: UUID, clientID: UUID) async throws -> DirectCall
    /// Отклоняет входящий личный вызов.
    /// - Parameters:
    ///   - id: Идентификатор личного вызова.
    ///   - clientID: Идентификатор экземпляра клиента на устройстве пользователя.
    func decline(_ id: UUID, clientID: UUID) async throws -> DirectCall
    /// Отменяет исходящий вызов до соединения.
    /// - Parameters:
    ///   - id: Идентификатор личного вызова.
    ///   - clientID: Идентификатор экземпляра клиента на устройстве пользователя.
    func cancel(_ id: UUID, clientID: UUID) async throws -> DirectCall
    /// Завершает личный вызов.
    /// - Parameters:
    ///   - id: Идентификатор личного вызова.
    ///   - clientID: Идентификатор экземпляра клиента на устройстве пользователя.
    func end(_ id: UUID, clientID: UUID) async throws -> DirectCall
    /// Подтверждает серверу, что клиент продолжает участвовать в вызове.
    /// - Parameters:
    ///   - id: Идентификатор личного вызова.
    ///   - clientID: Идентификатор экземпляра клиента на устройстве пользователя.
    func heartbeat(_ id: UUID, clientID: UUID) async throws -> DirectCall
}

public struct DirectCallsRepository: DirectCallsServing {
    public let origin: ServerOrigin
    public let userID: UUID
    private let client: AuthenticatedClient
    /// Создаёт репозиторий личных звонков для авторизованного пользователя.
    /// - Parameter client: Клиент, выполняющий запросы от имени текущего аккаунта.
    public init(client: AuthenticatedClient) {
        self.client = client; origin = client.account.server; userID = client.account.user.id
    }
    /// Создаёт исходящий личный вызов для указанного пользователя.
    /// - Parameters:
    ///   - targetUserID: Идентификатор пользователя, которому адресован вызов.
    ///   - clientRequestID: Идентификатор запроса для устранения дубликатов при повторной отправке.
    ///   - clientID: Идентификатор экземпляра клиента на устройстве пользователя.
    public func create(targetUserID: UUID, clientRequestID: UUID, clientID: UUID) async throws -> DirectCall {
        try accountOnly()
        guard targetUserID != userID, [targetUserID, clientRequestID, clientID].allSatisfy(DirectCall.validID) else { throw ClientError.invalidInput }
        struct Body: Encodable { let targetUserId: String; let clientRequestId: String; let clientId: String }
        let item = try result(await client.request("POST", path: ["calls"], body: WireJSON.encoder().encode(
            Body(targetUserId: sid(targetUserID), clientRequestId: sid(clientRequestID), clientId: sid(clientID)))))
        guard item.callerUserId == userID, item.calleeUserId == targetUserID, item.callerClientId == sid(clientID)
        else { throw ClientError.scopeMismatch }
        return item
    }
    /// Возвращает активный личный вызов текущего пользователя, если он есть.
    public func active() async throws -> DirectCall? {
        try accountOnly()
        let item = try decodeJSON(ItemResponse<DirectCall?>.self, from: await client.request("GET", path: ["calls", "active"])).item
        guard let item else { return nil }
        let checked = try validate(item)
        guard checked.isActive else { throw APIError.invalidResponse }
        return checked
    }
    /// Загружает текущее состояние личного вызова.
    /// - Parameter id: Идентификатор личного вызова.
    public func read(_ id: UUID) async throws -> DirectCall {
        try accountOnly(); try valid(id)
        return try result(await client.request("GET", path: ["calls", sid(id)]), expected: id)
    }
    /// Принимает входящий вызов на выбранном клиенте.
    /// - Parameters:
    ///   - id: Идентификатор личного вызова.
    ///   - clientID: Идентификатор экземпляра клиента на устройстве пользователя.
    public func accept(_ id: UUID, clientID: UUID) async throws -> DirectCall { try await change(id, action: "accept", clientID: clientID) }
    /// Отклоняет входящий личный вызов.
    /// - Parameters:
    ///   - id: Идентификатор личного вызова.
    ///   - clientID: Идентификатор экземпляра клиента на устройстве пользователя.
    public func decline(_ id: UUID, clientID: UUID) async throws -> DirectCall { try await change(id, action: "decline", clientID: clientID) }
    /// Отменяет исходящий вызов до соединения.
    /// - Parameters:
    ///   - id: Идентификатор личного вызова.
    ///   - clientID: Идентификатор экземпляра клиента на устройстве пользователя.
    public func cancel(_ id: UUID, clientID: UUID) async throws -> DirectCall { try await change(id, action: "cancel", clientID: clientID) }
    /// Завершает личный вызов.
    /// - Parameters:
    ///   - id: Идентификатор личного вызова.
    ///   - clientID: Идентификатор экземпляра клиента на устройстве пользователя.
    public func end(_ id: UUID, clientID: UUID) async throws -> DirectCall { try await change(id, action: "end", clientID: clientID) }
    /// Подтверждает серверу, что клиент продолжает участвовать в вызове.
    /// - Parameters:
    ///   - id: Идентификатор личного вызова.
    ///   - clientID: Идентификатор экземпляра клиента на устройстве пользователя.
    public func heartbeat(_ id: UUID, clientID: UUID) async throws -> DirectCall { try await change(id, action: "heartbeat", clientID: clientID) }
    /// Отправляет команду изменения состояния вызова и проверяет ответ.
    /// - Parameters:
    ///   - id: Идентификатор личного вызова.
    ///   - action: Команда изменения состояния вызова, например accept или end.
    ///   - clientID: Идентификатор экземпляра клиента на устройстве пользователя.
    private func change(_ id: UUID, action: String, clientID: UUID) async throws -> DirectCall {
        try accountOnly(); try valid(id); try valid(clientID)
        struct Body: Encodable { let clientId: String }
        let body = action == "decline" ? Data("{}".utf8) : try WireJSON.encoder().encode(Body(clientId: sid(clientID)))
        // Expired calls return a successful terminal state for any action. Do not infer success
        // from HTTP 200 alone or require the requested target state in this repository.
        return try result(await client.request("POST", path: ["calls", sid(id), action], body: body), expected: id)
    }
    /// Декодирует карточку вызова и сверяет запрошенный идентификатор.
    /// - Parameters:
    ///   - response: Ответ сервера, из которого извлекаются запрошенные данные.
    ///   - expected: Идентификатор вызова, который ожидается в ответе.
    private func result(_ response: NetworkResponse, expected: UUID? = nil) throws -> DirectCall {
        let item = try validate(decodeJSON(ItemResponse<DirectCall>.self, from: response).item)
        guard expected == nil || item.id == expected else { throw ClientError.scopeMismatch }
        return item
    }
    /// Проверяет согласованность карточки вызова и участие текущего пользователя.
    /// - Parameter call: Карточка личного вызова из ответа сервера.
    private func validate(_ call: DirectCall) throws -> DirectCall {
        do { return try call.validated(for: userID) }
        catch ClientError.invalidInput { throw APIError.invalidResponse }
    }
    /// Проверяет доступность личных звонков для текущего аккаунта.
    private func accountOnly() throws {
        guard client.account.user.guestConferenceId == nil else { throw ClientError.scopeMismatch }
    }
    /// Отклоняет недопустимый идентификатор вызова или клиента.
    /// - Parameter id: Проверяемый или форматируемый идентификатор из запроса.
    private func valid(_ id: UUID) throws { guard DirectCall.validID(id) else { throw ClientError.invalidInput } }
    /// Возвращает строковое представление UUID в формате API.
    /// - Parameter id: Проверяемый или форматируемый идентификатор из запроса.
    private func sid(_ id: UUID) -> String { id.uuidString.lowercased() }
}
