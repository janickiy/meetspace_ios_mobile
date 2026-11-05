import Foundation
import Testing
import MeetSpaceCore
import MeetSpaceAPI
import MeetSpaceStorage
import MeetSpaceRealtime
@testable import MeetSpaceFeatures

private struct WorkspaceProbe: ServerProbing {
    func check(_ origin: ServerOrigin) async throws -> ServerVersion { throw APIError.offline }
}
private actor WorkspacePreferences: ConfigurationStore {
    func load() -> AppConfiguration { AppConfiguration() }
    func save(_ value: AppConfiguration) {}
}
private struct WorkspaceSockets: RealtimeSocketFactory {
    func connect(_ url: URL) async throws -> any RealtimeSocket { throw APIError.offline }
}
private func conversationResponse(_ id: UUID) throws -> NetworkResponse {
    var object = try JSONSerialization.jsonObject(with: Fixture.conversation()) as! [String: Any]
    object["id"] = id.uuidString
    return try Fixture.response(["status": "ok", "item": object])
}
private func pageResponse(_ messages: [ChatMessage] = []) throws -> NetworkResponse {
    let items = try messages.map { try JSONSerialization.jsonObject(with: WireJSON.encoder().encode($0)) }
    return try Fixture.response(["status": "ok", "items": items, "unreadCount": 0])
}
private actor Gate {
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
private func waitFor(_ condition: @escaping @Sendable () async -> Bool) async throws {
    for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw APIError.timeout
}

@Test @MainActor func restoredAccountsSwitchWithoutSharingStateAndLogoutOnlyRemovesSelected() async throws {
    let a = try Fixture.account(), b = try Fixture.account(UUID(), server: ServerOrigin("https://second.example"))
    let credentialsA = Fixture.credentials()
    let credentialsB = SessionCredentials(accessToken: "second-token", sessionCookie: "second-cookie", expiresAt: Date().addingTimeInterval(3600))
    let secrets = TestSecrets(), index = MemoryAccountIndexStore()
    try await secrets.write(WireJSON.encoder().encode(credentialsA), for: a.key)
    try await secrets.write(WireJSON.encoder().encode(credentialsB), for: b.key)
    try await index.save(AccountIndex(accounts: [a, b], activeID: a.id))
    let transport = RoutedTransport { request, _ in
        if request.url?.path.hasSuffix("/me") == true {
            let id = request.url?.host == "second.example" ? b.user.id : a.user.id
            return try Fixture.response(["status": "ok", "user": Fixture.user(id)])
        }
        if request.url?.path.hasSuffix("/logout") == true { return NetworkResponse(status: 200) }
        throw APIError.offline
    }
    let identity = IdentityModel(dependencies: AppDependencies(serverProbe: WorkspaceProbe(), configuration: WorkspacePreferences(),
        credentials: secrets, accounts: index, transport: { transport }, sockets: WorkspaceSockets()))
    await identity.restore()
    let previous = try #require(identity.messaging)
    #expect(previous.account.id == a.id)
    await identity.switchAccount(b)
    #expect(identity.messaging?.account.id == b.id && !previous.active)
    await #expect(throws: CancellationError.self) { try await previous.client.currentUser() }
    let beforeA = await secrets.read(a.key), beforeB = await secrets.read(b.key)
    #expect(beforeA != nil && beforeB != nil)
    await identity.logout(b)
    #expect(identity.messaging == nil && identity.index.accounts.map(\.id) == [a.id])
    let afterA = await secrets.read(a.key), afterB = await secrets.read(b.key)
    #expect(afterA != nil && afterB == nil)
    await identity.switchAccount(a)
    #expect(identity.messaging?.account.id == a.id)
    let requests = await transport.requests.filter { $0.url?.path.hasSuffix("/me") == true }
    #expect(requests.filter { $0.url?.host == "second.example" }.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer second-token" })
    await identity.logout(a)
}

@Test @MainActor func lateHistoryCannotReplaceAnotherSelectedConversation() async throws {
    let a = Fixture.conversationID, b = UUID(), gate = Gate()
    let messageA = try Fixture.message(), messageB = try Fixture.message(id: UUID(), conversation: b)
    let transport = RoutedTransport { request, _ in
        let path = request.url!.path
        let id = path.contains(b.uuidString.lowercased()) ? b : a
        if path.hasSuffix("/messages") {
            if id == a { await gate.wait() }
            return try pageResponse([id == a ? messageA : messageB])
        }
        return try conversationResponse(id)
    }
    let client = AuthenticatedClient(account: try Fixture.account(), credentials: Fixture.credentials(), secureStore: TestSecrets(), transport: transport)
    let model = MessagingModel(client: client, sockets: WorkspaceSockets())
    let first = Task { await model.open(a) }
    try await waitFor { await gate.started }
    await model.open(b)
    await gate.release(); await first.value
    #expect(model.conversation?.id == b)
    #expect(model.timeline.messages.map(\.id) == [messageB.id])
    await model.close(); _ = try await client.close()
}

private actor SendAttempts {
    var identifiers: [UUID] = []
    func accept(_ request: URLRequest) throws -> NetworkResponse {
        let draft = try WireJSON.decoder().decode(MessageDraft.self, from: request.httpBody!)
        identifiers.append(draft.id)
        if identifiers.count == 1 { throw APIError.offline }
        let message = try Fixture.message(requestID: draft.id, text: draft.text)
        return try Fixture.response(["status": "ok", "item": JSONSerialization.jsonObject(with: WireJSON.encoder().encode(message))])
    }
}
@Test @MainActor func uncertainSendRetriesSameRequestAndProducesOneMessage() async throws {
    let attempts = SendAttempts()
    let transport = RoutedTransport { request, _ in
        if request.httpMethod == "POST" { return try await attempts.accept(request) }
        if request.url!.path.hasSuffix("/messages") { return try pageResponse() }
        return try conversationResponse(Fixture.conversationID)
    }
    let client = AuthenticatedClient(account: try Fixture.account(), credentials: Fixture.credentials(), secureStore: TestSecrets(), transport: transport)
    let model = MessagingModel(client: client, sockets: WorkspaceSockets())
    await model.open(Fixture.conversationID)
    model.text = "Retry once"; model.send()
    try await waitFor { await MainActor.run { model.pending.first?.failed == true } }
    let id = try #require(model.pending.first?.id); model.retry(id)
    try await waitFor { await MainActor.run { model.pending.isEmpty } }
    #expect(await attempts.identifiers == [id, id])
    #expect(model.timeline.messages.count == 1 && model.timeline.messages[0].clientRequestId == id)
    await model.close(); _ = try await client.close()
}

@Test @MainActor func cancellingUploadStopsBeforeFinalizeAndRemovesStagedFile() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let file = base.appendingPathComponent("sample.txt"); try Data("sample".utf8).write(to: file)
    let attachmentID = UUID(), account = try Fixture.account()
    let transport = RoutedTransport { request, _ in
        if request.url!.path.hasSuffix("/init") {
            return try Fixture.response(["item": [
                "id": attachmentID.uuidString, "conversationId": Fixture.conversationID.uuidString, "ownerId": account.user.id.uuidString,
                "filename": "sample.txt", "mimeType": "text/plain", "size": 6, "status": "pending", "expiresAt": "2099-01-01T00:00:00Z"],
                "uploadUrl": "/api/v1/conversations/\(Fixture.conversationID.uuidString.lowercased())/attachments/\(attachmentID.uuidString.lowercased())/content"])
        }
        if request.url!.path.hasSuffix("/content") {
            try await Task.sleep(for: .seconds(60))
            return NetworkResponse(status: 200)
        }
        if request.url!.path.hasSuffix("/messages") { return try pageResponse() }
        return try conversationResponse(Fixture.conversationID)
    }
    let client = AuthenticatedClient(account: account, credentials: Fixture.credentials(), secureStore: TestSecrets(), transport: transport)
    let model = MessagingModel(client: client, sockets: WorkspaceSockets(), files: AccountFileStore(account: account, baseDirectory: base))
    await model.open(Fixture.conversationID)
    await model.importFiles([file])
    try await waitFor { await transport.requests.contains { $0.url?.path.hasSuffix("/content") == true } }
    let upload = try #require(model.uploads.first)
    await model.cancelUpload(upload.id)
    #expect(model.uploads.isEmpty && !FileManager.default.fileExists(atPath: upload.file.url.path))
    #expect(await transport.requests.allSatisfy { $0.url?.path.hasSuffix("/finalize") != true })
    await model.close(); _ = try await client.close()
}
