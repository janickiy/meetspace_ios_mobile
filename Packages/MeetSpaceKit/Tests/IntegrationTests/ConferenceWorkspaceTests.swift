import Foundation
import Testing
import MeetSpaceCore
import MeetSpaceAPI
import MeetSpaceStorage
import MeetSpaceRealtime
import MeetSpaceMedia
@testable import MeetSpaceFeatures

private actor ConferenceWorkspaceGate {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}
private struct ConferenceWorkspaceProbe: ServerProbing {
    func check(_ origin: ServerOrigin) async throws -> ServerVersion { throw APIError.offline }
}
private actor ConferenceWorkspacePreferences: ConfigurationStore {
    func load() -> AppConfiguration { AppConfiguration() }
    func save(_ value: AppConfiguration) {}
}
private struct ConferenceWorkspaceSockets: ConferenceSocketFactory {
    func connect(origin: ServerOrigin, conferenceID: UUID, ticket: String) async throws -> any ConferenceSocket {
        throw APIError.offline
    }
}
private struct ConferenceWorkspaceUserSockets: RealtimeSocketFactory {
    func connect(_ url: URL) async throws -> any RealtimeSocket { throw APIError.offline }
}
private actor ConferenceWorkspaceBackend: RequestTransport {
    let room = UUID(), person = UUID(), guestUser = UUID(), guestPerson = UUID()
    var status: String
    private(set) var requests: [String] = []
    private(set) var guestCleanupUsedGuestBearer = false
    var leaveGate: ConferenceWorkspaceGate?
    var joinGate: ConferenceWorkspaceGate?
    var readGate: ConferenceWorkspaceGate?
    var guestGate: ConferenceWorkspaceGate?
    var failLeave = false
    init(status: String = "active") { self.status = status }
    func blockLeave(_ gate: ConferenceWorkspaceGate?) { leaveGate = gate }
    func blockJoin(_ gate: ConferenceWorkspaceGate) { joinGate = gate }
    func blockRead(_ gate: ConferenceWorkspaceGate) { readGate = gate }
    func blockGuest(_ gate: ConferenceWorkspaceGate) { guestGate = gate }
    func rejectLeave() { failLeave = true }
    func conference() -> Conference { Conference(id: room, ownerId: Fixture.userID, title: "Fixture", status: status) }
    func member(guest: Bool = false, status: String = "joined") -> ConferenceParticipant {
        ConferenceParticipant(id: guest ? guestPerson : person, conferenceId: room,
            userId: guest ? guestUser : Fixture.userID, displayName: "Fixture",
            role: guest ? "participant" : "owner", status: status)
    }
    private func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: WireJSON.encoder().encode(value))
    }
    private func item<T: Encodable>(_ value: T) throws -> NetworkResponse {
        try Fixture.response(["item": object(value)])
    }
    func count(_ suffix: String, method: String = "POST") -> Int {
        requests.filter { $0.hasPrefix(method + " ") && $0.hasSuffix(suffix) }.count
    }
    func send(_ request: URLRequest, limit: Int, uploadFile: URL?, progress: TransferProgress?) async throws -> NetworkResponse {
        let path = request.url!.path, method = request.httpMethod ?? "GET"
        requests.append(method + " " + path)
        if path.hasSuffix("/auth/me") { return try Fixture.response(["user": Fixture.user()]) }
        if path.hasSuffix("/auth/logout") { return NetworkResponse(status: 200) }
        if path.contains("/conference-invites/") {
            if path.hasSuffix("/guest") {
                if let guestGate { await guestGate.wait() }
                var user = Fixture.user(guestUser); user["guestConferenceId"] = room.uuidString
                return try Fixture.response(["accessToken": "fixture-guest", "tokenType": "Bearer", "expiresIn": 3600,
                    "user": user, "item": object(member(guest: true))])
            }
            if path.hasSuffix("/join") { return try item(member(status: status == "scheduled" ? "left" : "joined")) }
            return try Fixture.response(["item": ["id": room.uuidString, "title": "Fixture", "status": status]])
        }
        if path == "/api/v1/conferences" {
            if method == "POST" { return try item(conference()) }
            return try Fixture.response(["items": [object(conference())]])
        }
        if path.hasSuffix("/start") { status = "active"; return try item(conference()) }
        if path.hasSuffix("/join") {
            if let joinGate { await joinGate.wait() }
            return try item(member())
        }
        if path.hasSuffix("/leave") {
            if let leaveGate { await leaveGate.wait() }
            if failLeave { throw APIError.offline }
            let guest = request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-guest"
            guestCleanupUsedGuestBearer = guest
            return try item(member(guest: guest, status: "left"))
        }
        if path == "/api/v1/conferences/" + room.uuidString.lowercased() {
            if let readGate { await readGate.wait() }
            return try item(conference())
        }
        throw APIError.offline
    }
}
@MainActor private func conferenceWorkspace(_ backend: ConferenceWorkspaceBackend) throws -> ConferenceWorkspace {
    let client = AuthenticatedClient(account: try Fixture.account(), credentials: Fixture.credentials(),
        secureStore: TestSecrets(), transport: backend)
    return ConferenceWorkspace(repository: ConferenceRepository(client: client),
        sockets: ConferenceWorkspaceSockets(), makeMedia: { ConferenceMediaFactory.make() })
}
private func conferenceWorkspaceWait(_ condition: @escaping @Sendable () async -> Bool) async throws {
    for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw APIError.timeout
}
@Test @MainActor func conferenceWorkspaceRepeatedDismissPreservesLateLeaveBarrier() async throws {
    let backend = ConferenceWorkspaceBackend(), gate = ConferenceWorkspaceGate()
    let workspace = try conferenceWorkspace(backend), room = await backend.conference()
    await workspace.join(room)
    let previous = try #require(workspace.call)
    await backend.blockLeave(gate)
    await workspace.dismissCall()
    try await conferenceWorkspaceWait { await gate.started }
    await workspace.dismissCall() // A second UI dismissal must not erase the pending departure.
    var finished = false
    let rejoin = Task { await workspace.join(room); finished = true }
    try await Task.sleep(for: .milliseconds(30))
    #expect(workspace.call == nil && workspace.busy && !finished)
    #expect(await backend.count("/join") == 1)
    await gate.release()
    await rejoin.value
    #expect(workspace.call != nil && workspace.call?.id != previous.id && !workspace.busy)
    #expect(await backend.count("/join") == 2)
    await backend.blockLeave(nil)
    await workspace.close()
}

@Test @MainActor func conferenceWorkspaceCannotReplaceAnExistingCallByCreatingAnother() async throws {
    let backend = ConferenceWorkspaceBackend(), workspace = try conferenceWorkspace(backend)
    await workspace.join(await backend.conference())
    let previous = try #require(workspace.call)
    #expect(await workspace.create(title: "Second", waitingRoom: false) == false)
    #expect(workspace.call?.id == previous.id && previous.phase == .prejoin)
    #expect(await backend.count("/conferences") == 0)
    #expect(await backend.count("/leave") == 0)
    await workspace.close()
}

@Test @MainActor func conferenceWorkspaceCloseCompensatesLateJoinWithoutInstallingCall() async throws {
    let backend = ConferenceWorkspaceBackend(), gate = ConferenceWorkspaceGate()
    let workspace = try conferenceWorkspace(backend), room = await backend.conference()
    await backend.blockJoin(gate)
    let joining = Task { await workspace.join(room) }
    try await conferenceWorkspaceWait { await gate.started }
    await workspace.close()
    await gate.release(); await joining.value
    #expect(workspace.call == nil && !workspace.busy && workspace.meetings.isEmpty)
    #expect(await backend.count("/leave") == 1)
}

@Test @MainActor func conferenceWorkspaceClosedInviteCannotStartMeetingAfterLateRead() async throws {
    let backend = ConferenceWorkspaceBackend(status: "scheduled"), gate = ConferenceWorkspaceGate()
    let workspace = try conferenceWorkspace(backend)
    await backend.blockRead(gate)
    let joining = Task { await workspace.joinInvitation(String(repeating: "a", count: 32)) }
    try await conferenceWorkspaceWait { await gate.started }
    await workspace.close()
    await gate.release()
    #expect(await joining.value == false)
    #expect(workspace.call == nil)
    #expect(await backend.count("/start") == 0)
    #expect(await backend.count("/leave") == 1)
}

@Test @MainActor func conferenceWorkspaceOwnerInvitationStartsScheduledMeeting() async throws {
    let backend = ConferenceWorkspaceBackend(status: "scheduled"), workspace = try conferenceWorkspace(backend)
    #expect(await workspace.joinInvitation(String(repeating: "a", count: 32)))
    #expect(workspace.call != nil)
    #expect(await backend.status == "active")
    #expect(await backend.count("/start") == 1)
    await workspace.close()
}

@Test @MainActor func conferenceWorkspaceUncertainDepartureEndsBusyStateAndBlocksReuse() async throws {
    let backend = ConferenceWorkspaceBackend(), workspace = try conferenceWorkspace(backend)
    let room = await backend.conference()
    await workspace.join(room)
    let previous = try #require(workspace.call)
    await backend.rejectLeave()
    await workspace.dismissCall()
    #expect(await previous.awaitDeparture() == false)
    #expect(previous.departureUncertain)
    await workspace.dismissCall()
    await workspace.join(room)
    #expect(workspace.call == nil && !workspace.busy && workspace.error != nil)
    #expect(await backend.count("/join") == 1)
    #expect(await workspace.create(title: "Second", waitingRoom: false) == false)
    #expect(!workspace.busy && workspace.error != nil)
    #expect(await backend.count("/conferences") == 0)
    await workspace.close()
}

@Test @MainActor func conferenceGuestLateJoinCannotReplaceRestoredAccount() async throws {
    let backend = ConferenceWorkspaceBackend(), gate = ConferenceWorkspaceGate()
    let secrets = TestSecrets(), index = MemoryAccountIndexStore(), account = try Fixture.account()
    try await secrets.write(WireJSON.encoder().encode(Fixture.credentials()), for: account.key)
    try await index.save(AccountIndex(accounts: [account], activeID: account.id))
    let app = AppModel(dependencies: AppDependencies(serverProbe: ConferenceWorkspaceProbe(),
        configuration: ConferenceWorkspacePreferences(), credentials: secrets, accounts: index,
        transport: { backend }, sockets: ConferenceWorkspaceUserSockets(), conferenceSockets: ConferenceWorkspaceSockets(),
        media: { ConferenceMediaFactory.make() }))
    await backend.blockGuest(gate)
    let joining = Task { await app.joinGuest(server: Fixture.origin.url.absoluteString,
        invitation: String(repeating: "a", count: 32), name: "Guest") }
    try await conferenceWorkspaceWait { await gate.started }
    await app.restore()
    app.identityChanged()
    #expect(app.identity.messaging?.account.id == account.id)
    await gate.release()
    #expect(await joining.value == false)
    #expect(app.guestConference == nil && !app.guestBusy)
    #expect(app.identity.messaging?.account.id == account.id)
    #expect(await backend.count("/leave") == 1)
    #expect(await backend.guestCleanupUsedGuestBearer)
    await app.identity.logout(account)
}
