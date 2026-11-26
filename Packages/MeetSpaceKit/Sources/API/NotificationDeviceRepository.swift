import Foundation
import MeetSpaceCore

public protocol NotificationDevicesServing: Sendable {
    var origin: ServerOrigin { get }
    var userID: UUID { get }
    /// Загружает доступные на сервере интеграции уведомлений.
    func capabilities() async throws -> IntegrationCapabilities
    /// Возвращает устройства, зарегистрированные для уведомлений текущего аккаунта.
    func devices() async throws -> [NotificationDevice]
    /// Регистрирует токен обычных push-уведомлений iOS для текущего аккаунта.
    /// - Parameter token: Токен для доставки обычных push-уведомлений на iOS.
    func register(token: String) async throws -> NotificationDevice
    /// Отзывает регистрацию устройства для уведомлений.
    /// - Parameter deviceID: Идентификатор зарегистрированного устройства на сервере.
    func revoke(_ deviceID: UUID) async throws
    /// Получает сохранённые сервером настройки уведомлений аккаунта.
    func preferences() async throws -> NotificationPreferences
    /// Сохраняет выбор событий и каналов доставки уведомлений.
    /// - Parameter preferences: Выбранные настройки уведомлений аккаунта.
    func savePreferences(_ preferences: NotificationPreferences) async throws -> NotificationPreferences
}

/// Uses only the existing ordinary-notification API. Never send PushKit VoIP tokens here.
public struct NotificationDeviceRepository: NotificationDevicesServing {
    public let origin: ServerOrigin
    public let userID: UUID
    private let client: AuthenticatedClient
    /// Привязывает работу с push-устройствами к авторизованному аккаунту.
    /// - Parameter client: Клиент, выполняющий запросы от имени текущего аккаунта.
    public init(client: AuthenticatedClient) {
        self.client = client; origin = client.account.server; userID = client.account.user.id
    }
    /// Загружает доступные на сервере интеграции уведомлений.
    public func capabilities() async throws -> IntegrationCapabilities {
        try accountOnly()
        return try decodeJSON(IntegrationCapabilities.self, from: await client.request("GET", path: ["integrations", "capabilities"]))
    }
    /// Возвращает устройства, зарегистрированные для уведомлений текущего аккаунта.
    public func devices() async throws -> [NotificationDevice] {
        try accountOnly()
        let items = try decodeJSON(ItemsResponse<NotificationDevice>.self, from: await client.request("GET", path: ["notifications", "devices"])).items
        guard items.count <= 100, Set(items.map(\.id)).count == items.count,
              items.allSatisfy({ DirectCall.validID($0.id) && ["ios", "android", "web"].contains($0.platform) })
        else { throw APIError.invalidResponse }
        return items
    }
    /// Регистрирует токен обычных push-уведомлений iOS для текущего аккаунта.
    /// - Parameter token: Токен для доставки обычных push-уведомлений на iOS.
    public func register(token: String) async throws -> NotificationDevice {
        try accountOnly()
        guard (8...8192).contains(token.utf8.count),
              !token.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) })
        else { throw ClientError.invalidInput }
        struct Body: Encodable { let platform = "ios"; let token: String }
        let item = try decodeJSON(ItemResponse<NotificationDevice>.self, from: await client.request("POST", path: ["notifications", "devices"],
            body: WireJSON.encoder().encode(Body(token: token)))).item
        guard DirectCall.validID(item.id), item.platform == "ios", item.isActive else { throw APIError.invalidResponse }
        return item
    }
    /// Отзывает регистрацию устройства для уведомлений.
    /// - Parameter deviceID: Идентификатор зарегистрированного устройства на сервере.
    public func revoke(_ deviceID: UUID) async throws {
        try accountOnly()
        guard DirectCall.validID(deviceID) else { throw ClientError.invalidInput }
        _ = try await client.request("DELETE", path: ["notifications", "devices", deviceID.uuidString.lowercased()])
    }
    /// Получает сохранённые сервером настройки уведомлений аккаунта.
    public func preferences() async throws -> NotificationPreferences {
        try accountOnly()
        return try decodeJSON(NotificationPreferences.self, from: await client.request("GET", path: ["notifications", "preferences"]))
    }
    /// Сохраняет выбор событий и каналов доставки уведомлений.
    /// - Parameter preferences: Выбранные настройки уведомлений аккаунта.
    public func savePreferences(_ preferences: NotificationPreferences) async throws -> NotificationPreferences {
        try accountOnly()
        return try decodeJSON(NotificationPreferences.self, from: await client.request("PUT", path: ["notifications", "preferences"],
            body: WireJSON.encoder().encode(preferences)))
    }
    /// Отклоняет операции с push-устройствами из гостевой сессии.
    private func accountOnly() throws {
        guard client.account.user.guestConferenceId == nil else { throw ClientError.scopeMismatch }
    }
}
