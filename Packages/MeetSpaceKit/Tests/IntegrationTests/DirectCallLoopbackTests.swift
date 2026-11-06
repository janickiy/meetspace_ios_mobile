import Foundation
import Testing
import MeetSpaceCore
import MeetSpaceAPI
import MeetSpaceRealtime

/// Explicit disposable-loopback adapter. Production transport still requires HTTPS/WSS.
private final class CallsLoopbackHTTP: NSObject, RequestTransport, URLSessionTaskDelegate, @unchecked Sendable {
    let port: Int
    private var session: URLSession!
    init(port: Int) {
        self.port = port; super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    func send(_ request: URLRequest, limit: Int, uploadFile: URL?, progress: TransferProgress?) async throws -> NetworkResponse {
        guard let url = request.url, url.host == "127.0.0.1", url.scheme == "https", url.port == port, uploadFile == nil else { throw ClientError.scopeMismatch }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!; parts.scheme = "http"
        var local = request; local.url = parts.url
        let (data, response) = try await session.data(for: local)
        guard let response = response as? HTTPURLResponse, data.count <= limit else { throw APIError.invalidResponse }
        return NetworkResponse(status: response.statusCode, headers: response.allHeaderFields.reduce(into: [:]) {
            $0[String(describing: $1.key).lowercased()] = String(describing: $1.value)
        }, data: data)
    }
    func cancelAll() async { for task in await session.allTasks { task.cancel() } }
}

private final class CallsLoopbackSocket: @unchecked Sendable {
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    init(url: URL, port: Int) throws {
        guard url.scheme == "wss", url.host == "127.0.0.1", url.port == port else { throw ClientError.scopeMismatch }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!; parts.scheme = "ws"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false; configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration)
        socket = session.webSocketTask(with: parts.url!, protocols: ["go-recorder.v1"]); socket.resume()
    }
    func close() { socket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
    func send(_ bytes: Data) async throws { try await socket.send(.string(String(decoding: bytes, as: UTF8.self))) }
    func next() async throws -> Data {
        switch try await socket.receive() {
        case .data(let value): return value
        case .string(let value): return Data(value.utf8)
        @unknown default: throw APIError.invalidResponse
        }
    }
    func call(_ id: UUID, status: DirectCallStatus) async throws -> DirectCall {
        let timeout = Task { try await Task.sleep(for: .seconds(10)); self.close() }
        defer { timeout.cancel() }
        for _ in 0..<100 {
            if let event = try UserEvent.decode(await next()), let call = event.call, call.id == id, call.status == status { return call }
        }
        throw APIError.invalidResponse
    }
    func room(_ id: UUID, type: String) async throws -> ConferenceEnvelope {
        let timeout = Task { try await Task.sleep(for: .seconds(10)); self.close() }
        defer { timeout.cancel() }
        for _ in 0..<100 {
            let event = try ConferenceEnvelope.decode(await next(), conferenceID: id)
            if event.type == "error" { throw APIError.invalidResponse }
            if event.type == type { return event }
        }
        throw APIError.invalidResponse
    }
    func requireServerMembershipClose() async throws {
        let timeout = Task { try await Task.sleep(for: .seconds(10)); self.close() }
        defer { timeout.cancel() }
        do {
            for _ in 0..<100 { _ = try await next() }
            throw APIError.invalidResponse
        } catch {
            guard socket.closeCode == .policyViolation,
                  socket.closeReason.map({ String(decoding: $0, as: UTF8.self) }) == "membership_closed"
            else { throw APIError.invalidResponse }
        }
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MEETSPACE_CALLS_API_PORT"] != nil))
func actualBackendDirectCallsDevicesAndPrivateSFU() async throws {
    let port = try #require(Int(ProcessInfo.processInfo.environment["MEETSPACE_CALLS_API_PORT"] ?? ""))
    #expect((1025...65535).contains(port))
    let origin = try ServerOrigin("https://127.0.0.1:\(port)")
    let transport = CallsLoopbackHTTP(port: port), secrets = TestSecrets()
    let auth = AuthenticationGateway(origin: origin, transport: transport)
    var clients: [AuthenticatedClient] = []
    for index in 0..<4 {
        let email = "calls-\(index)-\(UUID().uuidString.lowercased())@example.test", password = UUID().uuidString
        _ = try await auth.register(email: email, password: password, name: "Calls fixture \(index)")
        let login = try await auth.login(email: email, password: password)
        clients.append(AuthenticatedClient(account: login.account, credentials: login.credentials, secureStore: secrets, transport: transport))
    }
    let clientA = clients[0], clientB = clients[1], clientC = clients[2], clientD = clients[3]
    let a = DirectCallsRepository(client: clientA), b = DirectCallsRepository(client: clientB)
    let c = DirectCallsRepository(client: clientC), d = DirectCallsRepository(client: clientD)
    let chatA = MessagingRepository(client: clientA), chatB = MessagingRepository(client: clientB)
    let mediaA = ConferenceRepository(client: clientA), mediaB = ConferenceRepository(client: clientB)
    let caller = UUID(), callee1 = UUID(), callee2 = UUID(), requestID = UUID()
    let userSocket = try CallsLoopbackSocket(url: RealtimeEndpoint.url(origin: origin, scope: .user, ticket: await chatB.ticket().ticket), port: port)
    defer { userSocket.close() }
    // Let the upgraded connection finish before the first account-wide event.
    try await Task.sleep(for: .milliseconds(100))
    let created = try await a.create(targetUserID: b.userID, clientRequestID: requestID, clientID: caller)
    #expect(created.status == .ringing && created.conferenceId == nil && created.version == 1)
    #expect(try await a.create(targetUserID: b.userID, clientRequestID: requestID, clientID: caller).id == created.id)
    #expect(try await userSocket.call(created.id, status: .ringing).id == created.id)
    await #expect(throws: APIError.httpStatus(409)) { try await a.create(targetUserID: b.userID, clientRequestID: requestID, clientID: UUID()) }
    await #expect(throws: APIError.httpStatus(409)) { try await c.create(targetUserID: b.userID, clientRequestID: UUID(), clientID: UUID()) }
    await #expect(throws: APIError.httpStatus(404)) { try await c.read(created.id) }
    let race = await withTaskGroup(of: DirectCall?.self, returning: [DirectCall].self) { group in
        for device in [callee1, callee2] {
            group.addTask {
                do { return try await b.accept(created.id, clientID: device) }
                catch APIError.httpStatus(let code) { #expect(code == 409); return nil }
                catch { Issue.record("Unexpected accept race error"); return nil }
            }
        }
        var winners: [DirectCall] = []; for await result in group { if let result { winners.append(result) } }; return winners
    }
    #expect(race.count == 1)
    let accepted = try #require(race.first)
    let acceptedClient = try #require(accepted.acceptedByClientId)
    let winner = try #require(UUID(uuidString: acceptedClient))
    let loser = winner == callee1 ? callee2 : callee1
    let room = try #require(accepted.conferenceId)
    #expect(try await userSocket.call(created.id, status: .accepted).acceptedByClientId == winner.uuidString.lowercased())
    #expect(try await b.accept(created.id, clientID: winner).version == accepted.version)
    #expect(try await a.heartbeat(created.id, clientID: caller).version == accepted.version)
    _ = try await b.heartbeat(created.id, clientID: winner)
    await #expect(throws: APIError.httpStatus(409)) { try await b.heartbeat(created.id, clientID: loser) }
    await #expect(throws: APIError.httpStatus(403)) { try await b.end(created.id, clientID: loser) }
    await #expect(throws: APIError.httpStatus(403)) { try await mediaB.ticket(room, clientID: loser) }
    await #expect(throws: APIError.httpStatus(403)) { try await mediaA.ticket(room, clientID: UUID()) }
    #expect(try await mediaA.selfParticipant(room).userId == a.userID)
    #expect(try await mediaB.selfParticipant(room).userId == b.userID)
    for repository in [mediaA, mediaB] {
        await #expect(throws: APIError.httpStatus(404)) { try await repository.read(room) }
        await #expect(throws: APIError.httpStatus(404)) { try await repository.join(room) }
        await #expect(throws: APIError.httpStatus(404)) { try await repository.leave(room) }
        #expect(try await repository.list().allSatisfy { $0.id != room })
    }
    let ownedTicket = try await mediaA.ticket(room, clientID: caller)
    let roomSocket = try CallsLoopbackSocket(url: RealtimeEndpoint.url(origin: origin, scope: .conference(room), ticket: ownedTicket.ticket), port: port)
    defer { roomSocket.close() }
    _ = try await roomSocket.room(room, type: "conference.state")
    try await roomSocket.send(ConferenceEnvelope.command(type: "media.join", conferenceID: room, data: [String: String]()))
    let joined = try await roomSocket.room(room, type: "media.joined")
    #expect(joined.conferenceID == room)
    let winnerTicket = try await mediaB.ticket(room, clientID: winner)
    let calleeSocket = try CallsLoopbackSocket(url: RealtimeEndpoint.url(origin: origin, scope: .conference(room), ticket: winnerTicket.ticket), port: port)
    defer { calleeSocket.close() }
    _ = try await calleeSocket.room(room, type: "conference.state")
    try await calleeSocket.send(ConferenceEnvelope.command(type: "media.join", conferenceID: room, data: [String: String]()))
    _ = try await calleeSocket.room(room, type: "media.joined")
    // Both clients remain connected: the REST end must close their membership and SFU allocation.
    // There is deliberately no client media.leave or socket cancellation before this assertion.
    #expect(try await b.end(created.id, clientID: winner).status == .ended)
    _ = try await userSocket.call(created.id, status: .ended)
    try await roomSocket.requireServerMembershipClose()
    try await calleeSocket.requireServerMembershipClose()
    let activeAAfterEnd = try await a.active(), activeBAfterEnd = try await b.active()
    #expect(activeAAfterEnd == nil && activeBAfterEnd == nil)
    await #expect(throws: APIError.httpStatus(403)) { try await mediaA.ticket(room, clientID: caller) }
    let history = try await chatA.messages(created.conversationId)
    #expect(history.items.contains { $0.call?.id == created.id && $0.call?.status == "ended" })
    let cancelled = try await a.create(targetUserID: b.userID, clientRequestID: UUID(), clientID: caller)
    await #expect(throws: APIError.httpStatus(403)) { try await a.cancel(cancelled.id, clientID: UUID()) }
    #expect(try await a.cancel(cancelled.id, clientID: caller).status == .cancelled)
    let declined = try await a.create(targetUserID: b.userID, clientRequestID: UUID(), clientID: caller)
    #expect(try await b.decline(declined.id, clientID: loser).status == .declined)
    print("PASS real direct calls: idempotency, busy slots, concurrent accept, user WS, both owner-device tickets and SFU media.join, private room restrictions, server membership_closed on end, history/cancel/decline")

    let pushA = NotificationDeviceRepository(client: clientA), pushB = NotificationDeviceRepository(client: clientB)
    #expect(try await pushA.capabilities().push == "http")
    let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let deviceA = try await pushA.register(token: token), deviceB = try await pushB.register(token: token)
    #expect(deviceA.id != deviceB.id) // Confirms the backend's global-token uniqueness gap.
    #expect(try await pushA.register(token: token).id == deviceA.id)
    await #expect(throws: APIError.httpStatus(404)) { try await pushB.revoke(deviceA.id) }
    try await pushA.revoke(deviceA.id)
    #expect(try await pushA.devices().first { $0.id == deviceA.id }?.isActive == false)
    #expect(try await pushB.devices().first { $0.id == deviceB.id }?.isActive == true)
    try await pushB.revoke(deviceB.id)
    print("PASS ordinary push metadata: HTTP capability, encrypted-token registration/idempotency, same-token two-account distinct bindings, scoped revoke; no APNs delivery asserted")

    let missed = try await a.create(targetUserID: b.userID, clientRequestID: UUID(), clientID: caller)
    let expiring = try await c.create(targetUserID: d.userID, clientRequestID: UUID(), clientID: UUID())
    let acceptedExpiring = try await d.accept(expiring.id, clientID: UUID())
    #expect(acceptedExpiring.status == .accepted)
    try await Task.sleep(for: .seconds(46)) // Real 45-second server ring and dual-lease deadlines.
    #expect(try await a.read(missed.id).status == .missed)
    #expect(try await c.read(expiring.id).status == .ended)
    let activeAAfterExpiry = try await a.active(), activeCAfterExpiry = try await c.active()
    #expect(activeAAfterExpiry == nil && activeCAfterExpiry == nil)
    print("PASS real timeouts: 45-second unanswered ring→missed and unrenewed accepted lease→ended")
    for client in clients { _ = try await client.close(logout: true) }
}
