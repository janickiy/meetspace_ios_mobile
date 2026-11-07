import Foundation
import Testing
import MeetSpaceCore
import MeetSpaceAPI
import MeetSpaceStorage
import MeetSpaceCalling
@testable import MeetSpaceFeatures

@MainActor private final class DeletionRecoveryPlatform: NormalPushNotifications {
    let events: AsyncStream<NormalPushNotificationEvent>
    private let continuation: AsyncStream<NormalPushNotificationEvent>.Continuation
    var authorization: NormalPushAuthorization = .authorized
    var registrations = 0
    var permissionRequests = 0
    init() { (events, continuation) = AsyncStream.makeStream() }
    func requestAuthorization() async throws -> NormalPushAuthorization { permissionRequests += 1; return authorization }
    func refreshAuthorization() async { }
    func register() { registrations += 1 }
    func unregister() { }
    func didRegister(deviceToken: Data) { continuation.yield(.token(deviceToken)) }
    func didFailRegistration() { continuation.yield(.failure(.registrationFailed)) }
}

/// Models the independent Keychain confirmation item and a separately failing cleanup journal.
private actor DeletionRecoveryStore: PushRegistrationStore {
    private var journal: PushRegistrationJournal
    private var confirmations: [PushAccountDeletionConfirmation] = []
    private var journalFailures = 0
    private var confirmationFailures = 0
    private var journalReadFails = false
    private var confirmationReadFails = false
    private var confirmationReadFailures = 0
    private var holdNextWrite = false
    private var writeGate: CheckedContinuation<Void, Never>?
    private(set) var writeHeld = false
    private(set) var journalWrites = 0
    private(set) var confirmationWrites = 0
    init(_ journal: PushRegistrationJournal) { self.journal = journal }
    func load() throws -> PushRegistrationJournal {
        if journalReadFails { throw ClientError.storage }
        return try journal.validated()
    }
    func save(_ value: PushRegistrationJournal) async throws {
        journalWrites += 1
        if holdNextWrite {
            holdNextWrite = false; writeHeld = true
            await withCheckedContinuation { writeGate = $0 }
            writeHeld = false
        }
        if journalFailures > 0 { journalFailures -= 1; throw ClientError.storage }
        journal = try value.validated()
    }
    func loadDeletionConfirmations() async throws -> [PushAccountDeletionConfirmation] {
        if confirmationReadFails { throw ClientError.storage }
        if confirmationReadFailures > 0 { confirmationReadFailures -= 1; throw ClientError.storage }
        return confirmations
    }
    func recordDeletionConfirmation(_ value: PushAccountDeletionConfirmation) async throws {
        confirmationWrites += 1
        if confirmationFailures > 0 { confirmationFailures -= 1; throw ClientError.storage }
        if !confirmations.contains(value) { confirmations.append(value) }
        _ = try PushRegistrationJournal(confirmedDeletions: confirmations).validated()
    }
    func fail(journalWrites: Int = 0, confirmationWrites: Int = 0,
              journalRead: Bool = false, confirmationRead: Bool = false) {
        journalFailures = journalWrites; confirmationFailures = confirmationWrites
        journalReadFails = journalRead; confirmationReadFails = confirmationRead
    }
    func holdNextJournalWrite() { holdNextWrite = true }
    func releaseJournalWrite() { holdNextWrite = false; writeGate?.resume(); writeGate = nil }
    func failNextConfirmationQuery() { confirmationReadFailures = 1 }
}

/// Intentionally implements only the original protocol: the real default receipt persists
/// in the journal, and an ordinary subsequent model save must not erase that proof.
private actor JournalOnlyDeletionRecoveryStore: PushRegistrationStore {
    private var journal: PushRegistrationJournal
    private let failedWrite: Int
    private(set) var writes = 0
    init(_ journal: PushRegistrationJournal, failedWrite: Int) {
        self.journal = journal; self.failedWrite = failedWrite
    }
    func load() throws -> PushRegistrationJournal { try journal.validated() }
    func save(_ value: PushRegistrationJournal) throws {
        writes += 1
        if writes == failedWrite { throw ClientError.storage }
        journal = try value.validated()
    }
}

private actor DeletionRecoveryService: NotificationDevicesServing {
    nonisolated let origin: ServerOrigin
    nonisolated let userID: UUID
    private let unauthorized: Bool
    private(set) var registrations = 0
    private(set) var revocations = 0
    private(set) var capabilityReads = 0
    init(origin: ServerOrigin = Fixture.origin, userID: UUID = Fixture.userID, unauthorized: Bool = false) {
        self.origin = origin; self.userID = userID; self.unauthorized = unauthorized
    }
    func capabilities() throws -> IntegrationCapabilities {
        capabilityReads += 1
        if unauthorized { throw APIError.httpStatus(401) }
        return IntegrationCapabilities(push: "http")
    }
    func devices() -> [NotificationDevice] { Issue.record("Recovery must not enumerate other devices"); return [] }
    func preferences() -> NotificationPreferences { NotificationPreferences() }
    func savePreferences(_ value: NotificationPreferences) -> NotificationPreferences { value }
    func register(token: String) throws -> NotificationDevice {
        registrations += 1
        if unauthorized { throw APIError.httpStatus(401) }
        return NotificationDevice(id: UUID(), platform: "ios", provider: "http", createdAt: Date(), updatedAt: Date())
    }
    func revoke(_ deviceID: UUID) throws {
        revocations += 1
        if unauthorized { throw APIError.httpStatus(401) }
    }
}

private func pendingDeletionBinding(origin: ServerOrigin = Fixture.origin, userID: UUID = Fixture.userID) -> PushRegistrationEntry {
    PushRegistrationEntry(origin: origin, userID: userID, enabled: true,
                          pendingTokenFingerprint: String(repeating: "a", count: 64))
}

@Test @MainActor func pushDeletionRecoveryReplaysDurableProofAfterPruneFailureAndRestartWithoutRepository() async throws {
    let otherOrigin = try ServerOrigin("https://other-deletion.fixture")
    let current = pendingDeletionBinding()
    let sameUUIDOtherServer = pendingDeletionBinding(origin: otherOrigin)
    let sameServerOtherUUID = pendingDeletionBinding(userID: UUID())
    let original = PushRegistrationJournal(entries: [current, sameUUIDOtherServer, sameServerOtherUUID])
    let store = DeletionRecoveryStore(original), first = PushRegistrationModel(platform: DeletionRecoveryPlatform(), store: store)
    await store.fail(journalWrites: 1)
    #expect(await first.accountDeletionConfirmed(origin: current.origin, userID: current.userID) == false)
    #expect(try await store.load().entries == original.entries)
    let savedProof = try await store.loadDeletionConfirmations()
    let expectedProof = PushAccountDeletionConfirmation(origin: current.origin, userID: current.userID)
    #expect(savedProof == [expectedProof])
    #expect(await store.confirmationWrites == 1)
    #expect(await store.journalWrites == 1)
    // Fresh model, no restored credentials/repository, and no matching OS token.
    let platform = DeletionRecoveryPlatform(), restarted = PushRegistrationModel(platform: platform, store: store)
    #expect(try await restarted.isAccountDeletionConfirmed(origin: current.origin, userID: current.userID))
    #expect(try await restarted.isAccountDeletionConfirmed(origin: otherOrigin, userID: current.userID) == false)
    await restarted.retryCleanup()
    #expect(try await store.load().entries == [sameUUIDOtherServer, sameServerOtherUUID])
    #expect(await store.journalWrites == 2)
    #expect(platform.registrations == 0 && platform.permissionRequests == 0)
    let fresh = DeletionRecoveryService(userID: UUID())
    #expect(await restarted.attach(repository: fresh) == false) // Unconfirmed OTHER bindings remain a barrier.
    await restarted.enable()
    #expect(await fresh.registrations == 0)
}

@Test @MainActor func pushDeletionRecoveryRetriesLoadedModelAndAllowsOnlyDifferentConfirmedCleanScope() async throws {
    let current = pendingDeletionBinding(), store = DeletionRecoveryStore(PushRegistrationJournal(entries: [pendingDeletionBinding()]))
    let platform = DeletionRecoveryPlatform(), model = PushRegistrationModel(platform: platform, store: store)
    await store.fail(journalWrites: 1)
    #expect(await model.accountDeletionConfirmed(origin: current.origin, userID: current.userID) == false)
    await model.retryCleanup() // loaded=true, repository=nil; must still replay.
    #expect(try await store.load().entries.isEmpty)
    #expect(model.error == nil && !model.busy)
    let deleted = DeletionRecoveryService(), next = DeletionRecoveryService(userID: UUID())
    #expect(await model.attach(repository: deleted) == false)
    await model.enable()
    #expect(await deleted.capabilityReads == 0)
    #expect(await deleted.registrations == 0)
    #expect(await model.attach(repository: next))
    await model.enable()
    #expect(model.enabled && platform.registrations == 1 && platform.permissionRequests == 1)
    #expect(try await store.load().confirmedDeletions == [PushAccountDeletionConfirmation(origin: current.origin, userID: current.userID)])
    #expect(try await store.load().entries.allSatisfy { $0.userID == next.userID })
}

@Test @MainActor func pushDeletionRecoveryRetriesOneFailedProofWriteBeforePruning() async throws {
    let current = pendingDeletionBinding(), store = DeletionRecoveryStore(PushRegistrationJournal(entries: [pendingDeletionBinding()]))
    await store.fail(confirmationWrites: 1)
    let model = PushRegistrationModel(platform: DeletionRecoveryPlatform(), store: store)
    #expect(await model.accountDeletionConfirmed(origin: current.origin, userID: current.userID))
    #expect(await store.confirmationWrites == 2)
    #expect(await store.journalWrites == 1)
    #expect(try await store.load().entries.isEmpty)
    let restarted = PushRegistrationModel(platform: DeletionRecoveryPlatform(), store: store)
    #expect(try await restarted.isAccountDeletionConfirmed(origin: current.origin, userID: current.userID))
    #expect(await restarted.attach(repository: DeletionRecoveryService()) == false)
}

@Test @MainActor func pushDeletionRecoveryRetainsMemoryProofAcrossFiniteFailureUntilExplicitRetry() async throws {
    let current = pendingDeletionBinding(), store = DeletionRecoveryStore(PushRegistrationJournal(entries: [pendingDeletionBinding()]))
    await store.fail(confirmationWrites: 2)
    let model = PushRegistrationModel(platform: DeletionRecoveryPlatform(), store: store)
    #expect(await model.accountDeletionConfirmed(origin: current.origin, userID: current.userID) == false)
    #expect(await store.confirmationWrites == 2)
    #expect(await store.journalWrites == 0)
    #expect(!model.busy)
    #expect(try await store.loadDeletionConfirmations().isEmpty)
    #expect(try await model.isAccountDeletionConfirmed(origin: current.origin, userID: current.userID))
    #expect(try await store.load().entries == [current])
    await model.retryCleanup()
    #expect(await store.confirmationWrites == 3)
    #expect(await store.journalWrites == 1)
    #expect(try await store.load().entries.isEmpty)
}

@Test @MainActor func pushDeletionRecoveryCannotInferUnpersistedProofAfterProcessLossOr401() async throws {
    let current = PushRegistrationEntry(origin: Fixture.origin, userID: Fixture.userID, deviceIDs: [UUID()],
                                        enabled: true, pendingTokenFingerprint: String(repeating: "b", count: 64))
    let store = DeletionRecoveryStore(PushRegistrationJournal(entries: [current]))
    await store.fail(confirmationWrites: 2)
    let lostProcess = PushRegistrationModel(platform: DeletionRecoveryPlatform(), store: store)
    #expect(await lostProcess.accountDeletionConfirmed(origin: current.origin, userID: current.userID) == false)
    let platform = DeletionRecoveryPlatform(), restarted = PushRegistrationModel(platform: platform, store: store)
    #expect(try await restarted.isAccountDeletionConfirmed(origin: current.origin, userID: current.userID) == false)
    let unauthorized = DeletionRecoveryService(unauthorized: true)
    #expect(await restarted.attach(repository: unauthorized) == false)
    await restarted.retryCleanup()
    #expect(try await store.load().entries == [current])
    #expect(try await store.loadDeletionConfirmations().isEmpty)
    #expect(await unauthorized.revocations == 2)
    #expect(await unauthorized.registrations == 0)
    #expect(!restarted.enabled)
}

@Test @MainActor func pushDeletionRecoveryProofReadIsIndependentOfBrokenJournalAndNeverTreatsReadFailureAsFalse() async throws {
    let current = pendingDeletionBinding(), store = DeletionRecoveryStore(PushRegistrationJournal(entries: [pendingDeletionBinding()]))
    await store.fail(journalRead: true)
    let first = PushRegistrationModel(platform: DeletionRecoveryPlatform(), store: store)
    #expect(await first.accountDeletionConfirmed(origin: current.origin, userID: current.userID) == false)
    #expect(await store.confirmationWrites == 1)
    #expect(await store.journalWrites == 0)
    let restarted = PushRegistrationModel(platform: DeletionRecoveryPlatform(), store: store)
    #expect(try await restarted.isAccountDeletionConfirmed(origin: current.origin, userID: current.userID))
    await store.fail(confirmationRead: true)
    let third = PushRegistrationModel(platform: DeletionRecoveryPlatform(), store: store)
    await #expect(throws: ClientError.storage) {
        try await third.isAccountDeletionConfirmed(origin: current.origin, userID: current.userID)
    }
    await store.fail()
    await restarted.retryCleanup()
    #expect(try await store.load().entries.isEmpty)
}

@Test @MainActor func pushDeletionRecoveryJournalFallbackSurvivesEitherSingleWriteFailureAndLaterNormalSaves() async throws {
    for failedWrite in [1, 2] { // Confirmation write, then journal prune.
        let current = pendingDeletionBinding()
        let store = JournalOnlyDeletionRecoveryStore(PushRegistrationJournal(entries: [current]), failedWrite: failedWrite)
        let first = PushRegistrationModel(platform: DeletionRecoveryPlatform(), store: store)
        #expect(await first.accountDeletionConfirmed(origin: current.origin, userID: current.userID) == (failedWrite == 1))
        let restarted = PushRegistrationModel(platform: DeletionRecoveryPlatform(), store: store)
        #expect(try await restarted.isAccountDeletionConfirmed(origin: current.origin, userID: current.userID))
        await restarted.retryCleanup()
        let next = DeletionRecoveryService(userID: UUID())
        #expect(await restarted.attach(repository: next))
        await restarted.enable(); await restarted.disable()
        #expect(try await store.load().entries.allSatisfy { $0.userID == next.userID })
        #expect(try await store.loadDeletionConfirmations() == [PushAccountDeletionConfirmation(origin: current.origin, userID: current.userID)])
    }
}

@Test @MainActor func pushDeletionRecoveryFencesLateOSTokenEnableAndPausedIntent() async throws {
    let store = DeletionRecoveryStore(PushRegistrationJournal()), platform = DeletionRecoveryPlatform()
    let service = DeletionRecoveryService(), model = PushRegistrationModel(platform: platform, store: store)
    #expect(await model.attach(repository: service)); await model.enable()
    let pause = try #require(await model.prepareAccountDeletion(origin: service.origin, userID: service.userID))
    await store.fail(journalWrites: 1)
    #expect(await model.accountDeletionConfirmed(origin: service.origin, userID: service.userID) == false)
    #expect(await model.restoreAccountDeletionPause(pause) == false)
    await model.enable()
    platform.didRegister(deviceToken: Data(repeating: 0xCA, count: 32))
    try await Task.sleep(for: .milliseconds(20))
    #expect(await service.registrations == 0)
    #expect(await service.revocations == 0)
    #expect(!model.enabled && !model.busy)
    await model.retryCleanup()
    #expect(try await store.load().entries.isEmpty)
}

@Test @MainActor func pushDeletionRecoveryFencesRegistrationSuspendedAtPrePOSTJournalWrite() async throws {
    let store = DeletionRecoveryStore(PushRegistrationJournal()), platform = DeletionRecoveryPlatform()
    let service = DeletionRecoveryService(), model = PushRegistrationModel(platform: platform, store: store)
    #expect(await model.attach(repository: service)); await model.enable()
    await store.holdNextJournalWrite()
    platform.didRegister(deviceToken: Data(repeating: 0xCB, count: 32))
    for _ in 0..<200 {
        if await store.writeHeld { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let reachedGate = await store.writeHeld
    #expect(reachedGate)
    guard reachedGate else { await store.releaseJournalWrite(); return }
    let confirmation = Task { await model.accountDeletionConfirmed(origin: service.origin, userID: service.userID) }
    for _ in 0..<200 {
        if !model.enabled { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(!model.enabled)
    await store.releaseJournalWrite()
    #expect(await confirmation.value)
    #expect(await service.registrations == 0)
    #expect(await service.revocations == 0)
    #expect(try await store.load().entries.isEmpty)
    #expect(try await store.loadDeletionConfirmations().count == 1)
}

@Test @MainActor func pushDeletionRecoveryPersistsPendingProofBeforeOneFailedLedgerQuery() async throws {
    let current = pendingDeletionBinding(), store = DeletionRecoveryStore(PushRegistrationJournal(entries: [pendingDeletionBinding()]))
    await store.failNextConfirmationQuery()
    let first = PushRegistrationModel(platform: DeletionRecoveryPlatform(), store: store)
    #expect(await first.accountDeletionConfirmed(origin: current.origin, userID: current.userID) == false)
    #expect(await store.confirmationWrites == 1) // Read failure did not prevent the proof write.
    #expect(await store.journalWrites == 0)
    let restarted = PushRegistrationModel(platform: DeletionRecoveryPlatform(), store: store)
    #expect(try await restarted.isAccountDeletionConfirmed(origin: current.origin, userID: current.userID))
    await restarted.retryCleanup()
    #expect(try await store.load().entries.isEmpty)
    #expect(await store.journalWrites == 1)
}

@Test func pushDeletionRecoveryJournalMigrationValidationAndMonotonicMemoryReceipt() async throws {
    let old = try WireJSON.decoder().decode(PushRegistrationJournal.self, from: Data("{\"entries\":[]}".utf8)).validated()
    #expect(old.confirmedDeletions.isEmpty)
    let scope = PushAccountDeletionConfirmation(origin: Fixture.origin, userID: Fixture.userID)
    #expect(throws: ClientError.storage) { try PushRegistrationJournal(confirmedDeletions: [scope, scope]).validated() }
    let invalid = PushAccountDeletionConfirmation(origin: Fixture.origin, userID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
    #expect(throws: ClientError.storage) { try PushRegistrationJournal(confirmedDeletions: [invalid]).validated() }
    let tooMany = (0..<1001).map { _ in PushAccountDeletionConfirmation(origin: Fixture.origin, userID: UUID()) }
    #expect(throws: ClientError.storage) { try PushRegistrationJournal(confirmedDeletions: tooMany).validated() }
    let store = MemoryPushRegistrationStore()
    try await store.recordDeletionConfirmation(scope)
    try await store.save(old) // Even an old cached empty snapshot cannot erase a confirmed scope.
    #expect(try await store.loadDeletionConfirmations() == [scope])
}
