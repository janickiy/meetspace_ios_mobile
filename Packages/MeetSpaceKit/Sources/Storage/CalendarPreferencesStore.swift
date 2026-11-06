import Foundation
import MeetSpaceCore

public actor UserDefaultsCalendarPreferencesStore: CalendarPreferencesStore {
    private let defaults: UserDefaults
    private let key: String
    public init(account: CredentialKey, suiteName: String? = nil) {
        defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        key = "meetspace.calendar.v1|" + account.storageKey
    }
    public func load() throws -> CalendarPreferences {
        guard let data = defaults.data(forKey: key) else { return CalendarPreferences() }
        return try WireJSON.decoder().decode(CalendarPreferences.self, from: data).validated()
    }
    public func save(_ preferences: CalendarPreferences) throws {
        defaults.set(try WireJSON.encoder().encode(preferences.validated()), forKey: key)
    }
}
