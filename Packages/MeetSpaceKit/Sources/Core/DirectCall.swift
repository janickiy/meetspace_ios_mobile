import Foundation

public enum DirectCallStatus: String, Codable, CaseIterable, Sendable {
    case ringing, accepted, declined, cancelled, missed, ended
    public var isActive: Bool { self == .ringing || self == .accepted }
    public var isTerminal: Bool { !isActive }
}

public struct DirectCallPeer: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let displayName: String
    /// Создаёт краткую карточку участника личного звонка.
    /// - Parameters:
    ///   - id: Идентификатор пользователя звонка.
    ///   - displayName: Имя пользователя, отображаемое другим участникам.
    public init(id: UUID, displayName: String) { self.id = id; self.displayName = displayName }
}

/// Authoritative account-scoped state. Lease deadlines are server-only; heartbeat responses
/// can have an unchanged version. A ringing deadline is not an accepted call's expiry.
public struct DirectCall: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let conversationId: UUID
    public let conferenceId: UUID?
    public let callerUserId: UUID
    public let calleeUserId: UUID
    public let callerClientId: String
    public let acceptedByClientId: String?
    public let status: DirectCallStatus
    public let version: Int64
    public let createdAt: Date
    public let expiresAt: Date
    public let acceptedAt: Date?
    public let endedAt: Date?
    public let caller: DirectCallPeer
    public let callee: DirectCallPeer
    public let durationSec: Int64

    /// Собирает состояние личного вызова, его участников и временные отметки.
    /// - Parameters:
    ///   - id: Идентификатор личного вызова.
    ///   - conversationId: Идентификатор личного чата участников вызова.
    ///   - conferenceId: Идентификатор конференции.
    ///   - callerUserId: Идентификатор инициатора звонка.
    ///   - calleeUserId: Идентификатор вызываемого пользователя.
    ///   - callerClientId: Идентификатор клиентского устройства инициатора.
    ///   - acceptedByClientId: Идентификатор устройства, на котором приняли вызов.
    ///   - status: Статус, возвращённый сервером.
    ///   - version: Номер версии состояния звонка на сервере.
    ///   - createdAt: Время создания записи.
    ///   - expiresAt: Срок ожидания ответа на входящий вызов.
    ///   - acceptedAt: Время принятия входящего вызова.
    ///   - endedAt: Время перехода вызова в конечное состояние.
    ///   - caller: Краткая карточка инициатора звонка.
    ///   - callee: Краткая карточка вызываемого пользователя.
    ///   - durationSec: Длительность в секундах.
    public init(id: UUID, conversationId: UUID, conferenceId: UUID? = nil,
                callerUserId: UUID, calleeUserId: UUID, callerClientId: String, acceptedByClientId: String? = nil,
                status: DirectCallStatus, version: Int64, createdAt: Date, expiresAt: Date,
                acceptedAt: Date? = nil, endedAt: Date? = nil, caller: DirectCallPeer, callee: DirectCallPeer,
                durationSec: Int64 = 0) {
        self.id = id; self.conversationId = conversationId; self.conferenceId = conferenceId
        self.callerUserId = callerUserId; self.calleeUserId = calleeUserId; self.callerClientId = callerClientId
        self.acceptedByClientId = acceptedByClientId; self.status = status; self.version = version
        self.createdAt = createdAt; self.expiresAt = expiresAt; self.acceptedAt = acceptedAt; self.endedAt = endedAt
        self.caller = caller; self.callee = callee; self.durationSec = durationSec
    }

    public var isActive: Bool { status.isActive }
    public var isTerminal: Bool { status.isTerminal }
    /// Находит второго участника звонка относительно указанного пользователя.
    /// - Parameter userID: Идентификатор пользователя на выбранном сервере.
    public func peer(for userID: UUID) -> DirectCallPeer? {
        if userID == callerUserId { return callee }
        if userID == calleeUserId { return caller }
        return nil
    }
    /// Проверяет, принадлежит ли устройство вызывающей стороне или участнику, принявшему звонок.
    ///
    /// Перед началом захвата медиа вызывающий код также проверяет, что звонок принят.
    /// - Parameters:
    ///   - userID: Идентификатор пользователя на выбранном сервере.
    ///   - clientID: Идентификатор экземпляра клиента на устройстве пользователя.
    public func ownsMedia(userID: UUID, clientID: UUID) -> Bool {
        let client = clientID.uuidString.lowercased()
        return (userID == callerUserId && callerClientId == client) ||
            (userID == calleeUserId && acceptedByClientId == client)
    }
    /// Проверяет участников, идентификаторы и согласованность полей со статусом вызова.
    /// - Parameter userID: Идентификатор пользователя на выбранном сервере.
    public func validated(for userID: UUID) throws -> Self {
        guard peer(for: userID) != nil else { throw ClientError.scopeMismatch }
        guard [id, conversationId, callerUserId, calleeUserId].allSatisfy(Self.validID),
              conferenceId.map(Self.validID) ?? true, callerUserId != calleeUserId,
              caller.id == callerUserId, callee.id == calleeUserId,
              Self.validClientID(callerClientId), acceptedByClientId.map(Self.validClientID) ?? true,
              version > 0, durationSec >= 0 else { throw ClientError.invalidInput }
        switch status {
        case .accepted, .ended:
            guard conferenceId != nil, acceptedByClientId != nil, acceptedAt != nil else { throw ClientError.invalidInput }
        case .ringing, .declined, .cancelled, .missed:
            guard conferenceId == nil, acceptedByClientId == nil, acceptedAt == nil else { throw ClientError.invalidInput }
        }
        guard isTerminal == (endedAt != nil) else { throw ClientError.invalidInput }
        return self
    }
    /// Проверяет, отличается ли UUID от нулевого идентификатора.
    /// - Parameter id: UUID вызова, чата или участника для проверки.
    public static func validID(_ id: UUID) -> Bool { id.uuidString != "00000000-0000-0000-0000-000000000000" }
    /// Проверяет строковый UUID клиента на канонический нижний регистр и ненулевое значение.
    /// - Parameter value: Строковое представление идентификатора устройства клиента.
    private static func validClientID(_ value: String) -> Bool {
        guard let id = UUID(uuidString: value) else { return false }
        return validID(id) && id.uuidString.lowercased() == value
    }
}
