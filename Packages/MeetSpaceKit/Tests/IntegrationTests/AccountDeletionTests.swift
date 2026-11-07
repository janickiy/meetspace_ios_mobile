import Foundation
import Testing
import MeetSpaceCore
import MeetSpaceAPI
import MeetSpaceStorage
import MeetSpaceRealtime
import MeetSpaceCalling
@testable import MeetSpaceFeatures

@Test func stage08AccountDeletionSendsOneScopedPasswordMutationAfterPreflightRefresh() async throws {
    let account = try Fixture.account(), secrets = TestSecrets()
    let transport = RoutedTransport { request, upload in
        if request.url?.path.hasSuffix("/refresh") == true { return try Fixture.login() }
        #expect(request.url?.absoluteString == "https://fixture.example/api/v1/auth/me")
        #expect(request.httpMethod == "DELETE" && upload == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-renewed-token")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: String]
        #expect(body == ["password": "private-confirmation"])
        return try Fixture.response(["status": "success"])
    }
    let client = AuthenticatedClient(account: account, credentials: Fixture.credentials(expired: true), secureStore: secrets, transport: transport)
    try await client.deleteAccount(password: "private-confirmation")
    #expect(await transport.requests.map(\.httpMethod) == ["POST", "DELETE"])
    _ = try await client.close()
}

@Test func stage08AccountDeletionRejectionsNeverReplayOrExpireValidSession() async throws {
    for (status, expected) in [(400, AccountDeletionError.passwordRejected), (422, .passwordRejected),
                              (401, .notAuthorized), (403, .notAuthorized), (409, .conflict), (405, .unavailable)] {
        let transport = RoutedTransport { request, _ in
            if request.httpMethod == "DELETE" { return NetworkResponse(status: status) }
            #expect(request.httpMethod == "GET" && request.url?.path.hasSuffix("/auth/me") == true)
            return try Fixture.response(["user": Fixture.user()])
        }
        let client = AuthenticatedClient(account: try Fixture.account(), credentials: Fixture.credentials(), secureStore: TestSecrets(), transport: transport)
        await #expect(throws: expected) { try await client.deleteAccount(password: "wrong") }
        #expect(try await client.currentUser().id == Fixture.userID)
        #expect(await transport.requests.map(\.httpMethod) == ["DELETE", "GET"])
        _ = try await client.close()
    }
}

@Test func stage08AccountDeletionUnknownOutcomeIsNeverReportedAsSuccessOrRetried() async throws {
    for failure in 0..<4 {
        let transport = RoutedTransport { request, _ in
            if request.httpMethod != "DELETE" { return try Fixture.response(["user": Fixture.user()]) }
            switch failure {
            case 0: throw APIError.timeout
            case 1: return NetworkResponse(status: 503)
            case 2: return try Fixture.response(["status": "not-confirmed"])
            default: return NetworkResponse(status: 200, headers: ["content-type": "application/json"], data: Data("{broken".utf8))
            }
        }
        let client = AuthenticatedClient(account: try Fixture.account(), credentials: Fixture.credentials(), secureStore: TestSecrets(), transport: transport)
        await #expect(throws: AccountDeletionError.unconfirmed) { try await client.deleteAccount(password: "password") }
        #expect(try await client.currentUser().id == Fixture.userID)
        #expect(await transport.requests.filter { $0.httpMethod == "DELETE" }.count == 1)
        _ = try await client.close()
    }
}

@Test func stage08AccountDeletionInvalidPasswordNeverSendsRequest() async throws {
    let transport = RoutedTransport { _, _ in Issue.record("Invalid input must not be transmitted"); throw APIError.offline }
    let client = AuthenticatedClient(account: try Fixture.account(), credentials: Fixture.credentials(), secureStore: TestSecrets(), transport: transport)
    for password in ["", String(repeating: "a", count: 129)] {
        await #expect(throws: ClientError.invalidInput) { try await client.deleteAccount(password: password) }
    }
    #expect(await transport.requests.isEmpty)
    _ = try await client.close()
}

private struct DeletionProbe: ServerProbing {
    func check(_ origin: ServerOrigin) async throws -> ServerVersion { throw APIError.offline }
}
private actor DeletionPreferences: ConfigurationStore {
    func load() -> AppConfiguration { AppConfiguration() }
    func save(_ value: AppConfiguration) {}
}
private struct DeletionSockets: RealtimeSocketFactory {
    func connect(_ url: URL) async throws -> any RealtimeSocket { throw APIError.offline }
}
private actor DeletionDownloads: RecordingDownloading {
    var closes = 0
    func download(url: URL, file: RecordingFile, progress: TransferProgress?) throws -> URL { throw APIError.offline }
    func remove(_ url: URL) {}
    func close() { closes += 1 }
}
private actor DeletionGate {
    var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { waiting = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@Test func stage08AccountDeletionKeepsAffirmativeResultWhenConcurrentReadSeesRevocation() async throws {
    let gate = DeletionGate()
    let transport = RoutedTransport { request, _ in
        if request.httpMethod == "DELETE" {
            await gate.wait(); return try Fixture.response(["status": "success"])
        }
        return NetworkResponse(status: 401)
    }
    let client = AuthenticatedClient(account: try Fixture.account(), credentials: Fixture.credentials(), secureStore: TestSecrets(), transport: transport)
    let deletion = Task { try await client.deleteAccount(password: "password") }
    for _ in 0..<300 { if await gate.waiting { break }; try await Task.sleep(for: .milliseconds(5)) }
    #expect(await gate.waiting)
    await #expect(throws: ClientError.sessionExpired) { try await client.currentUser() }
    await gate.release()
    try await deletion.value
    #expect(await transport.requests.filter { $0.httpMethod == "DELETE" }.count == 1)
    _ = try await client.close()
}

@Test @MainActor func stage08AccountDeletionRemovesOnlyConfirmedScopeAndFencesIdentityChanges() async throws {
    // Same UUID on another server must keep its credentials, file cache and push cleanup journal.
    let first = try Fixture.account(UUID())
    let second = try Fixture.account(first.user.id, server: ServerOrigin("https://other-delete.fixture"))
    let secrets = TestSecrets(), accounts = MemoryAccountIndexStore(), downloads = DeletionDownloads(), gate = DeletionGate()
    let credentials = try WireJSON.encoder().encode(Fixture.credentials())
    try await secrets.write(credentials, for: first.key); try await secrets.write(credentials, for: second.key)
    try await accounts.save(AccountIndex(accounts: [first, second], activeID: first.id))
    let otherBinding = PushRegistrationEntry(origin: second.server, userID: second.user.id, deviceIDs: [UUID()], enabled: true)
    let pushStore = MemoryPushRegistrationStore(PushRegistrationJournal(entries: [
        PushRegistrationEntry(origin: first.server, userID: first.user.id, deviceIDs: [UUID()], enabled: true), otherBinding]))
    let firstFiles = AccountFileStore(account: first), secondFiles = AccountFileStore(account: second)
    let ownFile = try await firstFiles.storeDownload(Data("owned".utf8), filename: "owned.txt")
    let peerFile = try await secondFiles.storeDownload(Data("peer".utf8), filename: "peer.txt")
    let transport = RoutedTransport { request, _ in
        if request.httpMethod == "DELETE", request.url?.path == "/api/v1/auth/me" {
            #expect(request.url?.host == first.server.url.host)
            await gate.wait(); return try Fixture.response(["status": "success"])
        }
        if request.url?.path == "/api/v1/auth/me" { return try Fixture.response(["user": Fixture.user(first.user.id)]) }
        throw APIError.offline
    }
    let identity = IdentityModel(dependencies: AppDependencies(serverProbe: DeletionProbe(), configuration: DeletionPreferences(),
        credentials: secrets, accounts: accounts, transport: { transport }, sockets: DeletionSockets(), pushStore: pushStore,
        recordingDownloads: { _ in downloads }))
    await identity.restore()
    let oldClient = try #require(identity.messaging?.client), oldSettings = try #require(identity.settings)
    let deletion = Task { await identity.deleteAccount(first, password: "correct-password") }
    for _ in 0..<300 { if await gate.waiting { break }; try await Task.sleep(for: .milliseconds(5)) }
    #expect(await gate.waiting)
    #expect(identity.busy && identity.deletingAccount)
    await identity.switchAccount(second); await identity.logout(first)
    #expect(identity.messaging?.account.id == first.id && identity.index.accounts.count == 2)
    #expect(await identity.deleteAccount(first, password: "duplicate") == false)
    await gate.release()
    #expect(await deletion.value)
    #expect(identity.messaging == nil && identity.calendar == nil && identity.recordings == nil && identity.settings == nil)
    #expect(identity.calls == nil && identity.conferences == nil && !identity.busy && !identity.deletingAccount)
    #expect(identity.index.accounts == [second])
    #expect(await accounts.load().accounts == [second])
    #expect(await secrets.read(first.key) == nil)
    #expect(await secrets.read(second.key) == credentials)
    #expect(!FileManager.default.fileExists(atPath: ownFile.path) && FileManager.default.fileExists(atPath: peerFile.path))
    #expect(try await pushStore.load().entries == [otherBinding])
    #expect(await downloads.closes == 1 && !oldSettings.canSaveProfile)
    await #expect(throws: CancellationError.self) { try await oldClient.currentUser() }
    #expect(await transport.requests.filter { $0.httpMethod == "DELETE" && $0.url?.path == "/api/v1/auth/me" }.count == 1)
    #expect(await transport.requests.filter { $0.url?.path.hasSuffix("/logout") == true }.isEmpty)
    await identity.switchAccount(second)
    #expect(identity.messaging?.account.id == second.id)
    await identity.logout(second)
    try await secondFiles.clear()
}

@Test @MainActor func stage08AccountDeletionFailurePreservesWorkspaceCredentialsAndCachedFiles() async throws {
    for status in [422, 409, 503] {
        let account = try Fixture.account(UUID()), secrets = TestSecrets(), accounts = MemoryAccountIndexStore()
        let credentials = try WireJSON.encoder().encode(Fixture.credentials())
        try await secrets.write(credentials, for: account.key)
        try await accounts.save(AccountIndex(accounts: [account], activeID: account.id))
        let files = AccountFileStore(account: account)
        let cached = try await files.storeDownload(Data("retained".utf8), filename: "retained.txt")
        let transport = RoutedTransport { request, _ in
            if request.httpMethod == "DELETE" { return NetworkResponse(status: status) }
            if request.url?.path == "/api/v1/auth/me" { return try Fixture.response(["user": Fixture.user(account.user.id)]) }
            throw APIError.offline
        }
        let identity = IdentityModel(dependencies: AppDependencies(serverProbe: DeletionProbe(), configuration: DeletionPreferences(),
            credentials: secrets, accounts: accounts, transport: { transport }, sockets: DeletionSockets()))
        await identity.restore()
        let previous = try #require(identity.messaging)
        #expect(await identity.deleteAccount(account, password: "password") == false)
        #expect(identity.messaging === previous && !identity.busy && !identity.deletingAccount)
        #expect(identity.error != nil && identity.information == nil)
        #expect(identity.index.accounts == [account])
        #expect(await secrets.read(account.key) == credentials)
        #expect(FileManager.default.fileExists(atPath: cached.path))
        #expect(try await previous.client.currentUser().id == account.user.id)
        await identity.logout(account)
    }
}

@MainActor private final class DeletionPushPlatform: NormalPushNotifications {
    let events: AsyncStream<NormalPushNotificationEvent>
    private let continuation: AsyncStream<NormalPushNotificationEvent>.Continuation
    var authorization: NormalPushAuthorization = .authorized
    var prompts = 0
    var registrations = 0
    init() { (events, continuation) = AsyncStream.makeStream() }
    func requestAuthorization() async throws -> NormalPushAuthorization { prompts += 1; return authorization }
    func refreshAuthorization() async { }
    func register() { registrations += 1 }
    func unregister() { }
    func didRegister(deviceToken: Data) { continuation.yield(.token(deviceToken)) }
    func didFailRegistration() { continuation.yield(.failure(.registrationFailed)) }
    func token(_ byte: UInt8) { didRegister(deviceToken: Data(repeating: byte, count: 32)) }
}
private actor DeletionPushOrder {
    var events: [String] = []
    func append(_ event: String) { events.append(event) }
}
@MainActor private func waitForDeletionPush(_ predicate: @escaping @MainActor () async -> Bool) async throws {
    for _ in 0..<300 {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw APIError.timeout
}
private func deletionPushDefaults(_ path: String) throws -> NetworkResponse? {
    if path == "/api/v1/integrations/capabilities" {
        return NetworkResponse(status: 200, headers: ["content-type": "application/json"],
            data: try WireJSON.encoder().encode(IntegrationCapabilities(push: "http")))
    }
    if path == "/api/v1/notifications/preferences" {
        return NetworkResponse(status: 200, headers: ["content-type": "application/json"],
            data: try WireJSON.encoder().encode(NotificationPreferences(push: true)))
    }
    return nil
}
private func deletionPushDevice() throws -> NetworkResponse {
    try Fixture.response(["item": ["id": "ab111111-1111-4111-8111-111111111111", "platform": "ios", "provider": "http",
        "createdAt": "2026-11-06T12:00:00Z", "updatedAt": "2026-11-06T12:00:00Z"]])
}

@Test @MainActor func stage08AccountDeletionWaitsForLatePushWriteAndCleanupBeforeDELETE() async throws {
    for revokeFails in [false, true] {
        let account = try Fixture.account(UUID()), secrets = TestSecrets(), accounts = MemoryAccountIndexStore()
        let platform = DeletionPushPlatform(), store = MemoryPushRegistrationStore(), gate = DeletionGate(), order = DeletionPushOrder()
        try await secrets.write(WireJSON.encoder().encode(Fixture.credentials()), for: account.key)
        try await accounts.save(AccountIndex(accounts: [account], activeID: account.id))
        let transport = RoutedTransport { request, _ in
            let path = request.url!.path
            if path == "/api/v1/notifications/devices", request.httpMethod == "POST" {
                await order.append("register-start")
                await gate.wait()
                await order.append("register-finished")
                return try deletionPushDevice()
            }
            if path.hasPrefix("/api/v1/notifications/devices/"), request.httpMethod == "DELETE" {
                await order.append("revoke")
                if revokeFails { throw APIError.offline }
                return NetworkResponse(status: 204)
            }
            if path == "/api/v1/auth/me", request.httpMethod == "DELETE" {
                let before = await order.events
                #expect(before.first == "register-start" && before.dropFirst().first == "register-finished")
                #expect(before.last == "revoke")
                let entry = try #require(await store.load().entries.first)
                #expect(entry.origin == account.server && entry.userID == account.user.id && entry.enabled)
                #expect(entry.hasBinding == revokeFails) // Failed cleanup is not silently forgotten before 200.
                await order.append("delete")
                return try Fixture.response(["status": "success"])
            }
            if path == "/api/v1/auth/me" { return try Fixture.response(["user": Fixture.user(account.user.id)]) }
            if let response = try deletionPushDefaults(path) { return response }
            throw APIError.offline
        }
        let identity = IdentityModel(dependencies: AppDependencies(serverProbe: DeletionProbe(), configuration: DeletionPreferences(),
            credentials: secrets, accounts: accounts, transport: { transport }, sockets: DeletionSockets(),
            notifications: { platform }, pushStore: store))
        await identity.restore(); await identity.notifications.enable()
        platform.token(0xAC)
        try await waitForDeletionPush { await gate.waiting }
        let deletion = Task { await identity.deleteAccount(account, password: "confirmed-password") }
        try await waitForDeletionPush { identity.deletingAccount && !identity.notifications.enabled }
        #expect(await order.events == ["register-start"])
        platform.token(0xAD) // New callbacks are fenced while the earlier POST is still running.
        await gate.release()
        #expect(await deletion.value)
        #expect(await order.events.last == "delete")
        #expect(await order.events.filter { $0 == "register-start" }.count == 1)
        #expect(try await store.load().entries.isEmpty)
        #expect(identity.messaging == nil)
        #expect(await secrets.read(account.key) == nil)
    }
}

@Test @MainActor func stage08AccountDeletionRejectionAndUnknownRestorePriorPushIntentWithoutPrompt() async throws {
    for enabled in [false, true] {
        for status in [422, 409, 503, -1] {
            let account = try Fixture.account(UUID()), secrets = TestSecrets(), accounts = MemoryAccountIndexStore()
            let platform = DeletionPushPlatform(), order = DeletionPushOrder()
            let store = MemoryPushRegistrationStore(PushRegistrationJournal(entries: [
                PushRegistrationEntry(origin: account.server, userID: account.user.id, enabled: enabled)]))
            let credentials = try WireJSON.encoder().encode(Fixture.credentials())
            try await secrets.write(credentials, for: account.key)
            try await accounts.save(AccountIndex(accounts: [account], activeID: account.id))
            let transport = RoutedTransport { request, _ in
                let path = request.url!.path
                if path == "/api/v1/auth/me", request.httpMethod == "DELETE" {
                    await order.append("delete")
                    if status == -1 { throw APIError.timeout }
                    return NetworkResponse(status: status)
                }
                if path == "/api/v1/notifications/devices", request.httpMethod == "POST" {
                    await order.append("register"); return try deletionPushDevice()
                }
                if path.hasPrefix("/api/v1/notifications/devices/"), request.httpMethod == "DELETE" {
                    await order.append("revoke"); return NetworkResponse(status: 204)
                }
                if path == "/api/v1/auth/me" { return try Fixture.response(["user": Fixture.user(account.user.id)]) }
                if let response = try deletionPushDefaults(path) { return response }
                throw APIError.offline
            }
            let identity = IdentityModel(dependencies: AppDependencies(serverProbe: DeletionProbe(), configuration: DeletionPreferences(),
                credentials: secrets, accounts: accounts, transport: { transport }, sockets: DeletionSockets(),
                notifications: { platform }, pushStore: store))
            await identity.restore()
            let workspace = try #require(identity.messaging)
            if enabled {
                platform.token(0xBD)
                try await waitForDeletionPush { await order.events.contains("register") && !identity.notifications.busy }
            }
            #expect(await identity.deleteAccount(account, password: "not-deleted") == false)
            #expect(identity.messaging === workspace && identity.notifications.enabled == enabled)
            #expect(platform.prompts == 0 && platform.registrations == (enabled ? 2 : 0))
            #expect(try await store.load().entries.first?.enabled == enabled)
            #expect(await secrets.read(account.key) == credentials)
            #expect(await order.events.filter { $0 == "delete" }.count == 1)
            if enabled {
                #expect(await order.events == ["register", "revoke", "delete"])
                platform.token(0xBE)
                try await waitForDeletionPush { await order.events.filter { $0 == "register" }.count == 2 && !identity.notifications.busy }
            }
            await identity.logout(account)
        }
    }
}

private actor IdentityDeletionRecoveryStore: PushRegistrationStore {
    var journal: PushRegistrationJournal
    var confirmations: [PushAccountDeletionConfirmation] = []
    var failedPrunes = 0
    init(_ journal: PushRegistrationJournal) { self.journal = journal }
    func load() -> PushRegistrationJournal { journal }
    func loadDeletionConfirmations() async throws -> [PushAccountDeletionConfirmation] { confirmations }
    func recordDeletionConfirmation(_ value: PushAccountDeletionConfirmation) async throws {
        if !confirmations.contains(value) { confirmations.append(value) }
    }
    func save(_ value: PushRegistrationJournal) throws {
        if !confirmations.isEmpty, !journal.entries.isEmpty, value.entries.isEmpty, failedPrunes == 0 {
            failedPrunes += 1; throw ClientError.storage
        }
        journal = try value.validated()
    }
}

@Test @MainActor func stage08P2IdentityConfirmedDeletionRecoversJournalForAnotherAccountAfterRestart() async throws {
    let deleted = try Fixture.account(UUID())
    let other = try Fixture.account(UUID(), server: ServerOrigin("https://recovery-other.fixture"))
    let secrets = TestSecrets(), accounts = MemoryAccountIndexStore()
    let credentials = try WireJSON.encoder().encode(Fixture.credentials())
    try await secrets.write(credentials, for: deleted.key); try await secrets.write(credentials, for: other.key)
    try await accounts.save(AccountIndex(accounts: [deleted, other], activeID: deleted.id))
    // No OS token exists after restart, so this unknown binding cannot be revoked by retrying POST.
    let push = IdentityDeletionRecoveryStore(PushRegistrationJournal(entries: [PushRegistrationEntry(
        origin: deleted.server, userID: deleted.user.id, pendingTokenFingerprint: String(repeating: "a", count: 64))]))
    let transport = RoutedTransport { request, _ in
        if request.httpMethod == "DELETE", request.url?.path == "/api/v1/auth/me" {
            #expect(request.url?.host == deleted.server.url.host)
            return try Fixture.response(["status": "success"])
        }
        if request.httpMethod == "GET", request.url?.path == "/api/v1/auth/me" {
            return try Fixture.response(["user": Fixture.user(request.url?.host == deleted.server.url.host ? deleted.user.id : other.user.id)])
        }
        throw APIError.offline
    }
    let dependencies = AppDependencies(serverProbe: DeletionProbe(), configuration: DeletionPreferences(),
        credentials: secrets, accounts: accounts, transport: { transport }, sockets: DeletionSockets(), pushStore: push)
    let first = IdentityModel(dependencies: dependencies)
    await first.restore()
    #expect(await first.deleteAccount(deleted, password: "fixture-password"))
    #expect(await push.failedPrunes == 1)
    #expect(first.information?.contains("Сервер подтвердил удаление") == true)
    #expect(await push.load().entries.count == 1)
    #expect(await secrets.read(deleted.key) == nil && first.messaging == nil)
    #expect(try await push.loadDeletionConfirmations() == [PushAccountDeletionConfirmation(origin: deleted.server, userID: deleted.user.id)])
    let restarted = IdentityModel(dependencies: dependencies)
    await restarted.restore(); await restarted.switchAccount(other)
    #expect(restarted.messaging?.account.id == other.id)
    #expect(await push.load().entries.isEmpty)
    #expect(restarted.notifications.error == nil && !restarted.notifications.enabled)
    #expect(await secrets.read(other.key) == credentials)
    #expect(await transport.requests.filter { $0.httpMethod == "DELETE" && $0.url?.path == "/api/v1/auth/me" }.count == 1)
    #expect(await transport.requests.filter { $0.url?.path.contains("/devices") == true }.isEmpty)
    await restarted.logout(other)
}

@Test @MainActor func stage08P2IdentityNeverRestoresConfirmedDeletedScopeOffline() async throws {
    let deleted = try Fixture.account(UUID())
    let other = try Fixture.account(deleted.user.id, server: ServerOrigin("https://same-id-recovery.fixture"))
    let secrets = TestSecrets(), accounts = MemoryAccountIndexStore(), push = MemoryPushRegistrationStore()
    let credentials = try WireJSON.encoder().encode(Fixture.credentials())
    try await secrets.write(credentials, for: deleted.key); try await secrets.write(credentials, for: other.key)
    try await accounts.save(AccountIndex(accounts: [deleted, other], activeID: deleted.id))
    try await push.recordDeletionConfirmation(PushAccountDeletionConfirmation(origin: deleted.server, userID: deleted.user.id))
    let ownFiles = AccountFileStore(account: deleted), otherFiles = AccountFileStore(account: other)
    let own = try await ownFiles.storeDownload(Data("deleted".utf8), filename: "fixture.txt")
    let peer = try await otherFiles.storeDownload(Data("retained".utf8), filename: "fixture.txt")
    let transport = RoutedTransport { _, _ in throw APIError.offline }
    let identity = IdentityModel(dependencies: AppDependencies(serverProbe: DeletionProbe(), configuration: DeletionPreferences(),
        credentials: secrets, accounts: accounts, transport: { transport }, sockets: DeletionSockets(), pushStore: push))
    await identity.restore()
    #expect(identity.messaging == nil && identity.index.accounts == [other])
    #expect(await accounts.load().accounts == [other])
    #expect(await transport.requests.isEmpty) // No refresh, currentUser, DELETE or old-scope push mutation.
    let deletedCredentials = await secrets.read(deleted.key), retainedCredentials = await secrets.read(other.key)
    #expect(deletedCredentials == nil && retainedCredentials == credentials)
    #expect(!FileManager.default.fileExists(atPath: own.path) && FileManager.default.fileExists(atPath: peer.path))
    await identity.switchAccount(other)
    #expect(identity.messaging?.account.id == other.id) // Same UUID on another origin is independent.
    await identity.logout(other)
}

@Test @MainActor func stage08P2IdentityUnauthorizedIsNotDeletionConfirmation() async throws {
    let account = try Fixture.account(UUID()), secrets = TestSecrets(), accounts = MemoryAccountIndexStore()
    let entry = PushRegistrationEntry(origin: account.server, userID: account.user.id,
                                      pendingTokenFingerprint: String(repeating: "b", count: 64))
    let push = MemoryPushRegistrationStore(PushRegistrationJournal(entries: [entry]))
    try await secrets.write(WireJSON.encoder().encode(Fixture.credentials()), for: account.key)
    try await accounts.save(AccountIndex(accounts: [account], activeID: account.id))
    let transport = RoutedTransport { _, _ in NetworkResponse(status: 401) }
    let identity = IdentityModel(dependencies: AppDependencies(serverProbe: DeletionProbe(), configuration: DeletionPreferences(),
        credentials: secrets, accounts: accounts, transport: { transport }, sockets: DeletionSockets(), pushStore: push))
    await identity.restore(); await identity.notifications.retryCleanup()
    #expect(identity.messaging == nil)
    #expect(try await push.load().entries == [entry])
    #expect(try await push.loadDeletionConfirmations().isEmpty)
    #expect(identity.notifications.error != nil)
}
