import Foundation
import CryptoKit
import MeetSpaceCore

public struct WSTicket: Decodable, Sendable {
    public let ticket: String
    public let expiresAt: Date
}
public struct AttachmentUpload: Decodable, Sendable {
    public let item: Attachment
    public let uploadUrl: String
}
public struct DownloadDescriptor: Decodable, Sendable {
    public let url: String
    public let expiresAt: Date
    public let authenticated: Bool?
}
public struct UploadInput: Encodable, Sendable {
    public let clientRequestId: UUID
    public let filename: String
    public let mimeType: String
    public let size: Int
    /// Описывает локальное вложение перед подготовкой загрузки.
    /// - Parameters:
    ///   - id: Идентификатор запроса на подготовку вложения.
    ///   - filename: Имя файла с расширением.
    ///   - mimeType: MIME-тип файла.
    ///   - size: Размер файла в байтах.
    public init(id: UUID, filename: String, mimeType: String, size: Int) {
        clientRequestId = id; self.filename = filename; self.mimeType = mimeType; self.size = size
    }
}

public enum ChatMaterialKind: String, CaseIterable, Sendable { case media, file, link }

public struct ChatMaterialPage: Decodable, Sendable {
    public struct Item: Decodable, Sendable {
        public let message: ChatMessage
        public let attachment: Attachment?
        public let url: String?
    }
    public let items: [Item]
    public let nextCursor: String?
}

public struct MessagingRepository: Sendable {
    public let client: AuthenticatedClient
    private let downloads: any RequestTransport
    /// Создаёт репозиторий чатов с отдельным транспортом для файлов вложений.
    /// - Parameters:
    ///   - client: Клиент, выполняющий запросы от имени текущего аккаунта.
    ///   - downloads: Транспорт для скачивания вложений по выданным сервером адресам.
    public init(client: AuthenticatedClient, downloads: any RequestTransport = URLSessionRequestTransport()) {
        self.client = client; self.downloads = downloads
    }
    /// Загружает страницу чатов с учётом поиска, типа и признака непрочитанных сообщений.
    /// - Parameters:
    ///   - cursor: Курсор продолжения из предыдущего ответа. Для первой страницы передайте nil.
    ///   - search: Строка поиска для отбора результатов.
    ///   - type: Фильтр по типу чата. При nil возвращаются чаты всех типов.
    ///   - unreadOnly: При true выборка ограничена чатами с непрочитанными сообщениями.
    public func conversations(cursor: String? = nil, search: String = "", type: String? = nil, unreadOnly: Bool = false) async throws -> ConversationPage {
        var query = pageQuery(cursor)
        if !search.isEmpty { query.append(URLQueryItem(name: "search", value: search)) }
        if let type { query.append(URLQueryItem(name: "type", value: type)) }
        if unreadOnly { query.append(URLQueryItem(name: "unreadOnly", value: "true")) }
        return try decodeJSON(ConversationPage.self, from: await client.request("GET", path: ["conversations"], query: query))
    }
    /// Загружает сведения о выбранном чате.
    /// - Parameter id: Идентификатор чата.
    public func conversation(_ id: UUID) async throws -> Conversation {
        try decodeJSON(ItemResponse<Conversation>.self, from: await client.request("GET", path: scope(id))).item
    }
    /// Загружает профиль контакта в контексте выбранного чата.
    /// - Parameters:
    ///   - conversation: Идентификатор чата.
    ///   - user: Идентификатор выбранного пользователя в чате.
    public func contactProfile(_ conversation: UUID, user: UUID) async throws -> ContactProfile {
        let response = try await client.request("GET", path: scope(conversation) + ["profiles", sid(user)])
        let profile = try decodeJSON(ItemResponse<ContactProfile>.self, from: response).item
        guard profile.id == user else { throw APIError.invalidResponse }
        return profile
    }
    /// Проверяет присутствие собеседника по серверным данным чата.
    /// - Parameters:
    ///   - conversation: Идентификатор чата.
    ///   - user: Идентификатор выбранного пользователя в чате.
    public func peerOnline(_ conversation: UUID, user: UUID) async throws -> Bool {
        struct Presence: Decodable {
            let conversationId: UUID
            let peerId: UUID
            let online: Bool
        }
        struct Response: Decodable {
            let status: String
            let item: Presence
        }
        let response = try await client.request("GET", path: scope(conversation) + ["peer-presence"])
        let result = try decodeJSON(Response.self, from: response)
        guard result.status == "success", result.item.conversationId == conversation, result.item.peerId == user else {
            throw APIError.invalidResponse
        }
        return result.item.online
    }
    /// Получает страницу материалов выбранного типа в чате.
    /// - Parameters:
    ///   - conversation: Идентификатор чата.
    ///   - kind: Категория материалов чата для выборки.
    ///   - cursor: Курсор продолжения из предыдущего ответа. Для первой страницы передайте nil.
    public func materials(_ conversation: UUID, kind: ChatMaterialKind, cursor: String?) async throws -> ChatMaterialPage {
        let query = pageQuery(cursor) + [URLQueryItem(name: "kind", value: kind.rawValue)]
        let response = try await client.request("GET", path: scope(conversation) + ["materials"], query: query)
        let page = try decodeJSON(ChatMaterialPage.self, from: response)
        guard page.items.count <= 50, page.items.allSatisfy({ item in
            let message = item.message
            guard message.conversationId == conversation, message.isActionable else { return false }
            if kind == .link { return item.url != nil }
            guard let file = item.attachment, file.conversationId == conversation, file.messageId == message.id,
                  message.attachments.contains(file) else { return false }
            let media = file.mimeType.hasPrefix("image/") || file.mimeType.hasPrefix("video/")
            return (kind == .media) == media
        }) else { throw APIError.invalidResponse }
        return page
    }
    /// Ищет пользователей по введённой строке.
    /// - Parameter search: Строка поиска для отбора результатов.
    public func users(search: String) async throws -> [Peer] {
        try decodeJSON(ItemsResponse<Peer>.self, from: await client.request("GET", path: ["users"],
            query: [URLQueryItem(name: "search", value: search)])).items
    }
    /// Открывает или создаёт личный чат с пользователем.
    /// - Parameter userID: Идентификатор пользователя на выбранном сервере.
    public func direct(userID: UUID) async throws -> Conversation {
        struct Body: Encodable { let userId: UUID }
        let conversation = try decodeJSON(ItemResponse<Conversation>.self, from: await client.request("POST", path: ["conversations", "direct"],
            body: WireJSON.encoder().encode(Body(userId: userID)))).item
        guard conversation.type == "direct", conversation.peer?.id == userID else { throw APIError.invalidResponse }
        return conversation
    }
    /// Создаёт групповой чат с указанным составом участников.
    /// - Parameters:
    ///   - id: Клиентский идентификатор запроса на создание группы для повторной отправки.
    ///   - name: Новое название группового чата.
    ///   - description: Описание группового чата.
    ///   - members: Идентификаторы пользователей, включаемых в создаваемую группу.
    public func createGroup(id: UUID, name: String, description: String, members: [UUID]) async throws -> Conversation {
        try validateGroup(name: name, description: description)
        guard members.count < 100 else { throw ClientError.invalidInput }
        struct Body: Encodable { let clientRequestId: UUID; let name: String; let description: String; let memberIds: [UUID] }
        let body = Body(clientRequestId: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), description: description, memberIds: members)
        return try decodeJSON(ItemResponse<Conversation>.self, from: await client.request("POST", path: ["conversations", "group"],
            body: WireJSON.encoder().encode(body))).item
    }
    /// Загружает страницу сообщений чата с учётом поиска и границы истории.
    /// - Parameters:
    ///   - conversation: Идентификатор чата.
    ///   - before: Курсор предыдущей страницы истории. Для первого запроса передайте nil.
    ///   - search: Строка поиска для отбора результатов.
    public func messages(_ conversation: UUID, before: String? = nil, search: String? = nil) async throws -> MessagePage {
        var query = pageQuery(before)
        var path = scope(conversation) + ["messages"]
        if let search, !search.isEmpty {
            guard (2...200).contains(search.unicodeScalars.count) else { throw ClientError.invalidInput }
            path += ["search"]; query.append(URLQueryItem(name: "q", value: search))
        }
        return try decodeJSON(MessagePage.self, from: await client.request("GET", path: path, query: query))
    }
    /// Загружает фрагмент переписки вокруг выбранного сообщения.
    /// - Parameters:
    ///   - conversation: Идентификатор чата.
    ///   - message: Идентификатор сообщения в выбранном чате.
    public func context(_ conversation: UUID, message: UUID) async throws -> MessagePage {
        try decodeJSON(MessagePage.self, from: await client.request("GET", path: scope(conversation) + ["messages", sid(message), "context"]))
    }
    /// Отправляет подготовленное сообщение в чат.
    /// - Parameters:
    ///   - conversation: Идентификатор чата.
    ///   - draft: Подготовленное сообщение с текстом, вложениями и идентификатором отправки.
    public func send(_ conversation: UUID, draft: MessageDraft) async throws -> ChatMessage {
        try decodeJSON(ItemResponse<ChatMessage>.self, from: await client.request("POST", path: scope(conversation) + ["messages"],
            body: WireJSON.encoder().encode(draft))).item
    }
    /// Меняет текст выбранного сообщения и возвращает его новую версию.
    /// - Parameters:
    ///   - conversation: Идентификатор чата.
    ///   - message: Идентификатор сообщения в выбранном чате.
    ///   - text: Текст сообщения.
    public func edit(_ conversation: UUID, message: UUID, text: String) async throws -> ChatMessage {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.unicodeScalars.count <= 4000, !normalized.contains("\0") else { throw ClientError.invalidInput }
        struct Body: Encodable { let text: String }
        return try decodeJSON(ItemResponse<ChatMessage>.self, from: await client.request("PATCH",
            path: scope(conversation) + ["messages", sid(message)], body: WireJSON.encoder().encode(Body(text: normalized)))).item
    }
    /// Удаляет сообщение и возвращает его состояние после удаления.
    /// - Parameters:
    ///   - conversation: Идентификатор чата.
    ///   - message: Идентификатор сообщения в выбранном чате.
    public func delete(_ conversation: UUID, message: UUID) async throws -> ChatMessage {
        let deleted = try decodeJSON(ItemResponse<ChatMessage>.self, from: await client.request("DELETE",
            path: scope(conversation) + ["messages", sid(message)])).item
        guard deleted.id == message, deleted.conversationId == conversation, deleted.isDeleted else { throw APIError.invalidResponse }
        return deleted
    }
    /// Пересылает выбранные сообщения из исходного чата в целевой.
    /// - Parameters:
    ///   - destination: Идентификатор чата, куда пересылаются сообщения.
    ///   - source: Идентификатор чата с исходными сообщениями.
    ///   - messages: Идентификаторы сообщений для пересылки.
    ///   - requestID: Уникальный идентификатор отправленного запроса.
    public func forward(_ destination: UUID, source: UUID, messages: [UUID], requestID: UUID) async throws -> [ChatMessage] {
        guard (1...30).contains(messages.count), Set(messages).count == messages.count else { throw ClientError.invalidInput }
        struct Body: Encodable { let sourceType = "conversation"; let sourceId: UUID; let messageIds: [UUID]; let clientRequestId: UUID }
        let body = Body(sourceId: source, messageIds: messages, clientRequestId: requestID)
        let items = try decodeJSON(ItemsResponse<ChatMessage>.self, from: await client.request("POST",
            path: scope(destination) + ["messages", "forward"], body: WireJSON.encoder().encode(body))).items
        guard items.count == messages.count, Set(items.map(\.id)).count == items.count,
              items.allSatisfy({ $0.conversationId == destination && $0.senderId == client.account.user.id &&
                  $0.call == nil && ($0.isDeleted || $0.forwardedFrom?.senderName.isEmpty == false) }) else { throw APIError.invalidResponse }
        return items
    }
    /// Закрепляет или открепляет сообщение в чате.
    /// - Parameters:
    ///   - conversation: Идентификатор чата.
    ///   - message: Идентификатор сообщения в выбранном чате.
    ///   - pinned: При true сообщение закрепляется, при false закрепление снимается.
    public func pin(_ conversation: UUID, message: UUID, pinned: Bool) async throws {
        _ = try await client.request(pinned ? "PUT" : "DELETE", path: scope(conversation) + ["pins", sid(message)])
    }
    /// Отмечает переписку прочитанной до указанного сообщения включительно.
    /// - Parameters:
    ///   - conversation: Идентификатор чата.
    ///   - message: Идентификатор сообщения в выбранном чате.
    public func markRead(_ conversation: UUID, through message: UUID) async throws -> ReadState {
        struct Body: Encodable { let messageId: UUID }
        return try decodeJSON(ItemResponse<ReadState>.self, from: await client.request("PUT", path: scope(conversation) + ["chat", "read"],
            body: WireJSON.encoder().encode(Body(messageId: message)))).item
    }
    /// Меняет режим уведомлений для выбранного чата.
    /// - Parameters:
    ///   - id: Идентификатор чата.
    ///   - enabled: Признак включённых уведомлений.
    public func setNotifications(_ id: UUID, enabled: Bool) async throws -> Conversation {
        struct Body: Encodable { let notificationsEnabled: Bool }
        let data = try await client.request("PATCH", path: scope(id) + ["preferences"],
                                            body: WireJSON.encoder().encode(Body(notificationsEnabled: enabled)))
        let item = try decodeJSON(ItemResponse<Conversation>.self, from: data).item
        guard item.id == id, item.notificationsEnabled == enabled else { throw APIError.invalidResponse }
        return item
    }
    /// Очищает историю личной переписки для текущего пользователя.
    /// - Parameter id: Идентификатор чата.
    public func clearDirectHistory(_ id: UUID) async throws {
        _ = try await client.request("POST", path: scope(id) + ["clear-history"])
    }
    /// Скрывает личный чат из списка текущего пользователя.
    /// - Parameter id: Идентификатор чата.
    public func hideDirectConversation(_ id: UUID) async throws {
        _ = try await client.request("POST", path: scope(id) + ["hide"])
    }
    /// Загружает список участников группового чата.
    /// - Parameter conversation: Идентификатор чата.
    public func members(_ conversation: UUID) async throws -> [GroupMember] {
        try decodeJSON(ItemsResponse<GroupMember>.self, from: await client.request("GET", path: scope(conversation) + ["members"])).items
    }
    /// Сохраняет название и описание группы.
    /// - Parameters:
    ///   - conversation: Идентификатор чата.
    ///   - name: Новое название группового чата.
    ///   - description: Описание группового чата.
    public func updateGroup(_ conversation: UUID, name: String, description: String) async throws -> Conversation {
        try validateGroup(name: name, description: description)
        struct Body: Encodable { let name: String; let description: String }
        return try decodeJSON(ItemResponse<Conversation>.self, from: await client.request("PATCH", path: scope(conversation),
            body: WireJSON.encoder().encode(Body(name: name, description: description)))).item
    }
    /// Добавляет пользователей в группу.
    /// - Parameters:
    ///   - conversation: Идентификатор чата.
    ///   - users: Идентификаторы добавляемых пользователей.
    public func addMembers(_ conversation: UUID, users: [UUID]) async throws {
        struct Body: Encodable { let userIds: [UUID] }
        _ = try await client.request("POST", path: scope(conversation) + ["members"], body: WireJSON.encoder().encode(Body(userIds: users)))
    }
    /// Удаляет участника из группы.
    /// - Parameters:
    ///   - conversation: Идентификатор чата.
    ///   - user: Идентификатор выбранного пользователя в чате.
    public func removeMember(_ conversation: UUID, user: UUID) async throws {
        _ = try await client.request("DELETE", path: scope(conversation) + ["members", sid(user)])
    }
    /// Меняет роль участника в группе.
    /// - Parameters:
    ///   - conversation: Идентификатор чата.
    ///   - user: Идентификатор выбранного пользователя в чате.
    ///   - role: Роль, назначаемая участнику.
    public func changeRole(_ conversation: UUID, user: UUID, role: String) async throws {
        guard ["admin", "member"].contains(role) else { throw ClientError.invalidInput }
        struct Body: Encodable { let role: String }
        _ = try await client.request("PATCH", path: scope(conversation) + ["members", sid(user)], body: WireJSON.encoder().encode(Body(role: role)))
    }
    /// Передаёт права владельца группы выбранному участнику.
    /// - Parameters:
    ///   - conversation: Идентификатор чата.
    ///   - user: Идентификатор выбранного пользователя в чате.
    public func transferOwnership(_ conversation: UUID, user: UUID) async throws {
        struct Body: Encodable { let userId: UUID }
        _ = try await client.request("POST", path: scope(conversation) + ["ownership"], body: WireJSON.encoder().encode(Body(userId: user)))
    }
    /// Выводит текущего пользователя из группы.
    /// - Parameter conversation: Идентификатор чата.
    public func leaveGroup(_ conversation: UUID) async throws {
        _ = try await client.request("POST", path: scope(conversation) + ["leave"], body: Data("{}".utf8))
    }
    /// Удаляет указанный групповой чат.
    /// - Parameter conversation: Идентификатор чата.
    public func deleteGroup(_ conversation: UUID) async throws { _ = try await client.request("DELETE", path: scope(conversation)) }
    /// Получает билет для подключения к потоку событий пользователя.
    public func ticket() async throws -> WSTicket {
        let ticket = try decodeJSON(WSTicket.self, from: await client.request("POST", path: ["ws-ticket"]))
        guard ticket.expiresAt > Date(), ticket.ticket.utf8.count == 43, SessionCookie.valid(ticket.ticket) else { throw APIError.invalidResponse }
        return ticket
    }
    /// Подготавливает вложение, передаёт файл при необходимости и подтверждает загрузку.
    /// - Parameters:
    ///   - conversation: Идентификатор чата.
    ///   - input: Имя, MIME-тип, размер файла и идентификатор подготовки загрузки.
    ///   - file: Локальный адрес подготовленного файла для отправки.
    ///   - progress: Обработчик доли переданных данных от 0 до 1.
    public func upload(_ conversation: UUID, input: UploadInput, file: URL, progress: TransferProgress? = nil) async throws -> Attachment {
        try FilePolicy.validateName(input.filename)
        guard input.mimeType == (try FilePolicy.mimeType(for: input.filename)), (1...FilePolicy.maximumBytes).contains(input.size)
        else { throw ClientError.invalidInput }
        let started = try decodeJSON(AttachmentUpload.self, from: await client.request("POST", path: scope(conversation) + ["attachments", "init"],
            body: WireJSON.encoder().encode(input)))
        let attachment = started.item
        guard attachment.conversationId == conversation, attachment.ownerId == client.account.user.id,
              attachment.size == input.size, attachment.filename == input.filename, attachment.mimeType == input.mimeType
        else { throw ClientError.scopeMismatch }
        let path = scope(conversation) + ["attachments", sid(attachment.id), "content"]
        let expected = try EndpointURL.make(client.account.server, path: path)
        guard resolve(started.uploadUrl) == expected else { throw ClientError.scopeMismatch }
        // A finalize response may have been lost. Reuse the ready attachment instead of PUT-ing it again.
        if attachment.status == "ready", attachment.expiresAt > Date() { progress?(1); return attachment }
        guard attachment.status == "pending", attachment.expiresAt > Date() else { throw APIError.httpStatus(409) }
        _ = try await client.request("PUT", path: path, uploadFile: file, contentType: input.mimeType, progress: progress)
        let ready = try decodeJSON(ItemResponse<Attachment>.self, from: await client.request("POST",
            path: scope(conversation) + ["attachments", sid(attachment.id), "finalize"], body: Data("{}".utf8))).item
        guard ready.id == attachment.id, ready.status == "ready", ready.conversationId == conversation else { throw APIError.invalidResponse }
        return ready
    }
    /// Скачивает и проверяет файл вложения для выбранного чата.
    /// - Parameters:
    ///   - conversation: Идентификатор чата.
    ///   - attachment: Метаданные скачиваемого вложения.
    ///   - progress: Обработчик доли переданных данных от 0 до 1.
    public func download(_ conversation: UUID, attachment: Attachment, progress: TransferProgress? = nil) async throws -> Data {
        guard attachment.conversationId == conversation, attachment.size > 0, attachment.size <= FilePolicy.maximumBytes
        else { throw ClientError.scopeMismatch }
        try FilePolicy.validateName(attachment.filename)
        let info = try decodeJSON(DownloadDescriptor.self, from: await client.request("GET",
            path: scope(conversation) + ["attachments", sid(attachment.id), "download"]))
        guard info.expiresAt > Date() else { throw APIError.invalidResponse }
        let response: NetworkResponse
        if info.authenticated == true {
            let path = scope(conversation) + ["attachments", sid(attachment.id), "content"]
            guard resolve(info.url) == (try EndpointURL.make(client.account.server, path: path)) else { throw ClientError.scopeMismatch }
            response = try await client.request("GET", path: path, limit: Int(attachment.size), progress: progress)
        } else {
            guard let url = URL(string: info.url), url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil, url.fragment == nil else { throw APIError.tls }
            // Signed object-store URLs never receive API credentials, even on the same host.
            response = try await downloads.send(URLRequest(url: url), limit: Int(attachment.size), uploadFile: nil, progress: progress)
            try requireSuccess(response)
        }
        guard response.data.count == attachment.size else { throw APIError.invalidResponse }
        if let checksum = attachment.checksum, !checksum.isEmpty {
            let actual = SHA256.hash(data: response.data).map { String(format: "%02x", $0) }.joined()
            guard checksum.lowercased() == actual else { throw APIError.invalidResponse }
        }
        return response.data
    }
    /// Отменяет незавершённые передачи через транспорт скачивания вложений.
    public func cancelDownloads() async { await downloads.cancelAll() }
    /// Разрешает адрес вложения относительно сервера текущего аккаунта.
    /// - Parameter raw: Строковый адрес, полученный от сервера.
    private func resolve(_ raw: String) -> URL? { URL(string: raw, relativeTo: client.account.server.url)?.absoluteURL }
    /// Формирует путь API выбранного чата.
    /// - Parameter id: Идентификатор чата.
    private func scope(_ id: UUID) -> [String] { ["conversations", sid(id)] }
    /// Форматирует UUID в нижнем регистре для API.
    /// - Parameter id: Идентификатор ресурса, включаемый в путь запроса.
    private func sid(_ id: UUID) -> String { id.uuidString.lowercased() }
    /// Формирует параметры запроса следующей страницы материалов или чатов.
    /// - Parameter cursor: Курсор продолжения из предыдущего ответа. Для первой страницы передайте nil.
    private func pageQuery(_ cursor: String?) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "limit", value: "50")]
        if let cursor, !cursor.isEmpty { items.append(URLQueryItem(name: "before", value: cursor)) }
        return items
    }
    /// Проверяет допустимую длину названия и описания группы.
    /// - Parameters:
    ///   - name: Новое название группового чата.
    ///   - description: Описание группового чата.
    private func validateGroup(name: String, description: String) throws {
        guard (1...50).contains(name.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count),
              description.unicodeScalars.count <= 200 else { throw ClientError.invalidInput }
    }
}
