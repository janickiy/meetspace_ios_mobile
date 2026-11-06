import Foundation
import Testing
import MeetSpaceCore
import MeetSpaceAPI
import MeetSpaceStorage
import MeetSpaceRealtime
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
