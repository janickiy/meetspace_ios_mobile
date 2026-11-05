import Foundation
import Testing
import MeetSpaceCore
@testable import MeetSpaceStorage

@Test func preferencesRoundTripOnlyPublicConfiguration() async throws {
    let suite = "meetspace.tests.\(UUID().uuidString)"
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let store = PreferencesStore(suiteName: suite)
    #expect(try await store.load() == AppConfiguration())
    let config = AppConfiguration(server: try ServerOrigin("https://meet.example:8443"), appearance: .dark)
    try await store.save(config)
    #expect(try await PreferencesStore(suiteName: suite).load() == config)
    let data = try #require(UserDefaults(suiteName: suite)?.data(forKey: "meetspace.configuration.v1"))
    let dictionary = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(dictionary.keys) == ["server", "appearance"])
}

@Test func corruptedConfigurationIsReported() async throws {
    let suite = "meetspace.tests.\(UUID().uuidString)"
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    UserDefaults(suiteName: suite)?.set(Data("{\"server\":\"http://unsafe.example\",\"appearance\":\"dark\"}".utf8), forKey: "meetspace.configuration.v1")
    await #expect(throws: (any Error).self) { try await PreferencesStore(suiteName: suite).load() }
}
