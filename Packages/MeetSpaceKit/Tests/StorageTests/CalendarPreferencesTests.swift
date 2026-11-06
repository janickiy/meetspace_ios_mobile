import Foundation
import Testing
import MeetSpaceCore
import MeetSpaceStorage

@Test func calendarPreferencesPersistAndRemainScopedToServerAndAccount() async throws {
    let suite = "meetspace.calendar.tests.\(UUID())"
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let user = UUID(), origin = try ServerOrigin("https://one.example")
    let key = CredentialKey(server: origin, accountID: user)
    let store = UserDefaultsCalendarPreferencesStore(account: key, suiteName: suite)
    let value = CalendarPreferences(timeZoneIdentifier: "Asia/Kathmandu", displayMode: .month)
    try await store.save(value)
    #expect(try await UserDefaultsCalendarPreferencesStore(account: key, suiteName: suite).load() == value)
    let otherUser = UserDefaultsCalendarPreferencesStore(account: CredentialKey(server: origin, accountID: UUID()), suiteName: suite)
    let otherServer = UserDefaultsCalendarPreferencesStore(account: CredentialKey(server: try ServerOrigin("https://two.example"), accountID: user), suiteName: suite)
    #expect(try await otherUser.load().displayMode == .week)
    #expect(try await otherServer.load().displayMode == .week)
    await #expect(throws: ClientError.invalidInput) { try await store.save(CalendarPreferences(timeZoneIdentifier: "invalid-zone")) }
}
