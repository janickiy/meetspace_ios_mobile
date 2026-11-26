import Foundation

public enum LoadState: Equatable, Sendable {
    case loading, empty, content, offline, failed
}

public enum AppTab: String, CaseIterable, Sendable { case meetings, messages, profile }

public enum AppRoute: Hashable, Sendable {
    case calendar, recordings, folders, prejoin, call, personalCall
    case contactCall(Int)
    case meetingDetails(Int), recording(Int), thread(Int)
    case conversation(UUID), liveRecording(UUID), demoFolder(UUID)
    case newMeeting, scheduleMeeting, joinMeeting
    case audioSettings, videoSettings, notificationSettings, appearance, connection, accounts
    case interfaceCatalog
    case deploy, fingerprint, preflight, install, complete, installError
}

public enum Appearance: String, Codable, CaseIterable, Sendable { case system, light, dark }

public struct AppConfiguration: Codable, Equatable, Sendable {
    public var server: ServerOrigin?
    public var appearance: Appearance
    /// Задаёт выбранный сервер и оформление приложения.
    /// - Parameters:
    ///   - server: Базовый адрес сервера аккаунта.
    ///   - appearance: Выбранная тема оформления.
    public init(server: ServerOrigin? = nil, appearance: Appearance = .system) {
        self.server = server
        self.appearance = appearance
    }
}

public protocol ConfigurationStore: Sendable {
    /// Загружает сохранённую конфигурацию приложения.
    func load() async throws -> AppConfiguration
    /// Сохраняет выбранный сервер и оформление приложения.
    /// - Parameter configuration: Настройки сервера и оформления приложения.
    func save(_ configuration: AppConfiguration) async throws
}

/// Secrets are scoped to a server AND account, even before multi-account UI is implemented.
public struct CredentialKey: Hashable, Sendable {
    public let server: ServerOrigin
    public let accountID: UUID
    /// Формирует ключ учётных данных для сочетания сервера и аккаунта.
    /// - Parameters:
    ///   - server: Базовый адрес сервера аккаунта.
    ///   - accountID: Идентификатор пользователя текущего аккаунта.
    public init(server: ServerOrigin, accountID: UUID) {
        self.server = server
        self.accountID = accountID
    }
    public var storageKey: String { server.url.absoluteString + "|" + accountID.uuidString }
}

public protocol SecureStore: Sendable {
    /// Читает защищённые данные аккаунта или возвращает nil при их отсутствии.
    /// - Parameter key: Ключ хранилища, объединяющий адрес сервера и идентификатор аккаунта.
    func read(_ key: CredentialKey) async throws -> Data?
    /// Сохраняет защищённые данные по ключу аккаунта.
    /// - Parameters:
    ///   - value: Данные сессии для защищённого хранения.
    ///   - key: Ключ хранилища, объединяющий адрес сервера и идентификатор аккаунта.
    func write(_ value: Data, for key: CredentialKey) async throws
    /// Удаляет защищённые данные выбранного аккаунта.
    /// - Parameter key: Ключ хранилища, объединяющий адрес сервера и идентификатор аккаунта.
    func delete(_ key: CredentialKey) async throws
}
