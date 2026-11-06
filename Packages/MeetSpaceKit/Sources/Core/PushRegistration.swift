import Foundation

/// This describes the generic backend gateway. `http` does not establish APNs or VoIP support.
public struct IntegrationCapabilities: Codable, Equatable, Sendable {
    public let email: String
    public let push: String
    public let calendar: String
    public let calendarOAuthConfigured: Bool
    public let mockConnectAllowed: Bool
    public init(email: String = "noop", push: String, calendar: String = "noop",
                calendarOAuthConfigured: Bool = false, mockConnectAllowed: Bool = false) {
        self.email = email; self.push = push; self.calendar = calendar
        self.calendarOAuthConfigured = calendarOAuthConfigured; self.mockConnectAllowed = mockConnectAllowed
    }
}

public struct NotificationPreferences: Codable, Equatable, Sendable {
    public var invitation: Bool
    public var reminder: Bool
    public var recording: Bool
    public var email: Bool
    public var push: Bool
    public init(invitation: Bool = true, reminder: Bool = true, recording: Bool = true, email: Bool = false, push: Bool = false) {
        self.invitation = invitation; self.reminder = reminder; self.recording = recording; self.email = email; self.push = push
    }
}

/// Public device metadata. The server never returns a delivery token or its fingerprint.
public struct NotificationDevice: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let platform: String
    public let provider: String
    public let createdAt: Date
    public let updatedAt: Date
    public let revokedAt: Date?
    public let disabledAt: Date?
    public var isActive: Bool { revokedAt == nil && disabledAt == nil }
    public init(id: UUID, platform: String, provider: String, createdAt: Date, updatedAt: Date,
                revokedAt: Date? = nil, disabledAt: Date? = nil) {
        self.id = id; self.platform = platform; self.provider = provider
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.revokedAt = revokedAt; self.disabledAt = disabledAt
    }
}

/// Persist this binding for cleanup before account/server changes. It contains no delivery token.
/// The backend does not enforce global token uniqueness across accounts.
public struct PushDeviceBinding: Codable, Equatable, Sendable {
    public let origin: ServerOrigin
    public let userID: UUID
    public let deviceID: UUID
    public init(origin: ServerOrigin, userID: UUID, deviceID: UUID) {
        self.origin = origin; self.userID = userID; self.deviceID = deviceID
    }
}
