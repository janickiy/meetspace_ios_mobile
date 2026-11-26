import Foundation
import Observation
import MeetSpaceCore
import MeetSpaceAPI

/// One account scope. A late server response cannot resurrect a closed settings screen/account.
@MainActor @Observable public final class SettingsModel {
    public let account: AccountRecord
    public private(set) var profile: AccountUser
    public var displayName: String
    public var bio: String
    public private(set) var photo: Data?
    @ObservationIgnored private var photoVersion: String?
    @ObservationIgnored private var loadingPhoto: (version: String, task: Task<Data, Error>)?
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

    /// Готовит модель настроек и черновик профиля текущего аккаунта.
    /// - Parameters:
    ///   - repository: Сервис чтения и сохранения настроек.
    ///   - initialProfile: Профиль для первоначального отображения.
    ///   - onProfileSaved: Обработчик обновлённых данных профиля.
    public init(repository: any SettingsServing, initialProfile: AccountUser? = nil,
                onProfileSaved: @escaping @MainActor @Sendable (AccountUser) async throws -> Void = { _ in }) {
        self.repository = repository; self.account = repository.account
        // Identity may have just refreshed /auth/me while retaining this client's immutable
        // account scope and renewed credentials. Seed presentation from that checked profile.
        let current = initialProfile.flatMap { $0.id == repository.account.user.id ? $0 : nil } ?? repository.account.user
        profile = current; displayName = current.displayName ?? ""; bio = current.bio ?? ""; self.onProfileSaved = onProfileSaved
    }
    public var canSaveProfile: Bool {
        guard !busy, !closed, (try? ProfileValidation.bio(bio)) != nil else { return false }
        if displayName != (profile.displayName ?? "") {
            guard profile.authSource != "ldap", let name = try? ProfileValidation.displayName(displayName) else { return false }
            if name != profile.displayName { return true }
        }
        return profile.bio != nil && bio != profile.bio
    }
    public var canSavePreferences: Bool { !busy && !closed && savedPreferences != nil && preferences != savedPreferences }

    /// Загружает профиль, настройки уведомлений и сведения о возможностях сервера.
    public func load() async {
        guard !closed, !busy else { return }
        busy = true; information = nil; let current = epoch
        defer { if current == epoch { busy = false } }
        do {
            let value = try await repository.profile()
            guard current == epoch else { return }
            profile = value; displayName = value.displayName ?? ""; bio = value.bio ?? ""; profileError = nil
            await loadPhoto()
            guard current == epoch else { return }
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
    /// Сохраняет изменения профиля и передаёт обновлённого пользователя владельцу модели.
    public func saveProfile() async {
        guard canSaveProfile else { return }
        busy = true; information = nil; profileError = nil; let current = epoch
        defer { if current == epoch { busy = false } }
        do {
            let changedName = try? ProfileValidation.displayName(displayName)
            let value = try await repository.updateProfile(displayName: changedName == profile.displayName ? nil : changedName,
                                                           bio: bio == (profile.bio ?? "") ? nil : bio)
            guard current == epoch else { return }
            profile = value; displayName = value.displayName ?? ""; bio = value.bio ?? ""
            try await onProfileSaved(value)
            guard current == epoch else { return }
            information = "Профиль сохранён"
        } catch { guard current == epoch else { return }; profileError = userMessage(error) }
    }
    /// Загружает фотографию для актуальной версии аватара.
    public func loadPhoto() async {
        guard !closed, let repository = repository as? any ProfilePhotoServing else { return }
        guard let version = profile.avatarVersion else {
            loadingPhoto?.task.cancel(); loadingPhoto = nil; photo = nil; photoVersion = nil
            return
        }
        guard photoVersion != version else { return }
        let task: Task<Data, Error>
        if let loadingPhoto, loadingPhoto.version == version { task = loadingPhoto.task }
        else {
            loadingPhoto?.task.cancel(); photo = nil
            task = Task { try await repository.photo() }
            loadingPhoto = (version, task)
        }
        let image = try? await task.value
        guard !closed, !task.isCancelled, profile.avatarVersion == version, loadingPhoto?.version == version else { return }
        loadingPhoto = nil
        if let image { photo = image; photoVersion = version }
    }

    /// Сохраняет или удаляет фотографию профиля и обновляет её локальную версию.
    /// - Parameter data: Данные новой фотографии или `nil` для удаления.
    public func savePhoto(_ data: Data?) async -> Bool {
        guard !closed, !busy, let repository = repository as? any ProfilePhotoServing else { return false }
        busy = true; profileError = nil; information = nil; let current = epoch
        defer { if epoch == current { busy = false } }
        do {
            let updated = try await repository.savePhoto(data)
            guard current == epoch else { return false }
            loadingPhoto?.task.cancel(); loadingPhoto = nil
            profile = updated; photo = data; photoVersion = updated.avatarVersion
            try await onProfileSaved(updated)
            return current == epoch
        } catch {
            if current == epoch { profileError = userMessage(error) }
            return false
        }
    }

    /// Сохраняет выбранные параметры уведомлений текущего аккаунта.
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
    /// Отменяет загрузку фотографии и очищает состояние настроек при закрытии.
    public func close() {
        closed = true; epoch = UUID(); busy = false; loaded = false; devices = []
        loadingPhoto?.task.cancel(); loadingPhoto = nil; photo = nil; photoVersion = nil
        capabilities = nil; integrations = nil; savedPreferences = nil
    }
}
