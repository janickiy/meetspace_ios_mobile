import Foundation
import MeetSpaceCore

public protocol SettingsServing: Sendable {
    var account: AccountRecord { get }
    func profile() async throws -> AccountUser
    func updateProfile(displayName: String) async throws -> AccountUser
    func updateProfile(displayName: String?, bio: String?) async throws -> AccountUser
    func preferences() async throws -> NotificationPreferences
    func savePreferences(_ value: NotificationPreferences) async throws -> NotificationPreferences
    func devices() async throws -> [NotificationDevice]
    func capabilities() async throws -> ServerCapabilities
    func integrations() async throws -> IntegrationCapabilities
}

public extension SettingsServing {
    func updateProfile(displayName: String?, bio: String?) async throws -> AccountUser {
        guard let displayName, bio == nil else { throw ClientError.invalidInput }
        return try await updateProfile(displayName: displayName)
    }
}

public protocol ProfilePhotoServing: Sendable {
    func photo() async throws -> Data
    func savePhoto(_ data: Data?) async throws -> AccountUser
}

public struct SettingsRepository: SettingsServing, ProfilePhotoServing {
    public let account: AccountRecord
    private let client: AuthenticatedClient
    private let notifications: NotificationDeviceRepository
    public init(client: AuthenticatedClient) {
        self.client = client; account = client.account; notifications = NotificationDeviceRepository(client: client)
    }
    public func profile() async throws -> AccountUser {
        try accountOnly(); return try await client.currentUser()
    }
    public func updateProfile(displayName: String) async throws -> AccountUser {
        try await updateProfile(displayName: displayName, bio: nil)
    }
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
    public func photo() async throws -> Data {
        try accountOnly()
        let response = try await client.request("GET", path: ["users", account.user.id.uuidString.lowercased(), "avatar", "content"],
                                                limit: 256 * 1024)
        guard response.headers["content-type"]?.lowercased().hasPrefix("image/jpeg") == true,
              response.data.starts(with: [0xff, 0xd8]) else { throw APIError.invalidResponse }
        return response.data
    }

    public func savePhoto(_ data: Data?) async throws -> AccountUser {
        try accountOnly()
        if let data, !data.starts(with: [0xff, 0xd8]) || data.count > 2 * 1024 * 1024 { throw ClientError.invalidInput }
        let response = try await client.request(data == nil ? "DELETE" : "PUT", path: ["auth", "me", "avatar"], body: data, contentType: "image/jpeg")
        let user = try decodeJSON(UserResponse.self, from: response).user
        guard user.id == account.user.id, user.guestConferenceId == nil else { throw ClientError.accountMismatch }
        guard (user.avatarVersion != nil) == (data != nil) else { throw APIError.invalidResponse }
        return user
    }
    public func preferences() async throws -> NotificationPreferences { try await notifications.preferences() }
    public func savePreferences(_ value: NotificationPreferences) async throws -> NotificationPreferences {
        try await notifications.savePreferences(value)
    }
    public func devices() async throws -> [NotificationDevice] { try await notifications.devices() }
    public func capabilities() async throws -> ServerCapabilities {
        try accountOnly()
        return try decodeJSON(ServerCapabilities.self, from: await client.request("GET", path: ["capabilities"]))
    }
    public func integrations() async throws -> IntegrationCapabilities { try await notifications.capabilities() }
    private func accountOnly() throws {
        guard account.user.guestConferenceId == nil else { throw ClientError.scopeMismatch }
    }
}
