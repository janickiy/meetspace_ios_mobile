import Foundation
import Testing
import MeetSpaceCore
import MeetSpaceAPI
@testable import MeetSpaceFeatures

private actor MemoryConfiguration: ConfigurationStore {
    var value = AppConfiguration()
    func load() -> AppConfiguration { value }
    func save(_ value: AppConfiguration) { self.value = value }
}
private actor MemorySecrets: SecureStore {
    var values: [CredentialKey: Data] = [:]
    func read(_ key: CredentialKey) -> Data? { values[key] }
    func write(_ value: Data, for key: CredentialKey) { values[key] = value }
    func delete(_ key: CredentialKey) { values[key] = nil }
}
private actor ControlledProbe: ServerProbing {
    var continuations: [String: CheckedContinuation<ServerVersion, any Error>] = [:]
    func check(_ origin: ServerOrigin) async throws -> ServerVersion {
        try await withCheckedThrowingContinuation { continuations[origin.displayName] = $0 }
    }
    func pending(_ host: String) -> Bool { continuations[host] != nil }
    func finish(_ host: String, result: Result<ServerVersion, any Error>) {
        continuations.removeValue(forKey: host)?.resume(with: result)
    }
}
private let version = ServerVersion(version: "1", commit: "abc", buildTime: "unknown")

@MainActor private func fixture() -> (AppModel, ControlledProbe, MemoryConfiguration) {
    let probe = ControlledProbe(); let store = MemoryConfiguration()
    return (AppModel(dependencies: AppDependencies(serverProbe: probe, configuration: store, credentials: MemorySecrets())), probe, store)
}

private func until(_ condition: @escaping @Sendable () async -> Bool) async throws {
    for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw Timeout()
}
private struct Timeout: Error {}

@Test @MainActor func staleResponseCannotReplaceNewServer() async throws {
    let (model, probe, _) = fixture()
    model.checkServer("https://old.example")
    try await until { await probe.pending("old.example") }
    model.checkServer("https://new.example")
    try await until { await probe.pending("new.example") }
    await probe.finish("new.example", result: .success(version))
    try await until { await model.checkedServer?.displayName == "new.example" }
    await probe.finish("old.example", result: .success(version))
    await Task.yield()
    #expect(model.checkedServer?.displayName == "new.example")
    #expect(model.probeState == .content)
}

@Test @MainActor func invalidAddressNeverStartsRequestOrAdvances() async {
    let (model, _, _) = fixture()
    model.checkServer("http://meet.example")
    await model.continueToLogin()
    #expect(model.connectionError == .invalidURL)
    #expect(model.probeState == .failed)
    #expect(model.onboarding == .welcome)
    #expect(model.checkedServer == nil)
}

@Test @MainActor func leavingConnectionCancelsPendingCheck() async throws {
    let (model, probe, _) = fixture()
    model.show(.connect)
    model.checkServer("https://meet.example")
    try await until { await probe.pending("meet.example") }
    model.show(.welcome)
    await probe.finish("meet.example", result: .success(version))
    await Task.yield()
    #expect(model.checkedServer == nil)
    #expect(model.probeState == .empty)
}

@Test @MainActor func successfulCheckPersistsOriginBeforeLogin() async throws {
    let (model, probe, store) = fixture()
    model.checkServer("https://meet.example")
    try await until { await probe.pending("meet.example") }
    await probe.finish("meet.example", result: .success(version))
    try await until { await model.probeState == .content }
    await model.continueToLogin()
    #expect(model.onboarding == .login)
    #expect(await store.value.server?.displayName == "meet.example")
}

@Test @MainActor func offlineIsDistinctAndRetryCanSucceed() async throws {
    let (model, probe, _) = fixture()
    model.checkServer("https://meet.example")
    try await until { await probe.pending("meet.example") }
    await probe.finish("meet.example", result: .failure(APIError.offline))
    try await until { await model.probeState == .offline }
    #expect(model.connectionError == .offline)
    model.checkServer("https://meet.example")
    try await until { await probe.pending("meet.example") }
    await probe.finish("meet.example", result: .success(version))
    try await until { await model.probeState == .content }
    #expect(model.connectionError == nil)
}

@Test @MainActor func tabsPreserveIndependentPathsAndDemoExitClearsThem() {
    let (model, _, _) = fixture()
    #expect(!model.isDemo)
    model.enterDemo(); model.navigate(.recordings)
    model.tab = .messages; model.navigate(.thread(1))
    model.tab = .profile; model.navigate(.appearance)
    #expect(model.meetingsPath == [.recordings])
    #expect(model.messagesPath == [.thread(1)])
    #expect(model.profilePath == [.appearance])
    model.leaveDemo()
    #expect(!model.isDemo && model.onboarding == .welcome)
    #expect(model.meetingsPath.isEmpty && model.messagesPath.isEmpty && model.profilePath.isEmpty)
}

@Test @MainActor func reopeningServerFormRequiresANewCheck() async throws {
    let (model, probe, _) = fixture()
    model.show(.connect); model.checkServer("https://meet.example")
    try await until { await probe.pending("meet.example") }
    await probe.finish("meet.example", result: .success(version))
    try await until { await model.probeState == .content }
    model.show(.welcome); model.show(.connect)
    await model.continueToLogin()
    #expect(model.onboarding == .connect)
    #expect(model.checkedServer == nil && model.probeState == .empty)
}

private actor DelayedConfiguration: ConfigurationStore {
    private var continuation: CheckedContinuation<Void, Never>?
    var pending: Bool { continuation != nil }
    func load() -> AppConfiguration { AppConfiguration() }
    func save(_ configuration: AppConfiguration) async {
        await withCheckedContinuation { continuation = $0 }
    }
    func finish() { continuation?.resume(); continuation = nil }
}

@Test @MainActor func leavingWhileSavingCannotNavigateBackToLogin() async throws {
    let probe = ControlledProbe(); let store = DelayedConfiguration()
    let model = AppModel(dependencies: AppDependencies(serverProbe: probe, configuration: store, credentials: MemorySecrets()))
    model.show(.connect); model.checkServer("https://meet.example")
    try await until { await probe.pending("meet.example") }
    await probe.finish("meet.example", result: .success(version))
    try await until { await model.probeState == .content }
    let saving = Task { await model.continueToLogin() }
    try await until { await store.pending }
    model.show(.welcome)
    await store.finish(); await saving.value
    #expect(model.onboarding == .welcome)
}
