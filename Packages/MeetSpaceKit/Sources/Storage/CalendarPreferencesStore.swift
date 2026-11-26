import Foundation
import MeetSpaceCore

public actor UserDefaultsCalendarPreferencesStore: CalendarPreferencesStore {
    private let defaults: UserDefaults
    private let key: String
    /// Выбирает хранилище настроек календаря для указанного аккаунта.
    /// - Parameters:
    ///   - account: Учётная запись, которой принадлежат данные.
    ///   - suiteName: Имя набора UserDefaults или nil для стандартных настроек приложения.
    public init(account: CredentialKey, suiteName: String? = nil) {
        defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        key = "meetspace.calendar.v1|" + account.storageKey
    }
    /// Загружает проверенные параметры календаря или исходные значения для новой записи.
    public func load() throws -> CalendarPreferences {
        guard let data = defaults.data(forKey: key) else { return CalendarPreferences() }
        return try WireJSON.decoder().decode(CalendarPreferences.self, from: data).validated()
    }
    /// Сохраняет часовой пояс и режим календаря для текущего аккаунта.
    /// - Parameter preferences: Сохраняемые настройки часового пояса и режима календаря.
    public func save(_ preferences: CalendarPreferences) throws {
        defaults.set(try WireJSON.encoder().encode(preferences.validated()), forKey: key)
    }
}
