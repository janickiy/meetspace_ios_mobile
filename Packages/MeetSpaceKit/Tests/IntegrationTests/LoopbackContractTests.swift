import Foundation
import Testing
import CryptoKit
import MeetSpaceCore
import MeetSpaceAPI
import MeetSpaceStorage
import MeetSpaceRealtime

/// TEST ONLY: explicit loopback ports map production HTTPS/WSS requests to a disposable local Go server.
/// This validates wire contracts, not deployment TLS. No production transport or ATS exceptions are changed.
private final class LoopbackTransport: RequestTransport, Sendable {
    let ports: Set<Int>
    let session: URLSession
    init(ports: Set<Int>) {
        self.ports = ports
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }
    func send(_ request: URLRequest, limit: Int, uploadFile: URL?, progress: TransferProgress?) async throws -> NetworkResponse {
        guard let url = request.url, url.host == "127.0.0.1", ports.contains(url.port ?? 0), url.scheme == "https" else { throw FixtureFailure.scope }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.scheme = "http"
        var local = request; local.url = parts.url
        let result: (Data, URLResponse)
        if let uploadFile { result = try await session.upload(for: local, fromFile: uploadFile) }
        else { result = try await session.data(for: local) }
        guard let response = result.1 as? HTTPURLResponse, result.0.count <= limit else { throw FixtureFailure.response }
        progress?(1)
        return NetworkResponse(status: response.statusCode,
            headers: response.allHeaderFields.reduce(into: [:]) { $0[String(describing: $1.key).lowercased()] = String(describing: $1.value) },
            data: result.0)
    }
    func cancelAll() async { for task in await session.allTasks { task.cancel() } }
}
private final class LocalSocket: NSObject, URLSessionWebSocketDelegate, RealtimeSocket, @unchecked Sendable {
    // Immutable after connect returns; URLSession owns the delegate callbacks.
    private var session: URLSession!
    private var task: URLSessionWebSocketTask!
    private let opened: AsyncThrowingStream<Void, Error>
    private let continuation: AsyncThrowingStream<Void, Error>.Continuation
    private let incoming: AsyncThrowingStream<Data, Error>
    private let incomingContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private var pump: Task<Void, Never>?
    override init() {
        (opened, continuation) = AsyncThrowingStream.makeStream()
        (incoming, incomingContinuation) = AsyncThrowingStream.makeStream()
        super.init()
    }
    static func connect(_ url: URL) async throws -> LocalSocket {
        guard url.host == "127.0.0.1", url.scheme == "wss" else { throw FixtureFailure.scope }
        let socket = LocalSocket()
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!; parts.scheme = "ws"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        socket.session = URLSession(configuration: configuration, delegate: socket, delegateQueue: nil)
        socket.task = socket.session.webSocketTask(with: parts.url!)
        socket.task.resume()
        for try await _ in socket.opened {
            socket.pump = Task {
                do {
                    while !Task.isCancelled {
                        let value = try await socket.task.receive()
                        switch value {
                        case .string(let text): socket.incomingContinuation.yield(Data(text.utf8))
                        case .data(let data): socket.incomingContinuation.yield(data)
                        @unknown default: throw FixtureFailure.response
                        }
                    }
                } catch { socket.incomingContinuation.finish(throwing: error) }
            }
            return socket
        }
        throw FixtureFailure.response
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        continuation.yield(()); continuation.finish()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        continuation.finish(throwing: error ?? FixtureFailure.response)
    }
    func receive() async throws -> Data {
        var iterator = incoming.makeAsyncIterator()
        guard let data = try await iterator.next() else { throw FixtureFailure.response }
        return data
    }
    func close() async { pump?.cancel(); task.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel(); incomingContinuation.finish() }
    func message(_ requestID: UUID) async throws -> ChatMessage {
        let watchdog = Task { try await Task.sleep(for: .seconds(12)); await self.close() }
        defer { watchdog.cancel() }
        while true {
            if let event = try UserEvent.decode(await receive()), let message = event.message, message.clientRequestId == requestID {
                return message
            }
        }
    }
}
private enum FixtureFailure: Error { case scope, response, configuration }
actor TestSecrets: SecureStore {
    private var values: [CredentialKey: Data] = [:]
    func read(_ key: CredentialKey) -> Data? { values[key] }
    func write(_ value: Data, for key: CredentialKey) { values[key] = value }
    func delete(_ key: CredentialKey) { values[key] = nil }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MEETSPACE_TEST_API_PORT"] != nil))
func actualBackendTwoClientsAndFiles() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let api = Int(environment["MEETSPACE_TEST_API_PORT"] ?? ""),
          let objects = Int(environment["MEETSPACE_TEST_OBJECT_PORT"] ?? ""), api > 1024, objects > 1024 else { throw FixtureFailure.configuration }
    let origin = try ServerOrigin("https://127.0.0.1:\(api)")
    let ports: Set<Int> = [api, objects]
    let secrets = TestSecrets()
    let auth = AuthenticationGateway(origin: origin, transport: LoopbackTransport(ports: ports))
    let suffix = UUID().uuidString.lowercased()
    let password = UUID().uuidString
    let emailA = "ios-a-\(suffix)@example.test", emailB = "ios-b-\(suffix)@example.test"
    let userA = try await auth.register(email: emailA, password: password, name: "iOS A")
    let userB = try await auth.register(email: emailB, password: password, name: "iOS B")
    do {
        _ = try await auth.login(email: emailA, password: UUID().uuidString)
        Issue.record("Incorrect password was accepted")
    } catch APIError.httpStatus(let status) { #expect(status == 401) }
    let loginA = try await auth.login(email: emailA, password: password)
    let loginB = try await auth.login(email: emailB, password: password)
    #expect(loginA.account.user.id == userA.id && loginB.account.user.id == userB.id)
    #expect(loginA.credentials.sessionCookie != nil && loginB.credentials.sessionCookie != nil)
    let a = AuthenticatedClient(account: loginA.account, credentials: loginA.credentials, secureStore: secrets, transport: LoopbackTransport(ports: ports))
    let b = AuthenticatedClient(account: loginB.account, credentials: loginB.credentials, secureStore: secrets, transport: LoopbackTransport(ports: ports))
    let ra = MessagingRepository(client: a, downloads: LoopbackTransport(ports: ports))
    let rb = MessagingRepository(client: b, downloads: LoopbackTransport(ports: ports))
    #expect(try await a.currentUser().id == userA.id)
    try await a.refresh(); try await b.refresh()
    let restoredData = try #require(await secrets.read(loginA.account.key))
    let restored = try WireJSON.decoder().decode(SessionCredentials.self, from: restoredData).validated()
    let restoredClient = AuthenticatedClient(account: loginA.account, credentials: restored, secureStore: secrets, transport: LoopbackTransport(ports: ports))
    #expect(try await restoredClient.currentUser().id == userA.id)
    _ = try await restoredClient.close()
    print("PASS real backend: register, login, isolated cookies, refresh, credential restore")

    let direct = try await ra.direct(userID: userB.id)
    #expect(try await rb.direct(userID: userA.id).id == direct.id)
    let socketA = try await LocalSocket.connect(RealtimeEndpoint.url(origin: origin, scope: .user, ticket: ra.ticket().ticket))
    let socketB = try await LocalSocket.connect(RealtimeEndpoint.url(origin: origin, scope: .user, ticket: rb.ticket().ticket))
    // Longer than the server's four-second pong deadline; URLSession must answer control pings.
    try await Task.sleep(for: .seconds(6))
    let draft = try MessageDraft(text: "contract first \(suffix)")
    let sent = try await ra.send(direct.id, draft: draft)
    let receivedA = try await socketA.message(draft.id)
    let receivedB = try await socketB.message(draft.id)
    #expect(receivedA.id == sent.id && receivedB.id == sent.id)
    #expect(try await ra.send(direct.id, draft: draft).id == sent.id)
    let replyDraft = try MessageDraft(text: "contract reply \(suffix)", replyTo: sent.id)
    let reply = try await rb.send(direct.id, draft: replyDraft)
    #expect(reply.replyTo == sent.id)
    #expect(try await socketA.message(replyDraft.id).id == reply.id)
    let edited = try await rb.edit(direct.id, message: reply.id, text: "contract edited \(suffix)")
    #expect(edited.version > reply.version)
    #expect(try await rb.messages(direct.id, search: "edited").items.contains { $0.id == reply.id })
    _ = try await ra.markRead(direct.id, through: reply.id)
    #expect(try await ra.messages(direct.id).unreadCount == 0)
    do { _ = try await ra.edit(direct.id, message: reply.id, text: "not permitted"); Issue.record("Server accepted editing another user's message") }
    catch APIError.httpStatus(let status) { #expect(status == 403) }
    let deleted = try await rb.delete(direct.id, message: reply.id)
    #expect(deleted.isDeleted)
    print("PASS real backend: bidirectional WS after ping deadline, idempotent send, reply/edit/search/read/delete and 403")

    await socketB.close()
    var expected: [UUID] = []
    for number in 0..<53 {
        let message = try await ra.send(direct.id, draft: MessageDraft(text: "offline \(number)"))
        expected.append(message.id)
    }
    let socketB2 = try await LocalSocket.connect(RealtimeEndpoint.url(origin: origin, scope: .user, ticket: rb.ticket().ticket))
    let head = try await rb.messages(direct.id)
    var timeline = MessageTimeline(); timeline.merge(head.items, conversation: direct.id)
    let cursor = try #require(head.nextCursor)
    let older = try await rb.messages(direct.id, before: cursor)
    timeline.merge(older.items, conversation: direct.id); timeline.merge(head.items, conversation: direct.id)
    #expect(expected.allSatisfy { id in timeline.messages.contains { $0.id == id } })
    #expect(Set(timeline.messages.map(\.id)).count == timeline.messages.count)
    let afterReconnect = try MessageDraft(text: "after reconnect")
    let live = try await ra.send(direct.id, draft: afterReconnect)
    timeline.merge([try await socketB2.message(afterReconnect.id), live], conversation: direct.id)
    #expect(timeline.messages.filter { $0.id == live.id }.count == 1)
    print("PASS real backend: disconnected peer catches up through REST pagination; WS/REST merge has no duplicates")

    let group = try await ra.createGroup(id: UUID(), name: "iOS contract", description: "Disposable group", members: [userB.id])
    #expect(try await rb.members(group.id).count == 2)
    _ = try await ra.updateGroup(group.id, name: "Updated iOS", description: "Updated")
    try await ra.changeRole(group.id, user: userB.id, role: "admin")
    #expect(try await rb.conversation(group.id).myRole == "admin")
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("meetspace-contract-\(suffix)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("contract.txt")
    let bytes = Data("MeetSpace iOS real file round trip\n".utf8); try bytes.write(to: file)
    for conversation in [direct, group] {
        let uploadID = UUID()
        let input = UploadInput(id: uploadID, filename: "contract.txt", mimeType: "text/plain", size: bytes.count)
        let attachment = try await ra.upload(conversation.id, input: input, file: file)
        #expect(attachment.size == bytes.count)
        #expect(try await ra.upload(conversation.id, input: input, file: file).id == attachment.id)
        let fileMessage = try await ra.send(conversation.id, draft: MessageDraft(text: "", attachmentIds: [attachment.id]))
        let attached = try #require(fileMessage.attachments.first)
        _ = try await ra.edit(conversation.id, message: fileMessage.id, text: "caption")
        #expect(try await ra.edit(conversation.id, message: fileMessage.id, text: "").text.isEmpty)
        let downloaded = try await rb.download(conversation.id, attachment: attached)
        #expect(downloaded == bytes)
    }
    print("PASS real backend: direct signed download and group authenticated download match uploaded bytes")
    try await ra.transferOwnership(group.id, user: userB.id)
    try await ra.leaveGroup(group.id)
    do { _ = try await ra.messages(group.id); Issue.record("Removed member retained access") }
    catch APIError.httpStatus(let status) { #expect(status == 403 || status == 404) }
    try await rb.deleteGroup(group.id)
    await socketA.close(); await socketB2.close()
    #expect(try await a.close(logout: true))
    #expect(await secrets.read(loginA.account.key) == nil)
    do {
        _ = try await auth.refresh(userID: userA.id, cookie: try #require(loginA.credentials.sessionCookie))
        Issue.record("Revoked session refreshed")
    } catch APIError.httpStatus(let status) { #expect(status == 401) }
    #expect(try await b.currentUser().id == userB.id)
    #expect(try await b.close(logout: true))
    print("PASS real backend: group ownership/leave/delete, logout revokes only selected account")
}
