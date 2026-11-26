import Foundation
import MeetSpaceCore

public protocol SettingsServing: Sendable {
    var account: AccountRecord { get }
    /// Загружает профиль текущего пользователя.
    func profile() async throws -> AccountUser
    /// Сохраняет отображаемое имя и возвращает обновлённый профиль.
    /// - Parameter displayName: Имя пользователя, отображаемое другим участникам.
    func updateProfile(displayName: String) async throws -> AccountUser
    /// Обновляет переданные поля имени и биографии текущего пользователя.
    /// - Parameters:
    ///   - displayName: Имя пользователя, отображаемое другим участникам.
    ///   - bio: Новое описание профиля. При nil биография сохраняет прежнее значение.
    func updateProfile(displayName: String?, bio: String?) async throws -> AccountUser
    /// Получает настройки уведомлений аккаунта.
    func preferences() async throws -> NotificationPreferences
    /// Сохраняет настройки уведомлений и возвращает подтверждённые сервером значения.
    /// - Parameter value: Выбранные события и каналы доставки уведомлений.
    func savePreferences(_ value: NotificationPreferences) async throws -> NotificationPreferences
    /// Возвращает зарегистрированные устройства для уведомлений аккаунта.
    func devices() async throws -> [NotificationDevice]
    /// Загружает заявленные сервером возможности и версию сборки.
    func capabilities() async throws -> ServerCapabilities
    /// Загружает сведения о доступных серверных интеграциях.
    func integrations() async throws -> IntegrationCapabilities
}

public extension SettingsServing {
    /// Делегирует изменение имени реализации профиля, поддерживающей только это поле.
    /// - Parameters:
    ///   - displayName: Имя пользователя, отображаемое другим участникам.
    ///   - bio: Новое описание профиля. При nil биография сохраняет прежнее значение.
    func updateProfile(displayName: String?, bio: String?) async throws -> AccountUser {
        guard let displayName, bio == nil else { throw ClientError.invalidInput }
        return try await updateProfile(displayName: displayName)
    }
}

public protocol ProfilePhotoServing: Sendable {
    /// Получает фотографию профиля в формате JPEG.
    func photo() async throws -> Data
    /// Обновляет фотографию профиля или удаляет её при передаче пустого значения.
    /// - Parameter data: JPEG-изображение или nil для удаления фотографии.
    func savePhoto(_ data: Data?) async throws -> AccountUser
}

public struct SettingsRepository: SettingsServing, ProfilePhotoServing {
    public let account: AccountRecord
    private let client: AuthenticatedClient
    private let notifications: NotificationDeviceRepository
    /// Привязывает операции с профилем и настройками к текущему аккаунту.
    /// - Parameter client: Клиент, выполняющий запросы от имени текущего аккаунта.
    public init(client: AuthenticatedClient) {
        self.client = client; account = client.account; notifications = NotificationDeviceRepository(client: client)
    }
    /// Загружает профиль текущего пользователя.
    public func profile() async throws -> AccountUser {
        try accountOnly(); return try await client.currentUser()
    }
    /// Сохраняет отображаемое имя и возвращает обновлённый профиль.
    /// - Parameter displayName: Имя пользователя, отображаемое другим участникам.
    public func updateProfile(displayName: String) async throws -> AccountUser {
        try await updateProfile(displayName: displayName, bio: nil)
    }
    /// Обновляет переданные поля имени и биографии текущего пользователя.
    /// - Parameters:
    ///   - displayName: Имя пользователя, отображаемое другим участникам.
    ///   - bio: Новое описание профиля. При nil биография сохраняет прежнее значение.
    public func updateProfile(displayName: String?, bio: String?) async throws -> AccountUser {
        try accountOnly()
        struct Body: Encodable { let displayName: String?; let bio: String? }
        let name = try displayName.map(ProfileValidation.displayName)
        let biography = try bio.map(ProfileValidation.bio)
        guard name != nil || biography != nil else { throw ClientError.invalidInput }
        let response = try await client.request("PATCH", path: ["auth", "me"], body: WireJSON.encoder().encode(Body(displayName: name, bio: biography)))
        let user = try decodeJSON(UserResponse.self, from: response).user
        guard user.id == account.user.id, user.guestConferenceId == nil else { throw ClientError.accountMismatch }
        guard name == nil || user.displayName == name, biography == nil || user.bio == biography,
              user.email == account.user.email else { throw APIError.invalidResponse }
        return user
    }
    /// Получает фотографию профиля в формате JPEG.
    public func photo() async throws -> Data {
        try accountOnly()
        let response = try await client.request("GET", path: ["users", account.user.id.uuidString.lowercased(), "avatar", "content"],
                                                limit: 256 * 1024)
        guard response.headers["content-type"]?.lowercased().hasPrefix("image/jpeg") == true,
              response.data.starts(with: [0xff, 0xd8]) else { throw APIError.invalidResponse }
        return response.data
    }

    /// Обновляет фотографию профиля или удаляет её при передаче пустого значения.
    /// - Parameter data: JPEG-изображение или nil для удаления фотографии.
    public func savePhoto(_ data: Data?) async throws -> AccountUser {
        try accountOnly()
        if let data, !data.starts(with: [0xff, 0xd8]) || data.count > 2 * 1024 * 1024 { throw ClientError.invalidInput }
        let response = try await client.request(data == nil ? "DELETE" : "PUT", path: ["auth", "me", "avatar"], body: data, contentType: "image/jpeg")
        let user = try decodeJSON(UserResponse.self, from: response).user
        guard user.id == account.user.id, user.guestConferenceId == nil else { throw ClientError.accountMismatch }
        guard (user.avatarVersion != nil) == (data != nil) else { throw APIError.invalidResponse }
        return user
    }
    /// Получает настройки уведомлений аккаунта.
    public func preferences() async throws -> NotificationPreferences { try await notifications.preferences() }
    /// Сохраняет настройки уведомлений и возвращает подтверждённые сервером значения.
    /// - Parameter value: Выбранные события и каналы доставки уведомлений.
    public func savePreferences(_ value: NotificationPreferences) async throws -> NotificationPreferences {
        try await notifications.savePreferences(value)
    }
    /// Возвращает зарегистрированные устройства для уведомлений аккаунта.
    public func devices() async throws -> [NotificationDevice] { try await notifications.devices() }
    /// Загружает заявленные сервером возможности и версию сборки.
    public func capabilities() async throws -> ServerCapabilities {
        try accountOnly()
        return try decodeJSON(ServerCapabilities.self, from: await client.request("GET", path: ["capabilities"]))
    }
    /// Загружает сведения о доступных серверных интеграциях.
    public func integrations() async throws -> IntegrationCapabilities { try await notifications.capabilities() }
    /// Проверяет, что операция с настройками выполняется из обычного аккаунта.
    private func accountOnly() throws {
        guard account.user.guestConferenceId == nil else { throw ClientError.scopeMismatch }
    }
}
