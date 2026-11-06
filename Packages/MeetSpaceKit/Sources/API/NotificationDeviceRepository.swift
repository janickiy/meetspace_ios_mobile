import Foundation
import MeetSpaceCore

public protocol NotificationDevicesServing: Sendable {
    var origin: ServerOrigin { get }
    var userID: UUID { get }
    func capabilities() async throws -> IntegrationCapabilities
    func devices() async throws -> [NotificationDevice]
    func register(token: String) async throws -> NotificationDevice
    func revoke(_ deviceID: UUID) async throws
    func preferences() async throws -> NotificationPreferences
    func savePreferences(_ preferences: NotificationPreferences) async throws -> NotificationPreferences
}

/// Uses only the existing ordinary-notification API. Never send PushKit VoIP tokens here.
public struct NotificationDeviceRepository: NotificationDevicesServing {
    public let origin: ServerOrigin
    public let userID: UUID
    private let client: AuthenticatedClient
    public init(client: AuthenticatedClient) {
        self.client = client; origin = client.account.server; userID = client.account.user.id
    }
    public func capabilities() async throws -> IntegrationCapabilities {
        try accountOnly()
        return try decodeJSON(IntegrationCapabilities.self, from: await client.request("GET", path: ["integrations", "capabilities"]))
    }
    public func devices() async throws -> [NotificationDevice] {
        try accountOnly()
        let items = try decodeJSON(ItemsResponse<NotificationDevice>.self, from: await client.request("GET", path: ["notifications", "devices"])).items
        guard items.count <= 100, Set(items.map(\.id)).count == items.count,
              items.allSatisfy({ DirectCall.validID($0.id) && ["ios", "android", "web"].contains($0.platform) })
        else { throw APIError.invalidResponse }
        return items
    }
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
    public func revoke(_ deviceID: UUID) async throws {
        try accountOnly()
        guard DirectCall.validID(deviceID) else { throw ClientError.invalidInput }
        _ = try await client.request("DELETE", path: ["notifications", "devices", deviceID.uuidString.lowercased()])
    }
    public func preferences() async throws -> NotificationPreferences {
        try accountOnly()
        return try decodeJSON(NotificationPreferences.self, from: await client.request("GET", path: ["notifications", "preferences"]))
    }
    public func savePreferences(_ preferences: NotificationPreferences) async throws -> NotificationPreferences {
        try accountOnly()
        return try decodeJSON(NotificationPreferences.self, from: await client.request("PUT", path: ["notifications", "preferences"],
            body: WireJSON.encoder().encode(preferences)))
    }
    private func accountOnly() throws {
        guard client.account.user.guestConferenceId == nil else { throw ClientError.scopeMismatch }
    }
}
