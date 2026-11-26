import Foundation

public struct Conference: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let ownerId: UUID
    public let title: String
    public let inviteCode: String
    public let inviteUrl: String
    public let status: String
    public let createdAt: Date
    public let updatedAt: Date
    public let startedAt: Date?
    public let finishedAt: Date?
    public let waitingRoomEnabled: Bool
    public let scheduledAt: Date?
    public let plannedDurationMin: Int?
    public var isClosed: Bool { status == "finished" || status == "cancelled" }
    /// Собирает карточку встречи с данными организатора, приглашения и расписания.
    /// - Parameters:
    ///   - id: Идентификатор конференции.
    ///   - ownerId: Идентификатор организатора встречи.
    ///   - title: Название встречи.
    ///   - inviteCode: Код приглашения на встречу.
    ///   - inviteUrl: Ссылка на приглашение, предоставленная сервером.
    ///   - status: Статус, возвращённый сервером.
    ///   - createdAt: Время создания записи.
    ///   - updatedAt: Время последнего изменения записи.
    ///   - startedAt: Фактическое время начала.
    ///   - finishedAt: Фактическое время завершения встречи.
    ///   - waitingRoomEnabled: Признак использования зала ожидания во встрече.
    ///   - scheduledAt: Планируемые дата и время начала встречи.
    ///   - plannedDurationMin: Планируемая длительность встречи в минутах.
    public init(id: UUID, ownerId: UUID, title: String, inviteCode: String = "", inviteUrl: String = "",
                status: String = "created", createdAt: Date = Date(), updatedAt: Date = Date(),
                startedAt: Date? = nil, finishedAt: Date? = nil, waitingRoomEnabled: Bool = false,
                scheduledAt: Date? = nil, plannedDurationMin: Int? = nil) {
        self.id = id; self.ownerId = ownerId; self.title = title; self.inviteCode = inviteCode; self.inviteUrl = inviteUrl
        self.status = status; self.createdAt = createdAt; self.updatedAt = updatedAt; self.startedAt = startedAt
        self.finishedAt = finishedAt; self.waitingRoomEnabled = waitingRoomEnabled; self.scheduledAt = scheduledAt
        self.plannedDurationMin = plannedDurationMin
    }
}

public struct ConferenceInvitationUser: Decodable, Sendable, Identifiable {
    public let id: UUID
    public let email: String
    public let displayName: String?
}

public struct ConferenceInvitationResult: Decodable, Sendable {
    public let email: String
    public let status: String
}

public struct ConferenceInvite: Decodable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let status: String
    public let waitingRoomEnabled: Bool
    public let scheduledAt: Date?
    enum CodingKeys: String, CodingKey { case id, title, status, waitingRoomEnabled, scheduledAt }
    /// Декодирует публичные сведения о приглашении и состояние встречи.
    /// - Parameter decoder: Декодер, установленный вызывающей стороной для чтения полей модели.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); title = try c.decode(String.self, forKey: .title)
        status = try c.decode(String.self, forKey: .status)
        waitingRoomEnabled = try c.decodeIfPresent(Bool.self, forKey: .waitingRoomEnabled) ?? false
        scheduledAt = try c.decodeIfPresent(Date.self, forKey: .scheduledAt)
    }
}

public struct ConferenceParticipant: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let conferenceId: UUID
    public let userId: UUID?
    public let displayName: String
    public let role: String
    public let status: String
    public let joinedAt: Date?
    public let leftAt: Date?
    public let createdAt: Date
    public let updatedAt: Date
    public let microphoneEnabled: Bool
    public let cameraEnabled: Bool
    public let screenSharing: Bool
    public let microphoneBlocked: Bool
    public let cameraBlocked: Bool
    public let screenBlocked: Bool
    public let mediaPolicyVersion: Int64
    public let admissionState: String
    public let admissionDecidedAt: Date?
    public let admissionVersion: Int64
    public var isAdmitted: Bool {
        (admissionState == "admitted" || admissionState.isEmpty) && !["waiting", "rejected", "kicked"].contains(status)
    }
    public var canParticipate: Bool { isAdmitted && status == "joined" }
    public var canReadHistory: Bool { isAdmitted && ["joined", "left"].contains(status) }
    public var canAdmit: Bool { canParticipate && ["owner", "co_host"].contains(role) }
    public var isWaiting: Bool { status == "waiting" && admissionState == "waiting" }
    public var isRejectedOrKicked: Bool {
        ["rejected", "kicked"].contains(status) || ["rejected", "kicked"].contains(admissionState)
    }
    /// Определяет по роли и состоянию участников, показывать ли действие модерации.
    ///
    /// Сервер проверяет полномочия повторно при выполнении команды.
    /// - Parameters:
    ///   - target: Участник встречи, для которого проверяется возможность модерации.
    ///   - action: Действие модератора над участником.
    public func canModerate(_ target: Self, action: String) -> Bool {
        guard ["mute", "camera", "screen", "kick", "role"].contains(action), canParticipate,
              conferenceId == target.conferenceId, id != target.id, target.role != "owner",
              target.canReadHistory || (action == "kick" && target.status == "kicked") else { return false }
        if role == "owner" { return true }
        return role == "co_host" && target.role == "participant" && ["mute", "screen", "kick"].contains(action)
    }
    /// Создаёт запись участника с его ролью, состоянием медиа и решением о допуске.
    /// - Parameters:
    ///   - id: Идентификатор записи участника в этой конференции.
    ///   - conferenceId: Идентификатор конференции.
    ///   - userId: Идентификатор аккаунта участника, если он известен.
    ///   - displayName: Имя пользователя, отображаемое другим участникам.
    ///   - role: Роль, назначаемая участнику.
    ///   - status: Статус, возвращённый сервером.
    ///   - joinedAt: Время входа участника в конференцию.
    ///   - leftAt: Время последнего выхода участника из конференции.
    ///   - createdAt: Время создания записи.
    ///   - updatedAt: Время последнего изменения записи.
    ///   - microphoneEnabled: Признак включённого микрофона участника.
    ///   - cameraEnabled: Признак включённой камеры участника.
    ///   - screenSharing: Признак активной демонстрации экрана.
    ///   - microphoneBlocked: Запрет на публикацию микрофона для участника.
    ///   - cameraBlocked: Запрет на публикацию камеры для участника.
    ///   - screenBlocked: Запрет на демонстрацию экрана участником.
    ///   - mediaPolicyVersion: Версия ограничений на публикацию медиа.
    ///   - admissionState: Состояние допуска из зала ожидания.
    ///   - admissionDecidedAt: Время последнего решения о допуске участника.
    ///   - admissionVersion: Версия решения о допуске участника.
    public init(id: UUID, conferenceId: UUID, userId: UUID?, displayName: String, role: String = "participant",
                status: String = "joined", joinedAt: Date? = nil, leftAt: Date? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date(), microphoneEnabled: Bool = false,
                cameraEnabled: Bool = false, screenSharing: Bool = false, microphoneBlocked: Bool = false,
                cameraBlocked: Bool = false, screenBlocked: Bool = false, mediaPolicyVersion: Int64 = 1,
                admissionState: String = "admitted", admissionDecidedAt: Date? = nil, admissionVersion: Int64 = 1) {
        self.id = id; self.conferenceId = conferenceId; self.userId = userId; self.displayName = displayName
        self.role = role; self.status = status; self.joinedAt = joinedAt; self.leftAt = leftAt
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.microphoneEnabled = microphoneEnabled
        self.cameraEnabled = cameraEnabled; self.screenSharing = screenSharing; self.microphoneBlocked = microphoneBlocked
        self.cameraBlocked = cameraBlocked; self.screenBlocked = screenBlocked; self.mediaPolicyVersion = mediaPolicyVersion
        self.admissionState = admissionState; self.admissionDecidedAt = admissionDecidedAt; self.admissionVersion = admissionVersion
    }
}

public struct ConferenceMediaState: Codable, Equatable, Sendable {
    public let connectionId: UUID
    public let sequence: Int64
    public let microphoneEnabled: Bool
    public let cameraEnabled: Bool
    public let screenSharing: Bool
    /// Собирает обновление состояния локальных медиа для конкретного подключения.
    /// - Parameters:
    ///   - connectionID: Идентификатор подключения участника к конференции.
    ///   - sequence: Порядковый номер обновления медиа для подключения.
    ///   - microphoneEnabled: Признак включённого микрофона участника.
    ///   - cameraEnabled: Признак включённой камеры участника.
    ///   - screenSharing: Признак активной демонстрации экрана.
    public init(connectionID: UUID, sequence: Int64, microphoneEnabled: Bool, cameraEnabled: Bool, screenSharing: Bool = false) {
        connectionId = connectionID; self.sequence = sequence; self.microphoneEnabled = microphoneEnabled
        self.cameraEnabled = cameraEnabled; self.screenSharing = screenSharing
    }
    /// Проверяет, что порядковый номер обновления положителен и точно представим в формате API.
    public func validate() throws {
        guard (1...9_007_199_254_740_991).contains(sequence) else { throw ClientError.invalidInput }
    }
    enum CodingKeys: String, CodingKey { case connectionId, sequence, microphoneEnabled, cameraEnabled, screenSharing }
    /// Кодирует состояние микрофона, камеры и демонстрации для API конференции.
    /// - Parameter encoder: Кодировщик, в который записываются поля модели.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(connectionId.uuidString.lowercased(), forKey: .connectionId)
        try c.encode(sequence, forKey: .sequence); try c.encode(microphoneEnabled, forKey: .microphoneEnabled)
        try c.encode(cameraEnabled, forKey: .cameraEnabled); try c.encode(screenSharing, forKey: .screenSharing)
    }
}

public struct ConferenceModeration: Encodable, Equatable, Sendable {
    public let action: String
    public let blocked: Bool?
    public let role: String?
    /// Формирует команду модерации с параметрами выбранного действия.
    /// - Parameters:
    ///   - action: Действие модератора над участником.
    ///   - blocked: Новый признак блокировки выбранного источника медиа.
    ///   - role: Роль, назначаемая участнику.
    public init(action: String, blocked: Bool? = nil, role: String? = nil) throws {
        switch action {
        case "mute", "camera", "screen": guard blocked != nil, role == nil else { throw ClientError.invalidInput }
        case "kick": guard blocked == nil, role == nil else { throw ClientError.invalidInput }
        case "role": guard blocked == nil, ["co_host", "participant"].contains(role ?? "") else { throw ClientError.invalidInput }
        default: throw ClientError.invalidInput
        }
        self.action = action; self.blocked = blocked; self.role = role
    }
}

public struct ICEServer: Codable, Equatable, Sendable {
    public let urls: [String]
    public let username: String?
    public let credential: String?
    /// Описывает ICE-сервер и необязательные данные доступа к нему.
    /// - Parameters:
    ///   - urls: Адреса STUN или TURN, доступные на этом ICE-сервере.
    ///   - username: Имя пользователя для аутентификации на TURN-сервере.
    ///   - credential: Пароль для аутентификации на TURN-сервере.
    public init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls; self.username = username; self.credential = credential
    }
}
public struct ICEConfiguration: Codable, Equatable, Sendable {
    public let iceServers: [ICEServer]
    public let iceTransportPolicy: String
    public let expiresAt: Double?
    /// Объединяет ICE-серверы, политику транспорта и срок действия конфигурации.
    /// - Parameters:
    ///   - iceServers: Настроенные STUN- и TURN-серверы.
    ///   - iceTransportPolicy: Политика выбора ICE-кандидатов, all или relay.
    ///   - expiresAt: Срок действия настроек ICE в секундах Unix или nil для бессрочной конфигурации.
    public init(iceServers: [ICEServer], iceTransportPolicy: String = "all", expiresAt: Double? = nil) {
        self.iceServers = iceServers; self.iceTransportPolicy = iceTransportPolicy; self.expiresAt = expiresAt
    }
    enum CodingKeys: String, CodingKey { case iceServers, iceTransportPolicy, expiresAt }
    /// Декодирует конфигурацию ICE, применяя политику транспорта по умолчанию.
    /// - Parameter decoder: Декодер, установленный вызывающей стороной для чтения полей модели.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        iceServers = try c.decode([ICEServer].self, forKey: .iceServers)
        iceTransportPolicy = try c.decodeIfPresent(String.self, forKey: .iceTransportPolicy) ?? "all"
        expiresAt = try c.decodeIfPresent(Double.self, forKey: .expiresAt)
    }
    /// Проверяет срок действия конфигурации, политику транспорта и адреса ICE-серверов.
    /// - Parameter now: Момент, относительно которого проверяется дата.
    public func validated(now: Date = Date()) throws -> Self {
        guard ["all", "relay"].contains(iceTransportPolicy), iceServers.count <= 16,
              expiresAt.map({ $0.isFinite && $0 > now.timeIntervalSince1970 }) ?? true else { throw ClientError.invalidInput }
        for server in iceServers {
            guard !server.urls.isEmpty, server.urls.count <= 16,
                  server.username.map({ $0.utf8.count <= 1024 && !$0.contains("\r") && !$0.contains("\n") }) ?? true,
                  server.credential.map({ $0.utf8.count <= 4096 && !$0.contains("\r") && !$0.contains("\n") }) ?? true else { throw ClientError.invalidInput }
            for value in server.urls {
                guard value.utf8.count <= 512, !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
                      !value.contains("@"), !value.contains("#"), !value.contains("\\"),
                      let colon = value.firstIndex(of: ":"), ["stun", "stuns", "turn", "turns"].contains(String(value[..<colon]).lowercased()),
                      value.index(after: colon) < value.endIndex else { throw ClientError.invalidInput }
            }
        }
        if iceTransportPolicy == "relay", !iceServers.contains(where: { $0.urls.contains(where: { $0.lowercased().hasPrefix("turn:") || $0.lowercased().hasPrefix("turns:") }) }) {
            throw ClientError.invalidInput
        }
        return self
    }
}

/// Ephemeral guest credentials never enter AccountIndex, UserDefaults or Keychain.
public struct GuestConferenceSession: Sendable {
    public let origin: ServerOrigin
    public let accessToken: String
    public let expiresAt: Date
    public let user: AccountUser
    public let participant: ConferenceParticipant
    public var conferenceID: UUID { participant.conferenceId }
    /// Создаёт гостевую сессию после проверки соответствия гостя участнику конференции.
    /// - Parameters:
    ///   - origin: Базовый HTTPS-адрес сервера MeetSpace.
    ///   - accessToken: Токен доступа, выданный сервером.
    ///   - expiresAt: Момент окончания действия данных доступа.
    ///   - user: Профиль гостя, полученный от сервера.
    ///   - participant: Запись участника конференции.
    public init(origin: ServerOrigin, accessToken: String, expiresAt: Date, user: AccountUser, participant: ConferenceParticipant) throws {
        _ = try SessionCredentials(accessToken: accessToken, sessionCookie: nil, expiresAt: expiresAt).validated()
        guard user.guestConferenceId == participant.conferenceId, participant.userId == user.id,
              expiresAt > Date() else { throw ClientError.scopeMismatch }
        self.origin = origin; self.accessToken = accessToken; self.expiresAt = expiresAt; self.user = user; self.participant = participant
    }
}

public struct ConferenceMessage: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let sequence: Int64
    public let conferenceId: UUID?
    public let senderId: UUID
    public let senderName: String
    public let clientRequestId: UUID
    public let text: String
    public let replyTo: UUID?
    public let replyPreview: ReplyPreview?
    public let version: Int64
    public let createdAt: Date
    public let updatedAt: Date
    public let deletedAt: Date?
    public let attachments: [Attachment]
    public var isDeleted: Bool { deletedAt != nil }
    /// Проверяет право пользователя редактировать сообщение конференции.
    /// - Parameter user: Идентификатор пользователя, для которого проверяется возможность редактирования.
    public func canEdit(as user: UUID) -> Bool { senderId == user && !isDeleted }
    enum CodingKeys: String, CodingKey {
        case id, sequence, conferenceId, senderId, senderName, clientRequestId, text, replyTo, replyPreview
        case version, createdAt, updatedAt, deletedAt, attachments
    }
    /// Декодирует сообщение чата встречи и проверяет номер в последовательности.
    /// - Parameter decoder: Декодер, установленный вызывающей стороной для чтения полей модели.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        let raw = try c.decode(String.self, forKey: .sequence)
        guard let sequence = Int64(raw), sequence > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .sequence, in: c, debugDescription: "Invalid sequence")
        }
        self.sequence = sequence; conferenceId = try c.decodeIfPresent(UUID.self, forKey: .conferenceId)
        senderId = try c.decode(UUID.self, forKey: .senderId); senderName = try c.decode(String.self, forKey: .senderName)
        clientRequestId = try c.decode(UUID.self, forKey: .clientRequestId); text = try c.decode(String.self, forKey: .text)
        replyTo = try c.decodeIfPresent(UUID.self, forKey: .replyTo); replyPreview = try c.decodeIfPresent(ReplyPreview.self, forKey: .replyPreview)
        version = try c.decode(Int64.self, forKey: .version); createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt); deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
    }
    /// Кодирует сообщение встречи, сохраняя номер последовательности в строковом формате API.
    /// - Parameter encoder: Кодировщик, в который записываются поля модели.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(String(sequence), forKey: .sequence); try c.encodeIfPresent(conferenceId, forKey: .conferenceId)
        try c.encode(senderId, forKey: .senderId); try c.encode(senderName, forKey: .senderName)
        try c.encode(clientRequestId, forKey: .clientRequestId); try c.encode(text, forKey: .text)
        try c.encodeIfPresent(replyTo, forKey: .replyTo); try c.encodeIfPresent(replyPreview, forKey: .replyPreview)
        try c.encode(version, forKey: .version); try c.encode(createdAt, forKey: .createdAt); try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(deletedAt, forKey: .deletedAt); try c.encode(attachments, forKey: .attachments)
    }
}
public struct ConferenceMessagePage: Decodable, Sendable {
    public let items: [ConferenceMessage]
    public let nextCursor: String?
    public let unreadCount: Int
    public let lastReadMessageId: UUID?
    enum CodingKeys: String, CodingKey { case items, nextCursor, unreadCount, lastReadMessageId }
    /// Декодирует страницу сообщений чата конференции и её состояние прочтения.
    /// - Parameter decoder: Декодер, установленный вызывающей стороной для чтения полей модели.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decode([ConferenceMessage].self, forKey: .items)
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
        // Search responses contain items/cursor only. They do not update the authoritative read state.
        unreadCount = try c.decodeIfPresent(Int.self, forKey: .unreadCount) ?? 0
        lastReadMessageId = try c.decodeIfPresent(UUID.self, forKey: .lastReadMessageId)
    }
}
