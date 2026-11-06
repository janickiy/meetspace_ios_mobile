import Foundation
import Testing
import MeetSpaceCore
import MeetSpaceAPI
@testable import MeetSpaceFeatures

@Test func settingsProfileContractNormalizesOnlyNameAndChecksAccount() async throws {
    let account = try Fixture.account()
    let transport = RoutedTransport { request, _ in
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.path == "/api/v1/auth/me")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
        let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as! [String: String]
        #expect(body == ["displayName": "Новое имя"])
        var user = Fixture.user(); user["displayName"] = "Новое имя"
        return try Fixture.response(["status": "success", "user": user])
    }
    let repository = SettingsRepository(client: AuthenticatedClient(account: account, credentials: Fixture.credentials(), secureStore: TestSecrets(), transport: transport))
    #expect(try await repository.updateProfile(displayName: "  Новое имя \n").displayName == "Новое имя")
    for name in ["", " \n ", String(repeating: "а", count: 101), "a\u{0001}b"] {
        await #expect(throws: ClientError.invalidInput) { try await repository.updateProfile(displayName: name) }
    }
    #expect(await transport.requests.count == 1)
    let other = RoutedTransport { _, _ in try Fixture.response(["user": Fixture.user(UUID())]) }
    let scoped = SettingsRepository(client: AuthenticatedClient(account: account, credentials: Fixture.credentials(), secureStore: TestSecrets(), transport: other))
    await #expect(throws: ClientError.accountMismatch) { try await scoped.updateProfile(displayName: "Имя") }
    // The 100 limit is Unicode scalars (Go runes), not grapheme clusters or UTF-8 bytes.
    #expect(try ProfileValidation.displayName(String(repeating: "я", count: 100)).count == 100)
    #expect(throws: ClientError.invalidInput) { try ProfileValidation.displayName(String(repeating: "е\u{0301}", count: 51)) }
}

@Test func settingsCapabilitiesOnlyUseAdvertisedModesAndSSHStaysDisabled() async throws {
    let valid = try Fixture.data(["status": "success", "buildVersion": "20261106", "capabilities": ["recordingModes": ["composite", "individual_tracks"], "futureFeature": true]])
    let capabilities = try WireJSON.decoder().decode(ServerCapabilities.self, from: valid)
    #expect(capabilities.recordingModes == ["composite", "individual_tracks"])
    #expect(capabilities.buildVersion == "20261106")
    #expect(!IOSFeatureAvailability.sshInstallationEnabled)
    let noModes = try Fixture.data(["buildVersion": "dev", "capabilities": [:]])
    #expect(try WireJSON.decoder().decode(ServerCapabilities.self, from: noModes).recordingModes.isEmpty)
    let malformedValues: [Any] = [NSNull(), "composite", ["composite", "composite"], [String(repeating: "x", count: 65)], Array(repeating: "x", count: 33)]
    for malformed in malformedValues {
        let data = try Fixture.data(["buildVersion": "dev", "capabilities": ["recordingModes": malformed]])
        #expect(throws: DecodingError.self) { try WireJSON.decoder().decode(ServerCapabilities.self, from: data) }
    }
    let transport = RoutedTransport { request, _ in
        #expect(request.url?.path == "/api/v1/capabilities")
        return NetworkResponse(status: 200, headers: ["content-type": "application/json"], data: valid)
    }
    let repository = SettingsRepository(client: AuthenticatedClient(account: try Fixture.account(), credentials: Fixture.credentials(), secureStore: TestSecrets(), transport: transport))
    #expect(try await repository.capabilities() == capabilities)
}

private actor SettingsGate {
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
private actor SettingsFixture: SettingsServing {
    nonisolated let account: AccountRecord
    private var current: AccountUser
    private var stored = NotificationPreferences(invitation: true, reminder: false, recording: true, email: false, push: true)
    private let updateGate: SettingsGate?
    private let failCapabilities: Bool
    init(account: AccountRecord, updateGate: SettingsGate? = nil, failCapabilities: Bool = false) {
        self.account = account; current = account.user; self.updateGate = updateGate; self.failCapabilities = failCapabilities
    }
    func profile() -> AccountUser { current }
    func updateProfile(displayName: String) async throws -> AccountUser {
        await updateGate?.wait()
        var user = Fixture.user(account.user.id); user["displayName"] = try ProfileValidation.displayName(displayName)
        current = try WireJSON.decoder().decode(AccountUser.self, from: Fixture.data(user)); return current
    }
    func preferences() -> NotificationPreferences { stored }
    func savePreferences(_ value: NotificationPreferences) -> NotificationPreferences { stored = value; return value }
    func devices() -> [NotificationDevice] { [] }
    func capabilities() throws -> ServerCapabilities {
        if failCapabilities { throw APIError.httpStatus(503) }
        return ServerCapabilities(recordingModes: ["composite"], buildVersion: "test")
    }
    func integrations() -> IntegrationCapabilities { IntegrationCapabilities(push: "noop") }
}

@Test @MainActor func settingsSavePersistsAllFiveNotificationFieldsAndSurvivesFreshModel() async throws {
    let repository = SettingsFixture(account: try Fixture.account(), failCapabilities: true)
    var savedName: String?
    let model = SettingsModel(repository: repository, onProfileSaved: { savedName = $0.displayName })
    await model.load()
    #expect(model.loaded && model.capabilities == nil && model.capabilitiesError != nil)
    #expect(model.profileError == nil && model.savedPreferences != nil)
    model.displayName = "Изменённое имя"; await model.saveProfile()
    #expect(savedName == "Изменённое имя")
    let chosen = NotificationPreferences(invitation: false, reminder: true, recording: false, email: true, push: false)
    model.preferences = chosen; #expect(model.canSavePreferences)
    await model.saveNotifications(); #expect(!model.canSavePreferences)
    model.close()
    let restored = SettingsModel(repository: repository); await restored.load()
    #expect(restored.preferences == chosen)
    #expect(restored.profile.displayName == "Изменённое имя")
    restored.close()
}

@Test @MainActor func settingsCloseRejectsLateProfileSaveAndLocalIndexCallback() async throws {
    let gate = SettingsGate(), account = try Fixture.account()
    let repository = SettingsFixture(account: account, updateGate: gate)
    var callbacks = 0
    let model = SettingsModel(repository: repository, onProfileSaved: { _ in callbacks += 1 })
    model.displayName = "Поздний ответ"
    let save = Task { await model.saveProfile() }
    for _ in 0..<200 {
        if await gate.started { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await gate.started)
    model.close(); await gate.release(); await save.value
    #expect(callbacks == 0 && model.profile == account.user && !model.busy)
    #expect(!model.canSaveProfile && !model.canSavePreferences)
}
