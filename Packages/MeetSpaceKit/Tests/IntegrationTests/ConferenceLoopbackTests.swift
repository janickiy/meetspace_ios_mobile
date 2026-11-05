import Foundation
import Testing
import MeetSpaceCore
import MeetSpaceAPI

/// Explicit opt-in fixture transport. Production app transports continue requiring HTTPS/WSS.
private final class ConferenceLoopbackHTTP: NSObject, RequestTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private let port: Int
    private var session: URLSession!
    init(port: Int) {
        self.port = port; super.init()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil; config.urlCache = nil
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
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

@Test(.enabled(if: ProcessInfo.processInfo.environment["MEETSPACE_CONFERENCE_API_PORT"] != nil))
func actualBackendConferenceRESTAndGuestScope() async throws {
    let environment = ProcessInfo.processInfo.environment
    let port = try #require(Int(environment["MEETSPACE_CONFERENCE_API_PORT"] ?? ""))
    #expect((1025...65535).contains(port))
    let origin = try ServerOrigin("https://127.0.0.1:\(port)")
    let transport = ConferenceLoopbackHTTP(port: port), secrets = TestSecrets()
    let gateway = AuthenticationGateway(origin: origin, transport: transport)
    let suffix = UUID().uuidString.lowercased(), password = UUID().uuidString
    let mailA = "conference-a-\(suffix)@example.test", mailB = "conference-b-\(suffix)@example.test"
    _ = try await gateway.register(email: mailA, password: password, name: "Conference A")
    _ = try await gateway.register(email: mailB, password: password, name: "Conference B")
    let loginA = try await gateway.login(email: mailA, password: password)
    let loginB = try await gateway.login(email: mailB, password: password)
    let clientA = AuthenticatedClient(account: loginA.account, credentials: loginA.credentials, secureStore: secrets, transport: transport)
    let clientB = AuthenticatedClient(account: loginB.account, credentials: loginB.credentials, secureStore: secrets, transport: transport)
    let a = ConferenceRepository(client: clientA), b = ConferenceRepository(client: clientB)
    let room = try await a.create(title: "iOS SFU contract", waitingRoomEnabled: true)
    #expect(room.ownerId == loginA.account.user.id && room.status == "created")
    #expect(try await a.selfParticipant(room.id).status == "left")
    let owner = try await a.join(room.id)
    #expect(owner.canAdmit && owner.role == "owner")
    #expect(try await a.transition(room.id, action: "start").status == "active")
    let peer = try await b.joinInvite(code: room.inviteCode)
    #expect(peer.canParticipate && peer.admissionState == "admitted")
    #expect(try await a.list().contains { $0.id == room.id })
    #expect(try await a.read(room.id).inviteCode == room.inviteCode)
    let inviteGateway = ConferenceInviteGateway(origin: origin, transport: transport)
    let guestSession = try await inviteGateway.guestJoin(code: room.inviteCode, displayName: "Conference Guest")
    #expect(guestSession.user.guestConferenceId == room.id && guestSession.participant.canParticipate)
    // Actual backend creates role=participant for guests; the JWT user scope identifies them.
    #expect(guestSession.participant.role == "participant")
    let guest = ConferenceRepository(origin: origin, guest: guestSession, transport: transport)
    #expect(try await a.participants(room.id).count == 3)
    await #expect(throws: ClientError.scopeMismatch) { try await guest.read(UUID()) }
    await #expect(throws: ClientError.scopeMismatch) { try await guest.list() }
    _ = try await a.ice(); _ = try await guest.ice()
    _ = try await a.ticket(room.id, clientID: UUID())
    do { _ = try await b.moderate(room.id, participant: owner.id, request: ConferenceModeration(action: "mute", blocked: true)); Issue.record("Non-moderator controlled owner") }
    catch APIError.httpStatus(let status) { #expect(status == 403) }
    #expect(try await a.moderate(room.id, participant: peer.id, request: ConferenceModeration(action: "mute", blocked: true)).microphoneBlocked)
    _ = try await a.moderate(room.id, participant: peer.id, request: ConferenceModeration(action: "mute", blocked: false))
    #expect(try await a.moderate(room.id, participant: peer.id, request: ConferenceModeration(action: "role", role: "co_host")).role == "co_host")
    do { _ = try await b.moderate(room.id, participant: guestSession.participant.id, request: ConferenceModeration(action: "camera", blocked: true)); Issue.record("Co-host controlled camera") }
    catch APIError.httpStatus(let status) { #expect(status == 403) }
    _ = try await a.moderate(room.id, participant: peer.id, request: ConferenceModeration(action: "role", role: "participant"))
    let draft = try MessageDraft(text: "conference message " + suffix)
    let first = try await a.send(room.id, draft: draft)
    #expect(try await a.send(room.id, draft: draft).id == first.id)
    #expect(try await b.messages(room.id).items.contains { $0.id == first.id })
    let reply = try await b.send(room.id, draft: MessageDraft(text: "conference reply", replyTo: first.id))
    #expect(reply.replyTo == first.id)
    #expect(try await b.edit(room.id, message: reply.id, text: "edited conference reply").version > reply.version)
    _ = try await a.markRead(room.id, through: reply.id)
    #expect(try await a.readState(room.id).unreadCount == 0)
    #expect(try await b.messages(room.id, search: "edited").items.contains { $0.id == reply.id })
    #expect(try await b.delete(room.id, message: reply.id).isDeleted)
    _ = try await guest.send(room.id, draft: MessageDraft(text: "guest message"))
    try await guest.reaction(room.id, emoji: "👍")
    _ = try await b.leave(room.id)
    do { _ = try await b.ticket(room.id, clientID: UUID()); Issue.record("Left membership obtained ticket") }
    catch APIError.httpStatus(let status) { #expect(status == 403) }
    #expect(try await b.join(room.id).id == peer.id)
    _ = try await guest.leave(room.id)
    let resumedGuest = try await inviteGateway.guestJoin(code: room.inviteCode, displayName: "Guest resumed", resume: guestSession)
    #expect(resumedGuest.user.id == guestSession.user.id && resumedGuest.participant.id == guestSession.participant.id)
    _ = try await a.transition(room.id, action: "finish")
    _ = try await clientA.close(logout: true); _ = try await clientB.close(logout: true)
    print("PASS real conference REST: create/start/join, actual guest admission, scoped credentials, roles/moderation, chat/reactions, leave/rejoin/finish")
}
