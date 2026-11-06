import Foundation
import MeetSpaceCore

public protocol SettingsServing: Sendable {
    var account: AccountRecord { get }
    func profile() async throws -> AccountUser
    func updateProfile(displayName: String) async throws -> AccountUser
    func preferences() async throws -> NotificationPreferences
    func savePreferences(_ value: NotificationPreferences) async throws -> NotificationPreferences
    func devices() async throws -> [NotificationDevice]
    func capabilities() async throws -> ServerCapabilities
    func integrations() async throws -> IntegrationCapabilities
}

public struct SettingsRepository: SettingsServing {
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
        try accountOnly()
        struct Body: Encodable { let displayName: String }
        let name = try ProfileValidation.displayName(displayName)
        let response = try await client.request("PATCH", path: ["auth", "me"], body: WireJSON.encoder().encode(Body(displayName: name)))
        let user = try decodeJSON(UserResponse.self, from: response).user
        guard user.id == account.user.id, user.guestConferenceId == nil else { throw ClientError.accountMismatch }
        guard user.displayName == name, user.email == account.user.email else { throw APIError.invalidResponse }
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
