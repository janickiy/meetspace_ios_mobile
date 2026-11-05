#if DEBUG
import Foundation
import MeetSpaceCore
import MeetSpaceAPI
import MeetSpaceFeatures

/// Only explicit DEBUG UI-test launches use doubles. No network or persistent test credentials.
enum UITestDependencies {
    static func make() -> AppDependencies {
        AppDependencies(serverProbe: Probe(), configuration: Preferences(), credentials: Secrets())
    }
    private struct Probe: ServerProbing {
        func check(_ origin: ServerOrigin) async throws -> ServerVersion {
            guard origin.displayName == "fixture.example" else { throw APIError.offline }
            return ServerVersion(version: "test", commit: "fixture", buildTime: "fixture")
        }
    }
    private actor Preferences: ConfigurationStore {
        private var value = AppConfiguration()
        func load() -> AppConfiguration { value }
        func save(_ configuration: AppConfiguration) { value = configuration }
    }
    private actor Secrets: SecureStore {
        private var values: [CredentialKey: Data] = [:]
        func read(_ key: CredentialKey) -> Data? { values[key] }
        func write(_ value: Data, for key: CredentialKey) { values[key] = value }
        func delete(_ key: CredentialKey) { values[key] = nil }
    }
}
#endif
