import Foundation

public enum LoadState: Equatable, Sendable {
    case loading, empty, content, offline, failed
}

public enum AppTab: String, CaseIterable, Sendable { case meetings, messages, profile }

public enum AppRoute: Hashable, Sendable {
    case calendar, recordings, folders, prejoin, call, personalCall
    case meetingDetails(Int), recording(Int), thread(Int)
    case newMeeting, scheduleMeeting, joinMeeting
    case audioSettings, videoSettings, notificationSettings, appearance, connection, accounts
    case interfaceCatalog
    case deploy, fingerprint, preflight, install, complete, installError
}

public enum Appearance: String, Codable, CaseIterable, Sendable { case system, light, dark }

public struct AppConfiguration: Codable, Equatable, Sendable {
    public var server: ServerOrigin?
    public var appearance: Appearance
    public init(server: ServerOrigin? = nil, appearance: Appearance = .system) {
        self.server = server
        self.appearance = appearance
    }
}

public protocol ConfigurationStore: Sendable {
    func load() async throws -> AppConfiguration
    func save(_ configuration: AppConfiguration) async throws
}

/// Secrets are scoped to a server AND account, even before multi-account UI is implemented.
public struct CredentialKey: Hashable, Sendable {
    public let server: ServerOrigin
    public let accountID: UUID
    public init(server: ServerOrigin, accountID: UUID) {
        self.server = server
        self.accountID = accountID
    }
    public var storageKey: String { server.url.absoluteString + "|" + accountID.uuidString }
}

public protocol SecureStore: Sendable {
    func read(_ key: CredentialKey) async throws -> Data?
    func write(_ value: Data, for key: CredentialKey) async throws
    func delete(_ key: CredentialKey) async throws
}
