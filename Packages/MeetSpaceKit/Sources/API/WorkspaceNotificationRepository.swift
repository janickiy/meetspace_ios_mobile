import Foundation
import MeetSpaceCore

public struct WorkspaceNotification: Identifiable, Decodable, Sendable {
    public struct Payload: Decodable, Sendable {
        public let conversationId: UUID?
        public let recordingId: UUID?
    }
    public let id: UUID
    public let userId: UUID
    public let type: String
    public let payload: Payload
    public let createdAt: Date
    public let readAt: Date?
}

public struct WorkspaceNotificationPage: Decodable, Sendable {
    public let items: [WorkspaceNotification]
    public let nextCursor: String?
    public let unreadCount: Int
}

public struct WorkspaceNotificationRepository: Sendable {
    private let client: AuthenticatedClient
    /// Создаёт репозиторий уведомлений рабочего пространства текущего аккаунта.
    /// - Parameter client: Клиент, выполняющий запросы от имени текущего аккаунта.
    public init(client: AuthenticatedClient) { self.client = client }

    /// Загружает страницу уведомлений пользователя.
    /// - Parameter cursor: Курсор продолжения из предыдущего ответа. Для первой страницы передайте nil.
    public func list(cursor: String? = nil) async throws -> WorkspaceNotificationPage {
        let query = cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? []
        let page = try decodeJSON(WorkspaceNotificationPage.self, from: await client.request("GET", path: ["notifications"], query: query))
        guard page.unreadCount >= 0, page.items.allSatisfy({ $0.userId == client.account.user.id }),
              Set(page.items.map(\.id)).count == page.items.count else { throw APIError.invalidResponse }
        return page
    }

    /// Отмечает выбранное уведомление прочитанным.
    /// - Parameter id: Идентификатор уведомления рабочего пространства.
    public func markRead(_ id: UUID) async throws {
        let item = try decodeJSON(ItemResponse<WorkspaceNotification>.self, from: await client.request("POST",
            path: ["notifications", id.uuidString.lowercased(), "read"], body: Data("{}".utf8))).item
        guard item.id == id, item.userId == client.account.user.id, item.readAt != nil else { throw APIError.invalidResponse }
    }
}
