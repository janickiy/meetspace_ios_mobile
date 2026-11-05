import Foundation
import Testing
import CryptoKit
import MeetSpaceCore
import MeetSpaceAPI
import MeetSpaceStorage
import MeetSpaceRealtime
@testable import MeetSpaceFeatures

enum Fixture {
    static let userID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let conversationID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    static let messageID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    static let origin = try! ServerOrigin("https://fixture.example")
    static func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    static func user(_ id: UUID = userID) -> [String: Any] {
        ["id": id.uuidString, "email": "\(id.uuidString)@example.test", "displayName": "Fixture", "isAdmin": false,
         "createdAt": "2026-10-01T10:00:00Z", "updatedAt": "2026-10-01T10:00:00.123Z"]
    }
    static func account(_ id: UUID = userID, server: ServerOrigin = origin) throws -> AccountRecord {
        AccountRecord(server: server, user: try WireJSON.decoder().decode(AccountUser.self, from: data(user(id))))
    }
    static func login(_ id: UUID = userID) throws -> NetworkResponse {
        NetworkResponse(status: 200, headers: ["Content-Type": "application/json",
            "Set-Cookie": "meetrix_session=fixture-cookie; Path=/api/v1/auth; HttpOnly; Secure, meetrix_account_\(id.uuidString.lowercased())=fixture-cookie; Path=/api/v1/auth; HttpOnly; Secure"],
            data: try data(["accessToken": "fixture-renewed-token", "tokenType": "Bearer", "expiresIn": 3600, "user": user(id)]))
    }
    static func credentials(expired: Bool = false) -> SessionCredentials {
        SessionCredentials(accessToken: "fixture-token", sessionCookie: "fixture-cookie", expiresAt: Date().addingTimeInterval(expired ? -60 : 3600))
    }
    static func message(id: UUID = messageID, requestID: UUID = UUID(), version: Int = 1, sequence: String = "9007199254740993",
                        conversation: UUID = conversationID, deleted: Bool = false, text: String = "Fixture") throws -> ChatMessage {
        var object: [String: Any] = ["id": id.uuidString, "sequence": sequence, "conversationId": conversation.uuidString,
            "senderId": userID.uuidString, "senderName": "Fixture", "clientRequestId": requestID.uuidString, "text": text,
            "version": version, "createdAt": "2026-10-01T10:00:00Z", "updatedAt": "2026-10-01T10:00:00Z", "attachments": NSNull()]
        if deleted { object["deletedAt"] = "2026-10-01T10:01:00Z" }
        return try WireJSON.decoder().decode(ChatMessage.self, from: data(object))
    }
    static func conversation() throws -> Data {
        try data(["id": conversationID.uuidString, "type": "direct", "peer": ["id": UUID().uuidString, "displayName": "Peer"],
                  "description": "", "updatedAt": "2026-10-01T10:00:00Z", "preview": "", "unreadCount": 0, "notificationsEnabled": true])
    }
    static func response(_ object: [String: Any]) throws -> NetworkResponse {
        NetworkResponse(status: 200, headers: ["content-type": "application/json"], data: try data(object))
    }
}
actor RoutedTransport: RequestTransport {
    typealias Handler = @Sendable (URLRequest, URL?) async throws -> NetworkResponse
    private let handler: Handler
    private(set) var requests: [URLRequest] = []
    init(_ handler: @escaping Handler) { self.handler = handler }
    func send(_ request: URLRequest, limit: Int, uploadFile: URL?, progress: TransferProgress?) async throws -> NetworkResponse {
        requests.append(request)
        return try await handler(request, uploadFile)
    }
}
private struct QuietSockets: RealtimeSocketFactory {
    func connect(_ url: URL) async throws -> any RealtimeSocket {
        try await Task.sleep(for: .seconds(3600)); throw CancellationError()
    }
}

@Test func concurrentUnauthorizedRequestsRefreshOnceAndRetryOnce() async throws {
    let transport = RoutedTransport { request, _ in
        if request.url?.path.hasSuffix("/refresh") == true {
            try await Task.sleep(for: .milliseconds(30)); return try Fixture.login()
        }
        if request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token" { return NetworkResponse(status: 401) }
        return try Fixture.response(["status": "ok", "user": Fixture.user()])
    }
    let secrets = TestSecrets(), account = try Fixture.account()
    let client = AuthenticatedClient(account: account, credentials: Fixture.credentials(), secureStore: secrets, transport: transport)
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<12 { group.addTask { _ = try await client.currentUser() } }
        try await group.waitForAll()
    }
    let requests = await transport.requests
    #expect(requests.filter { $0.url?.path.hasSuffix("/refresh") == true }.count == 1)
    #expect(requests.filter { $0.url?.path.hasSuffix("/me") == true }.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil })
    let refresh = try #require(requests.first { $0.url?.path.hasSuffix("/refresh") == true })
    let object = try JSONSerialization.jsonObject(with: #require(refresh.httpBody)) as? [String: String]
    #expect(object?["userId"] == account.user.id.uuidString.lowercased())
    #expect(await secrets.read(account.key) != nil)
}

@Test func repeated401ExpiresWithoutInfiniteRefresh() async throws {
    let transport = RoutedTransport { request, _ in
        request.url?.path.hasSuffix("/refresh") == true ? try Fixture.login() : NetworkResponse(status: 401)
    }
    let client = AuthenticatedClient(account: try Fixture.account(), credentials: Fixture.credentials(), secureStore: TestSecrets(), transport: transport)
    await #expect(throws: ClientError.sessionExpired) { try await client.currentUser() }
    #expect(await transport.requests.count == 3)
    await #expect(throws: ClientError.sessionExpired) { try await client.currentUser() }
    #expect(await transport.requests.count == 3)
}

@Test func forbiddenAndOfflineDoNotDestroySessions() async throws {
    let secrets = TestSecrets(), account = try Fixture.account()
    try await secrets.write(WireJSON.encoder().encode(Fixture.credentials()), for: account.key)
    for status in [403, 429, 500] {
        let transport = RoutedTransport { _, _ in NetworkResponse(status: status) }
        let client = AuthenticatedClient(account: account, credentials: Fixture.credentials(), secureStore: secrets, transport: transport)
        await #expect(throws: APIError.httpStatus(status)) { try await client.currentUser() }
        #expect(await transport.requests.count == 1)
        #expect(await secrets.read(account.key) != nil)
    }
    let offline = RoutedTransport { _, _ in throw APIError.offline }
    let client = AuthenticatedClient(account: account, credentials: Fixture.credentials(expired: true), secureStore: secrets, transport: offline)
    await #expect(throws: APIError.offline) { try await client.currentUser() }
    #expect(await secrets.read(account.key) != nil)
}

private actor DelayedSecrets: SecureStore {
    var data: Data?
    var writing = false
    private var gate: CheckedContinuation<Void, Never>?
    func read(_ key: CredentialKey) -> Data? { data }
    func write(_ value: Data, for key: CredentialKey) async {
        writing = true
        await withCheckedContinuation { gate = $0 }
        data = value
    }
    func release() { gate?.resume(); gate = nil }
    func delete(_ key: CredentialKey) { data = nil }
}

@Test func logoutDrainsRefreshWriteBeforeKeychainDeletion() async throws {
    let secrets = DelayedSecrets()
    let transport = RoutedTransport { request, _ in
        request.url?.path.hasSuffix("/refresh") == true ? try Fixture.login() : NetworkResponse(status: 200)
    }
    let account = try Fixture.account()
    let client = AuthenticatedClient(account: account, credentials: Fixture.credentials(expired: true), secureStore: secrets, transport: transport)
    let refreshing = Task { try await client.refresh() }
    for _ in 0..<100 {
        if await secrets.writing { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await secrets.writing)
    let closing = Task { try await client.close(logout: true) }
    try await Task.sleep(for: .milliseconds(20)); await secrets.release()
    _ = try? await refreshing.value; _ = try await closing.value
    #expect(await secrets.read(account.key) == nil)
}

@Test func refreshRejectsChangedAccountAndMalformedCookie() async throws {
    let transport = RoutedTransport { _, _ in try Fixture.login(UUID()) }
    let client = AuthenticatedClient(account: try Fixture.account(), credentials: Fixture.credentials(expired: true), secureStore: TestSecrets(), transport: transport)
    await #expect(throws: ClientError.accountMismatch) { try await client.refresh() }
    #expect(throws: (any Error).self) {
        try SessionCookie.extract(headers: ["set-cookie": "meetrix_session=abc; Path=/; Secure"], origin: Fixture.origin, userID: Fixture.userID, fallback: nil)
    }
    #expect(throws: ClientError.missingSession) {
        try SessionCredentials(accessToken: "bad\r\nheader", sessionCookie: nil, expiresAt: Date()).validated()
    }
}

@Test func fiveAccountsPerOriginAndMetadataContainNoSessionSecrets() throws {
    var index = AccountIndex()
    for _ in 0..<5 { try index.upsert(Fixture.account(UUID())) }
    #expect(throws: ClientError.accountLimit) { try index.upsert(Fixture.account(UUID())) }
    try index.upsert(Fixture.account(UUID(), server: ServerOrigin("https://other.example")))
    #expect(try index.validated().accounts.count == 6)
    let encoded = String(decoding: try WireJSON.encoder().encode(index), as: UTF8.self)
    #expect(!encoded.contains("accessToken") && !encoded.contains("sessionCookie"))
    var duplicate = index; duplicate.accounts.append(index.accounts[0])
    #expect(throws: ClientError.storage) { try duplicate.validated() }
}

@Test func versionsAndIntegerSequencesPreventDuplicateOrResurrectedMessages() throws {
    let message = try Fixture.message()
    #expect(message.sequence == 9_007_199_254_740_993)
    let deleted = try Fixture.message(version: 3, deleted: true)
    let edited = try Fixture.message(version: 2)
    var timeline = MessageTimeline()
    timeline.merge([message, message, deleted, edited], conversation: Fixture.conversationID)
    timeline.merge([try Fixture.message(id: UUID(), conversation: UUID())], conversation: Fixture.conversationID)
    #expect(timeline.messages.count == 1 && timeline.messages[0].isDeleted)
    #expect(timeline.messages[0].attachments.isEmpty)
    #expect(throws: (any Error).self) { try Fixture.message(sequence: "9223372036854775808") }
}

@Test func serverCharacterAndFileLimitsAreEnforced() throws {
    try AccountValidation.registration(email: "A@Example.test", password: "a\u{301}a\u{301}a\u{301}a\u{301}", name: "")
    #expect(throws: ClientError.invalidInput) { try MessageDraft(text: String(repeating: "a", count: 4001)) }
    #expect(throws: ClientError.invalidInput) { try MessageDraft(text: "", attachmentIds: Array(repeating: UUID(), count: 6)) }
    #expect(throws: ClientError.invalidInput) { try MessageDraft(text: " \n") }
    #expect(try FilePolicy.mimeType(for: "Отчёт.PDF") == "application/pdf")
    for name in ["../report.pdf", "dir/report.txt", "a\\b.txt", "a..txt", "a\u{202e}.txt"] {
        #expect(throws: ClientError.invalidFileName) { try FilePolicy.validateName(name) }
    }
    #expect(throws: ClientError.unsupportedFile) { try FilePolicy.mimeType(for: "run.exe") }
}

@Test func accountTemporaryFilesAreIsolatedAndBounded() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let a = AccountFileStore(account: try Fixture.account(), baseDirectory: base)
    let b = AccountFileStore(account: try Fixture.account(UUID()), baseDirectory: base)
    let first = try await a.storeDownload(Data("a".utf8), filename: "file.txt")
    let second = try await b.storeDownload(Data("b".utf8), filename: "file.txt")
    #expect(first != second)
    await a.remove(second)
    #expect(FileManager.default.fileExists(atPath: second.path))
    try await a.clear()
    #expect(!FileManager.default.fileExists(atPath: first.path) && FileManager.default.fileExists(atPath: second.path))
    await #expect(throws: ClientError.fileTooLarge) { try await a.storeDownload(Data(), filename: "empty.txt") }
}

@Test func websocketUsesPublishedNamesAndIgnoresUnknownPayloads() throws {
    let message = try Fixture.message()
    let payload = try JSONSerialization.jsonObject(with: WireJSON.encoder().encode(message))
    let event = try Fixture.data(["version": 1, "id": UUID().uuidString, "type": "message.created",
                                 "data": ["conversationId": Fixture.conversationID.uuidString, "message": payload]])
    #expect(try UserEvent.decode(event)?.message?.id == message.id)
    let unknown = try Fixture.data(["version": 1, "type": "user.presence", "data": ["arbitrary": 7]])
    #expect(try UserEvent.decode(unknown) == nil)
    let mismatched = try Fixture.data(["version": 1, "id": UUID().uuidString, "type": "message.updated",
                                      "data": ["conversationId": UUID().uuidString, "message": payload]])
    #expect(throws: (any Error).self) { try UserEvent.decode(mismatched) }
    var dedup = EventDeduplicator(capacity: 2); let id = UUID()
    let first = dedup.accept(id), duplicate = dedup.accept(id)
    #expect(first && !duplicate)
    _ = dedup.accept(UUID()); _ = dedup.accept(UUID())
    let evicted = dedup.accept(id); #expect(evicted)
    #expect(ReconnectPolicy.delay(attempt: 100, jitter: 1) == 30)
}

@Test func authenticatedFileURLCannotEscapeAccountOriginOrConversation() async throws {
    let account = try Fixture.account(), attachmentID = UUID()
    let attachment = try WireJSON.decoder().decode(Attachment.self, from: Fixture.data([
        "id": attachmentID.uuidString, "conversationId": Fixture.conversationID.uuidString, "ownerId": account.user.id.uuidString,
        "filename": "file.txt", "mimeType": "text/plain", "size": 4, "status": "ready", "expiresAt": "2099-01-01T00:00:00Z"]))
    let transport = RoutedTransport { _, _ in
        try Fixture.response(["url": "https://unrelated.example/private", "expiresAt": "2099-01-01T00:00:00Z", "authenticated": true])
    }
    let client = AuthenticatedClient(account: account, credentials: Fixture.credentials(), secureStore: TestSecrets(), transport: transport)
    await #expect(throws: ClientError.scopeMismatch) { try await MessagingRepository(client: client).download(Fixture.conversationID, attachment: attachment) }
    #expect(await transport.requests.count == 1)
}

@Test func signedDownloadNeverReceivesBearerAndRejectsCorruptBytes() async throws {
    let account = try Fixture.account(), bytes = Data("safe".utf8)
    let checksum = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let attachment = try WireJSON.decoder().decode(Attachment.self, from: Fixture.data([
        "id": UUID().uuidString, "conversationId": Fixture.conversationID.uuidString, "ownerId": account.user.id.uuidString,
        "filename": "file.txt", "mimeType": "text/plain", "size": 4, "checksum": checksum, "status": "ready", "expiresAt": "2099-01-01T00:00:00Z"]))
    let transport = RoutedTransport { _, _ in
        try Fixture.response(["url": "https://objects.example/file", "expiresAt": "2099-01-01T00:00:00Z"])
    }
    let objects = RoutedTransport { request, _ in
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil && request.value(forHTTPHeaderField: "Cookie") == nil)
        return NetworkResponse(status: 200, data: Data("evil".utf8))
    }
    let client = AuthenticatedClient(account: account, credentials: Fixture.credentials(), secureStore: TestSecrets(), transport: transport)
    await #expect(throws: APIError.invalidResponse) {
        try await MessagingRepository(client: client, downloads: objects).download(Fixture.conversationID, attachment: attachment)
    }
    #expect(await objects.requests.count == 1)
}
