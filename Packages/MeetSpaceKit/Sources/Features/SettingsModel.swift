import Foundation
import Observation
import MeetSpaceCore
import MeetSpaceAPI

/// One account scope. A late server response cannot resurrect a closed settings screen/account.
@MainActor @Observable public final class SettingsModel {
    public let account: AccountRecord
    public private(set) var profile: AccountUser
    public var displayName: String
    public var preferences = NotificationPreferences()
    public private(set) var savedPreferences: NotificationPreferences?
    public private(set) var devices: [NotificationDevice] = []
    public private(set) var capabilities: ServerCapabilities?
    public private(set) var integrations: IntegrationCapabilities?
    public private(set) var busy = false
    public private(set) var loaded = false
    public private(set) var profileError: String?
    public private(set) var preferencesError: String?
    public private(set) var devicesError: String?
    public private(set) var capabilitiesError: String?
    public private(set) var information: String?
    @ObservationIgnored private let repository: any SettingsServing
    @ObservationIgnored private let onProfileSaved: @MainActor @Sendable (AccountUser) async throws -> Void
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var closed = false

    public init(repository: any SettingsServing,
                onProfileSaved: @escaping @MainActor @Sendable (AccountUser) async throws -> Void = { _ in }) {
        self.repository = repository; self.account = repository.account; profile = repository.account.user
        displayName = repository.account.user.displayName ?? ""; self.onProfileSaved = onProfileSaved
    }
    public var canSaveProfile: Bool {
        !busy && !closed && (try? ProfileValidation.displayName(displayName)).map { $0 != profile.displayName } == true
    }
    public var canSavePreferences: Bool { !busy && !closed && savedPreferences != nil && preferences != savedPreferences }

    public func load() async {
        guard !closed, !busy else { return }
        busy = true; information = nil; let current = epoch
        defer { if current == epoch { busy = false } }
        do {
            let value = try await repository.profile()
            guard current == epoch else { return }
            profile = value; displayName = value.displayName ?? ""; profileError = nil
        } catch { guard current == epoch else { return }; profileError = userMessage(error) }
        do {
            let value = try await repository.preferences()
            guard current == epoch else { return }
            preferences = value; savedPreferences = value; preferencesError = nil
        } catch { guard current == epoch else { return }; savedPreferences = nil; preferencesError = userMessage(error) }
        do {
            let value = try await repository.devices()
            guard current == epoch else { return }
            devices = value.sorted { $0.updatedAt > $1.updatedAt }; devicesError = nil
        } catch { guard current == epoch else { return }; devices = []; devicesError = userMessage(error) }
        do {
            async let platform = repository.capabilities()
            async let integrations = repository.integrations()
            let values = try await (platform, integrations)
            guard current == epoch else { return }
            capabilities = values.0; self.integrations = values.1; capabilitiesError = nil
        } catch { guard current == epoch else { return }; capabilities = nil; integrations = nil; capabilitiesError = userMessage(error) }
        loaded = true
    }
    public func saveProfile() async {
        guard canSaveProfile else { return }
        busy = true; information = nil; profileError = nil; let current = epoch
        defer { if current == epoch { busy = false } }
        do {
            let value = try await repository.updateProfile(displayName: displayName)
            guard current == epoch else { return }
            profile = value; displayName = value.displayName ?? ""
            try await onProfileSaved(value)
            guard current == epoch else { return }
            information = "Профиль сохранён"
        } catch { guard current == epoch else { return }; profileError = userMessage(error) }
    }
    public func saveNotifications() async {
        guard canSavePreferences else { return }
        busy = true; information = nil; preferencesError = nil; let current = epoch
        defer { if current == epoch { busy = false } }
        do {
            let value = try await repository.savePreferences(preferences)
            guard current == epoch else { return }
            preferences = value; savedPreferences = value; information = "Настройки уведомлений сохранены"
        } catch { guard current == epoch else { return }; preferencesError = userMessage(error) }
    }
    public func close() {
        closed = true; epoch = UUID(); busy = false; loaded = false; devices = []
        capabilities = nil; integrations = nil; savedPreferences = nil
    }
}
