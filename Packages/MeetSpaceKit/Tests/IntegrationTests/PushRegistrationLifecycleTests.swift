import Foundation
import Testing
import CryptoKit
import MeetSpaceCore
import MeetSpaceAPI
import MeetSpaceStorage
import MeetSpaceCalling
@testable import MeetSpaceFeatures

@MainActor private final class PushPlatformFixture: NormalPushNotifications {
    let events: AsyncStream<NormalPushNotificationEvent>
    private let continuation: AsyncStream<NormalPushNotificationEvent>.Continuation
    var authorization: NormalPushAuthorization = .authorized
    var authorizationRequests = 0
    var registrations = 0
    var unregistrations = 0
    init() { (events, continuation) = AsyncStream.makeStream() }
    func requestAuthorization() async throws -> NormalPushAuthorization { authorizationRequests += 1; return authorization }
    func refreshAuthorization() async { }
    func register() { registrations += 1 }
    func unregister() { unregistrations += 1 }
    func didRegister(deviceToken: Data) { continuation.yield(.token(deviceToken)) }
    func didFailRegistration() { continuation.yield(.failure(.registrationFailed)) }
}

private actor PushServiceFixture: NotificationDevicesServing {
    nonisolated let origin: ServerOrigin
    nonisolated let userID: UUID
    let store: any PushRegistrationStore
    var capability = "http"
    var savedPreferences = NotificationPreferences(invitation: false, reminder: true, recording: false)
    var calls: [String] = []
    var registerCount = 0
    var revoked: [UUID] = []
    var failRegistration = false
    var failRevocation = false
    var holdRegistration = false
    var gate: CheckedContinuation<Void, Never>?
    init(store: any PushRegistrationStore, origin: ServerOrigin = Fixture.origin, userID: UUID = Fixture.userID) {
        self.store = store; self.origin = origin; self.userID = userID
    }
    func capabilities() -> IntegrationCapabilities { IntegrationCapabilities(push: capability) }
    func devices() -> [NotificationDevice] { Issue.record("Manager must not enumerate account devices for cleanup"); return [] }
    func preferences() -> NotificationPreferences { savedPreferences }
    func savePreferences(_ preferences: NotificationPreferences) -> NotificationPreferences { savedPreferences = preferences; return preferences }
    func register(token: String) async throws -> NotificationDevice {
        let value = try await store.load()
        let entry = value.entries.first { $0.origin == origin && $0.userID == userID }
        let fingerprint = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(entry?.pendingTokenFingerprint == fingerprint)
        registerCount += 1; calls.append("register")
        if holdRegistration { await withCheckedContinuation { gate = $0 } }
        if failRegistration { throw APIError.offline }
        let id = UUID(uuidString: registerCount == 1 ? "AB111111-1111-4111-8111-111111111111" : "BC222222-2222-4222-8222-222222222222")!
        return NotificationDevice(id: id, platform: "ios", provider: "http", createdAt: Date(), updatedAt: Date())
    }
    func revoke(_ deviceID: UUID) throws {
        calls.append("revoke")
        if failRevocation { throw APIError.offline }
        revoked.append(deviceID)
    }
    func setCapability(_ value: String) { capability = value }
    func hold() { holdRegistration = true }
    func release() { holdRegistration = false; gate?.resume(); gate = nil }
    func fail(register: Bool = false, revoke: Bool = false) { failRegistration = register; failRevocation = revoke }
}

@MainActor private func waitForPush(_ predicate: @escaping @MainActor () async -> Bool) async throws {
    for _ in 0..<300 {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for push lifecycle transition")
}

@Test @MainActor func pushRegistrationRequiresExplicitConsentAndPersistsBeforeSendingToken() async throws {
    let store = MemoryPushRegistrationStore(), platform = PushPlatformFixture()
    let service = PushServiceFixture(store: store)
    let model = PushRegistrationModel(platform: platform, store: store)
    #expect(await model.attach(repository: service))
    #expect(platform.authorizationRequests == 0 && platform.registrations == 0)
    await model.enable()
    #expect(platform.authorizationRequests == 1 && platform.registrations == 1)
    let preferences = await service.savedPreferences
    #expect(preferences.push && !preferences.invitation && !preferences.recording)
    platform.didRegister(deviceToken: Data(repeating: 0xAB, count: 32))
    try await waitForPush { await service.registerCount == 1 && !model.busy }
    let journal = try await store.load()
    #expect(journal.entries.first?.deviceIDs.count == 1)
    #expect(journal.entries.first?.pendingTokenFingerprint == nil)
    #expect(!String(decoding: try WireJSON.encoder().encode(journal), as: UTF8.self).contains(String(repeating: "ab", count: 32)))
    await model.disable()
    #expect(!model.enabled && !model.busy)
    #expect(await service.revoked.count == 1)
    #expect(try await store.load().entries.first?.hasBinding == false)
    #expect(await service.savedPreferences.push) // Other account devices retain their preference.
}

@Test @MainActor func pushDetachDrainsLateRegistrationAndRevokesItsReceipt() async throws {
    let store = MemoryPushRegistrationStore(), platform = PushPlatformFixture()
    let service = PushServiceFixture(store: store)
    await service.hold()
    let model = PushRegistrationModel(platform: platform, store: store)
    _ = await model.attach(repository: service); await model.enable()
    platform.didRegister(deviceToken: Data(repeating: 0xAC, count: 32))
    try await waitForPush { await service.registerCount == 1 }
    let previousUnregister = platform.unregistrations
    model.suspendDelivery()
    #expect(platform.unregistrations == previousUnregister + 1 && !model.enabled)
    // A late OS callback is ignored while the existing POST still must be drained and revoked.
    platform.didRegister(deviceToken: Data(repeating: 0xAD, count: 32))
    let detached = Task { await model.detach() }
    try await waitForPush { platform.unregistrations > previousUnregister && !model.enabled }
    #expect(model.busy)
    await service.release()
    #expect(await detached.value)
    #expect(await service.revoked.count == 1)
    #expect(try await store.load().entries.allSatisfy { !$0.hasBinding })
    platform.didRegister(deviceToken: Data(repeating: 0xAD, count: 32))
    try await Task.sleep(for: .milliseconds(20))
    #expect(await service.registerCount == 1)
}

@Test @MainActor func pushTokenRotationRevokesOldReceiptBeforeNewRegistration() async throws {
    let store = MemoryPushRegistrationStore(), platform = PushPlatformFixture()
    let service = PushServiceFixture(store: store)
    let model = PushRegistrationModel(platform: platform, store: store)
    _ = await model.attach(repository: service); await model.enable()
    let first = Data(repeating: 0xBC, count: 32)
    platform.didRegister(deviceToken: first)
    try await waitForPush { await service.registerCount == 1 && !model.busy }
    platform.didRegister(deviceToken: first)
    platform.didRegister(deviceToken: Data(repeating: 0xBD, count: 32))
    try await waitForPush { await service.registerCount == 2 && !model.busy }
    #expect(await service.calls == ["register", "revoke", "register"])
    #expect(try await store.load().entries.first?.deviceIDs.count == 1)
    #expect(await model.detach())
}

@Test @MainActor func pushOfflineCleanupSurvivesRestartAndBlocksEveryOtherAccountAndServer() async throws {
    let store = MemoryPushRegistrationStore(), platform = PushPlatformFixture()
    let old = PushServiceFixture(store: store)
    let first = PushRegistrationModel(platform: platform, store: store)
    _ = await first.attach(repository: old); await first.enable()
    platform.didRegister(deviceToken: Data(repeating: 0xCD, count: 32))
    try await waitForPush { await old.registerCount == 1 && !first.busy }
    await old.fail(revoke: true)
    #expect(await first.detach() == false)
    let nextPlatform = PushPlatformFixture()
    let next = PushServiceFixture(store: store, origin: try ServerOrigin("https://other.fixture.example"), userID: UUID())
    let restarted = PushRegistrationModel(platform: nextPlatform, store: store)
    #expect(await restarted.attach(repository: next) == false)
    await restarted.enable()
    nextPlatform.didRegister(deviceToken: Data(repeating: 0xCE, count: 32))
    #expect(await next.registerCount == 0)
    #expect(nextPlatform.registrations == 0)
    #expect(await restarted.cleanup(repository: old) == false)
    await old.fail()
    #expect(await restarted.cleanup(repository: old))
    await restarted.enable()
    nextPlatform.didRegister(deviceToken: Data(repeating: 0xCE, count: 32))
    try await waitForPush { await next.registerCount == 1 && !restarted.busy }
    #expect(await restarted.detach())
}

@Test @MainActor func pushUnknownResponseCanRecoverOnlyWithMatchingFreshOSToken() async throws {
    let store = MemoryPushRegistrationStore(), platform = PushPlatformFixture()
    let service = PushServiceFixture(store: store)
    await service.fail(register: true)
    let model = PushRegistrationModel(platform: platform, store: store)
    _ = await model.attach(repository: service); await model.enable()
    let token = Data(repeating: 0xDE, count: 32)
    platform.didRegister(deviceToken: token)
    try await waitForPush { await service.registerCount == 1 && !model.busy }
    #expect(await model.detach() == false)
    #expect(try await store.load().entries.first?.pendingTokenFingerprint != nil)
    await service.fail()
    let newPlatform = PushPlatformFixture()
    let restarted = PushRegistrationModel(platform: newPlatform, store: store)
    #expect(await restarted.attach(repository: service) == false)
    let before = await service.registerCount
    newPlatform.didRegister(deviceToken: Data(repeating: 0xDF, count: 32))
    try await Task.sleep(for: .milliseconds(20))
    #expect(await service.registerCount == before) // Cannot recover a lost receipt with a rotated token.
    #expect(try await store.load().entries.first?.hasBinding == true)
    newPlatform.didRegister(deviceToken: token)
    try await waitForPush { await service.registerCount == before + 1 && !restarted.busy }
    #expect(await service.revoked.count == 1)
    #expect(try await store.load().entries.first?.hasBinding == false)
}

@Test @MainActor func pushNoopGatewayOrDeniedPermissionNeverRegisters() async throws {
    let store = MemoryPushRegistrationStore(), platform = PushPlatformFixture()
    let service = PushServiceFixture(store: store)
    let model = PushRegistrationModel(platform: platform, store: store)
    _ = await model.attach(repository: service)
    await service.setCapability("mock"); await model.enable()
    #expect(platform.authorizationRequests == 0)
    await service.setCapability("http"); platform.authorization = .denied; await model.enable()
    #expect(platform.registrations == 0 && !model.enabled)
    #expect(await service.registerCount == 0)
    #expect(try await store.load().entries.isEmpty)
}

@Test @MainActor func pushForegroundPermissionRevocationStopsDeliveryAndCleansOwnBinding() async throws {
    let store = MemoryPushRegistrationStore(), platform = PushPlatformFixture()
    let service = PushServiceFixture(store: store)
    let model = PushRegistrationModel(platform: platform, store: store)
    _ = await model.attach(repository: service); await model.enable()
    platform.didRegister(deviceToken: Data(repeating: 0xEA, count: 32))
    try await waitForPush { await service.registerCount == 1 && !model.busy }
    let stops = platform.unregistrations
    platform.authorization = .denied // User revoked permission outside the running process.
    await model.refreshAuthorization()
    #expect(!model.enabled && platform.unregistrations > stops)
    #expect(platform.authorizationRequests == 1 && platform.registrations == 1)
    try await waitForPush { await service.revoked.count == 1 && !model.busy }
    #expect(try await store.load().entries.first?.hasBinding == false)
    #expect(await service.savedPreferences.push) // Account-wide preferences affect other devices.
    platform.didRegister(deviceToken: Data(repeating: 0xEB, count: 32))
    platform.authorization = .authorized
    await model.refreshAuthorization() // Returning permission does not replace explicit enable.
    try await Task.sleep(for: .milliseconds(20))
    #expect(!model.enabled && platform.registrations == 1)
    #expect(await service.registerCount == 1)
    #expect(await model.detach())
}

private actor FailingPushStore: PushRegistrationStore {
    var value = PushRegistrationJournal()
    var writes = 0
    let failure: Int
    init(failure: Int) { self.failure = failure }
    func load() -> PushRegistrationJournal { value }
    func save(_ journal: PushRegistrationJournal) throws {
        writes += 1
        if writes == failure { throw ClientError.storage }
        value = try journal.validated()
    }
}

@Test @MainActor func pushJournalFailurePreventsPOSTOrRevokesUnpersistedReceipt() async throws {
    for failure in [2, 3] { // enabled preference, pre-POST intent, then receipt
        let store = FailingPushStore(failure: failure), platform = PushPlatformFixture()
        let service = PushServiceFixture(store: store)
        let model = PushRegistrationModel(platform: platform, store: store)
        _ = await model.attach(repository: service); await model.enable()
        platform.didRegister(deviceToken: Data(repeating: 0xEF, count: 32))
        try await waitForPush { await store.writes >= failure && !model.busy }
        #expect(await service.registerCount == (failure == 2 ? 0 : 1))
        if failure == 3 {
            #expect(await service.revoked.count == 1)
            #expect(try await store.load().entries.first?.pendingTokenFingerprint != nil)
        }
        #expect(model.error != nil)
        #expect(await model.detach())
    }
}

@Test @MainActor func stage08AccountDeletionDrainsLatePushWriteBeforeForgettingConfirmedScope() async throws {
    let store = MemoryPushRegistrationStore(), platform = PushPlatformFixture()
    let service = PushServiceFixture(store: store)
    await service.hold()
    let model = PushRegistrationModel(platform: platform, store: store)
    #expect(await model.attach(repository: service)); await model.enable()
    platform.didRegister(deviceToken: Data(repeating: 0xEF, count: 32))
    try await waitForPush { await service.registerCount == 1 }
    // Defensive local ordering only: even confirmed-scope forgetting drains a late receipt.
    // This does not prove server cleanup of that POST; the caller must pause BEFORE DELETE.
    await service.fail(revoke: true)
    let forgotten = Task { await model.accountDeletionConfirmed(origin: service.origin, userID: service.userID) }
    try await waitForPush { !model.enabled }
    #expect(model.busy)
    await service.release()
    #expect(await forgotten.value)
    #expect(try await store.load().entries.isEmpty)
    #expect(model.error == nil && !model.enabled)
    platform.didRegister(deviceToken: Data(repeating: 0xFA, count: 32))
    try await Task.sleep(for: .milliseconds(20))
    #expect(await service.registerCount == 1)
    #expect(try await store.load().entries.isEmpty)
}

@Test @MainActor func stage08AccountDeletionPushPauseCannotRestoreAnotherScopeOrOverrideDisable() async throws {
    let store = MemoryPushRegistrationStore(), platform = PushPlatformFixture()
    let first = PushServiceFixture(store: store), second = PushServiceFixture(store: store, origin: try ServerOrigin("https://other-pause.fixture"))
    let model = PushRegistrationModel(platform: platform, store: store)
    #expect(await model.attach(repository: first)); await model.enable()
    #expect(await model.prepareAccountDeletion(origin: second.origin, userID: second.userID) == nil)
    #expect(model.enabled) // Wrong server with the same user ID cannot pause the active account.
    let firstPause = try #require(await model.prepareAccountDeletion(origin: first.origin, userID: first.userID))
    #expect(!model.enabled)
    let registrations = platform.registrations
    await model.disable()
    #expect(await model.restoreAccountDeletionPause(firstPause) == false)
    #expect(!model.enabled && platform.registrations == registrations)
    #expect(try await store.load().entries.first?.enabled == false)
    await model.enable()
    let secondPause = try #require(await model.prepareAccountDeletion(origin: first.origin, userID: first.userID))
    #expect(await model.attach(repository: second))
    let afterSwitch = platform.registrations
    #expect(await model.restoreAccountDeletionPause(secondPause) == false)
    #expect(!model.enabled && platform.registrations == afterSwitch)
    #expect(await model.detach())
}
