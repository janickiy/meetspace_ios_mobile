import Foundation
import SwiftUI
import Testing
import MeetSpaceCore
import MeetSpaceAPI
import MeetSpaceMedia
import MeetSpaceBroadcast
import MeetSpaceRealtime
@testable import MeetSpaceFeatures

private actor SessionPermissionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var started = false
    func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
private actor SessionSecrets: SecureStore {
    func read(_ key: CredentialKey) -> Data? { nil }
    func write(_ value: Data, for key: CredentialKey) {}
    func delete(_ key: CredentialKey) {}
}
private enum SessionFixture {
    static let room = UUID(), user = UUID(), person = UUID(), peer = UUID(), connection = UUID()
    static let origin = try! ServerOrigin("https://session.fixture.example")
    static var member: ConferenceParticipant {
        ConferenceParticipant(id: person, conferenceId: room, userId: user, displayName: "Fixture")
    }
    static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: WireJSON.encoder().encode(value))
    }
    static func bytes(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    static func response(_ value: [String: Any]) throws -> NetworkResponse {
        NetworkResponse(status: 200, headers: ["content-type": "application/json"], data: try bytes(value))
    }
    static func event(_ type: String, _ data: [String: Any], reply: UUID? = nil) throws -> Data {
        var value: [String: Any] = ["version": 1, "id": UUID().uuidString, "type": type,
            "conferenceId": room.uuidString, "timestamp": "2026-11-05T12:00:00Z", "data": data]
        if let reply { value["replyTo"] = reply.uuidString }
        return try bytes(value)
    }
    static var policy: [String: Any] {
        ["version": 1, "microphoneBlocked": false, "cameraBlocked": false, "screenBlocked": false, "kicked": false]
    }
    static func roster() throws -> Data {
        var member = try #require(object(self.member) as? [String: Any]); member["online"] = true
        return try event("conference.state", ["connectionId": connection.uuidString,
            "participantId": person.uuidString, "status": "active", "participants": [member]])
    }
    static func repository(transport: SessionTransport = SessionTransport()) throws -> ConferenceRepository {
        let user = try WireJSON.decoder().decode(AccountUser.self, from: bytes([
            "id": Self.user.uuidString, "email": "fixture@example.test", "displayName": "Fixture", "isAdmin": false,
            "createdAt": "2026-11-05T12:00:00Z", "updatedAt": "2026-11-05T12:00:00Z"]))
        let account = AccountRecord(server: origin, user: user)
        let client = AuthenticatedClient(account: account,
            credentials: SessionCredentials(accessToken: "fixture", sessionCookie: nil, expiresAt: Date().addingTimeInterval(3600)),
            secureStore: SessionSecrets(), transport: transport)
        return ConferenceRepository(client: client)
    }
}
private actor SessionTransport: RequestTransport {
    var tickets = 0
    var leaves = 0
    var joins = 0
    var selfReads = 0
    var member: ConferenceParticipant = SessionFixture.member
    var leaveGate: SessionPermissionGate?
    var conferenceStatus = "active"
    var failure: (String, Int)?
    var ice = ICEConfiguration(iceServers: [ICEServer(urls: ["stun:fixture.example:3478"])])
    func blockLeave(_ gate: SessionPermissionGate) { leaveGate = gate }
    func setMember(_ value: ConferenceParticipant) { member = value }
    func setConferenceStatus(_ value: String) { conferenceStatus = value }
    func fail(_ path: String, status: Int) { failure = (path, status) }
    func setICE(_ value: ICEConfiguration) { ice = value }
    func send(_ request: URLRequest, limit: Int, uploadFile: URL?, progress: TransferProgress?) async throws -> NetworkResponse {
        let path = request.url!.path
        if path.hasSuffix("/participants/me") { selfReads += 1 }
        if let (suffix, status) = failure, path.hasSuffix(suffix) { return NetworkResponse(status: status) }
        if path.hasSuffix("/webrtc/config") {
            return NetworkResponse(status: 200, headers: ["content-type": "application/json"], data: try WireJSON.encoder().encode(ice))
        }
        if path.hasSuffix("/ws-ticket") {
            tickets += 1
            return try SessionFixture.response(["ticket": String(repeating: "a", count: 42) + String(tickets), "expiresAt": "2099-11-05T12:00:00Z"])
        }
        if path.hasSuffix("/messages") { return try SessionFixture.response(["items": [], "unreadCount": 0]) }
        if path.hasSuffix("/join") { joins += 1; member = SessionFixture.member }
        if path.hasSuffix("/leave") { leaves += 1; if let leaveGate { await leaveGate.wait() } }
        if path.hasSuffix("/participants/me") || path.hasSuffix("/media") || path.hasSuffix("/leave") || path.hasSuffix("/join") {
            return try SessionFixture.response(["status": "success", "item": SessionFixture.object(member)])
        }
        if path == "/api/v1/conferences/" + SessionFixture.room.uuidString.lowercased() {
            let conference = Conference(id: SessionFixture.room, ownerId: SessionFixture.user, title: "Fixture", status: conferenceStatus)
            return try SessionFixture.response(["status": "success", "item": SessionFixture.object(conference)])
        }
        throw APIError.httpStatus(404)
    }
}
private actor SessionSocket: ConferenceSocket {
    let stream: AsyncThrowingStream<Data, Error>
    let continuation: AsyncThrowingStream<Data, Error>.Continuation
    var sent: [ConferenceEnvelope] = []
    var closes = 0
    init() { (stream, continuation) = AsyncThrowingStream.makeStream() }
    func send(_ data: Data) throws { sent.append(try ConferenceEnvelope.decode(data, conferenceID: SessionFixture.room)) }
    func receive() async throws -> Data {
        var iterator = stream.makeAsyncIterator()
        guard let result = try await iterator.next() else { throw ConferenceSignalError.disconnected(retryable: true) }
        return result
    }
    func close() { closes += 1; continuation.finish() }
    func emit(_ data: Data) { continuation.yield(data) }
    func last(_ type: String) -> ConferenceEnvelope? { sent.last { $0.type == type } }
    func count(_ type: String) -> Int { sent.filter { $0.type == type }.count }
}
private actor SessionSockets: ConferenceSocketFactory {
    var sockets: [SessionSocket] = []
    var calls = 0
    let fail: Bool?
    init(fail: Bool? = nil) { self.fail = fail }
    func connect(origin: ServerOrigin, conferenceID: UUID, ticket: String) throws -> any ConferenceSocket {
        calls += 1
        if let fail { throw ConferenceSignalError.disconnected(retryable: fail) }
        let socket = SessionSocket(); sockets.append(socket); return socket
    }
}
@MainActor private final class SessionEngine: ConferenceMediaEngine {
    let events: AsyncStream<ConferenceMediaEvent>
    let continuation: AsyncStream<ConferenceMediaEvent>.Continuation
    let localVideoTrackID = UUID().uuidString
    var configuration: ConferenceMediaConfiguration?
    var microphone = false, camera = false, closed = false
    var microphoneAllowed = true, cameraAllowed = true, screenAllowed = false
    var screen = false, rollbacks = 0, screenFrames = 0
    var closeCount = 0, offers = 0
    var microphoneGate: SessionPermissionGate?
    init() { (events, continuation) = AsyncStream.makeStream() }
    var localScreenVideoTrackID: String { "fixture-screen" }
    func rollbackLocalOffer() async throws { rollbacks += 1 }
    func setScreenEnabled(_ enabled: Bool) async throws {
        guard !enabled || (screenAllowed && cameraAllowed) else { throw ConferenceMediaError.publicationBlocked }
        screen = enabled; continuation.yield(.screenCaptureState(enabled))
        continuation.yield(.negotiationNeeded)
    }
    func pushScreenFrame(_ frame: ScreenBroadcastFrame) throws { screenFrames += 1 }
    func configure(_ configuration: ConferenceMediaConfiguration) {
        self.configuration = configuration
        microphoneAllowed = configuration.microphoneAllowed; cameraAllowed = configuration.cameraAllowed
    }
    func makeOffer(iceRestart: Bool) throws -> ConferenceMediaOffer {
        guard !closed else { throw CancellationError() }; offers += 1
        return ConferenceMediaOffer(sdp: "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:0\r\na=recvonly\r\n", publications: screen ? [.init(mid: "2", source: "video/screen", trackId: localScreenVideoTrackID)] : [])
    }
    func applyAnswer(_ sdp: String) throws { if closed { throw CancellationError() } }
    func addRemoteCandidate(_ candidate: MeetSpaceMedia.ConferenceICECandidate) {}
    func setPublicationPermissions(microphone: Bool, camera: Bool, screen: Bool) {
        microphoneAllowed = microphone; cameraAllowed = camera; screenAllowed = screen && camera
        if !microphone { self.microphone = false }; if !camera { self.camera = false }
        capture()
    }
    func setMicrophoneEnabled(_ enabled: Bool) async throws {
        if enabled, let microphoneGate { await microphoneGate.wait() }
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        guard !enabled || microphoneAllowed else { throw ConferenceMediaError.publicationBlocked }
        microphone = enabled; capture(); continuation.yield(.negotiationNeeded)
    }
    func setCameraEnabled(_ enabled: Bool) throws {
        guard !closed, !enabled || cameraAllowed else { throw ConferenceMediaError.publicationBlocked }
        camera = enabled; capture(); continuation.yield(.negotiationNeeded)
    }
    func switchCamera() {}
    func setSpeakerEnabled(_ enabled: Bool) {}
    func suspend() { microphone = false; camera = false; capture() }
    func close() { closed = true; microphone = false; camera = false; closeCount += 1; continuation.finish() }
    func videoView(trackID: String, mirrored: Bool) -> AnyView { AnyView(Color.clear) }
    func emit(_ value: ConferenceMediaEvent) { continuation.yield(value) }
    private func capture() { continuation.yield(.captureState(microphone: microphone, camera: camera, frontCamera: true)) }
}
@MainActor private func sessionEventually(_ predicate: @escaping @MainActor () async -> Bool) async throws {
    for _ in 0..<250 {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(4))
    }
    throw APIError.timeout
}
@MainActor private func joinSession(_ session: ConferenceSession, sockets: SessionSockets,
                                   catalog: [[String: Any]] = [], workerICE: [ICEServer]? = nil) async throws -> SessionSocket {
    session.start()
    try await sessionEventually { await sockets.sockets.count == 1 }
    let socket = try #require(await sockets.sockets.first)
    await socket.emit(try SessionFixture.roster())
    try await sessionEventually { await socket.last("media.join") != nil }
    let request = try #require(await socket.last("media.join"))
    var joined: [String: Any] = ["mediaPeerId": SessionFixture.peer.uuidString,
        "maxPeers": 8, "tracks": catalog, "policy": SessionFixture.policy,
        "videoCapture": ["maxWidth": 1280, "maxHeight": 720, "maxFrameRate": 30]]
    if let workerICE { joined["iceServers"] = try SessionFixture.object(workerICE) }
    await socket.emit(try SessionFixture.event("media.joined", joined, reply: request.id))
    try await sessionEventually { await socket.last("media.offer") != nil }
    return socket
}
@MainActor private func answerSession(_ socket: SessionSocket, sdp: String = "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:0\r\n") async throws -> ConferenceEnvelope {
    let offer = try #require(await socket.last("media.offer"))
    struct Offer: Decodable { let negotiationId: String }
    await socket.emit(try SessionFixture.event("media.answer", ["mediaPeerId": SessionFixture.peer.uuidString,
        "negotiationId": offer.payload(Offer.self).negotiationId, "sdp": sdp], reply: offer.id))
    try await sessionEventually { await socket.last("media.ready") != nil }
    return try #require(await socket.last("media.ready"))
}

@Test @MainActor func conferenceSessionWaitsForReadyAcknowledgementAndRTCConnection() async throws {
    let sockets = SessionSockets(), engine = SessionEngine()
    let session = ConferenceSession(repository: try SessionFixture.repository(), title: "Fixture", participant: SessionFixture.member,
        sockets: sockets, makeMedia: { engine })
    let socket = try await joinSession(session, sockets: sockets)
    engine.emit(.connectionState(.connected))
    let ready = try await answerSession(socket)
    #expect(session.phase == .connecting)
    await socket.emit(try SessionFixture.event("ack", ["type": "media.ready"], reply: UUID()))
    try await Task.sleep(for: .milliseconds(15))
    #expect(session.phase == .connecting)
    await socket.emit(try SessionFixture.event("ack", ["type": "media.ready"], reply: ready.id))
    try await sessionEventually { session.phase == .connected }
    #expect(engine.configuration?.iceServers.first?.urls == ["stun:fixture.example:3478"])
    await session.leave()
    #expect(engine.closed && session.videoTracks.isEmpty && session.phase == .ended)
}

@MainActor private final class SessionBroadcast: ScreenBroadcastController {
    let events: AsyncStream<ScreenBroadcastEvent>
    let event: AsyncStream<ScreenBroadcastEvent>.Continuation
    let frames: AsyncStream<ScreenBroadcastFrame>
    let frame: AsyncStream<ScreenBroadcastFrame>.Continuation
    var isAvailable = true
    let extensionBundleID: String? = "fixture.broadcast"
    var sessionID: UUID?
    var stops = 0
    init() {
        (events, event) = AsyncStream.makeStream()
        (frames, frame) = AsyncStream.makeStream()
    }
    func prepare(configuration: ScreenBroadcastConfiguration) { sessionID = UUID() }
    func stop() { stops += 1; sessionID = nil }
    func sendFrame(_ id: UUID, timestamp: Int64 = 1) {
        frame.yield(ScreenBroadcastFrame(sessionID: id, width: 2, height: 2, rowBytes: 8,
            timestampNs: timestamp, pixels: Data(repeating: 0, count: 16)))
    }
}
@MainActor private func acknowledgeLatestScreenOffer(_ socket: SessionSocket) async throws {
    let before = await socket.count("media.ready")
    let offer = try #require(await socket.last("media.offer"))
    struct Offer: Decodable { let negotiationId: String }
    await socket.emit(try SessionFixture.event("media.answer", ["mediaPeerId": SessionFixture.peer.uuidString,
        "negotiationId": offer.payload(Offer.self).negotiationId, "sdp": "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:0\r\n"], reply: offer.id))
    try await sessionEventually { await socket.count("media.ready") > before }
    let ready = try #require(await socket.last("media.ready"))
    await socket.emit(try SessionFixture.event("ack", ["type": "media.ready"], reply: ready.id))
    try await Task.sleep(for: .milliseconds(15))
}
@MainActor private func screenSession() async throws -> (ConferenceSession, SessionEngine, SessionSocket, SessionBroadcast) {
    let sockets = SessionSockets(), engine = SessionEngine(), broadcast = SessionBroadcast()
    let session = ConferenceSession(repository: try SessionFixture.repository(), title: "Fixture", participant: SessionFixture.member,
        sockets: sockets, makeMedia: { engine }, makeBroadcast: { broadcast })
    let socket = try await joinSession(session, sockets: sockets)
    engine.emit(.connectionState(.connected))
    try await acknowledgeLatestScreenOffer(socket)
    try await sessionEventually { session.phase == .connected }
    return (session, engine, socket, broadcast)
}

@Test @MainActor func screenConsentFrameAndServerAckAreAllRequiredAndStopFencesFrames() async throws {
    let (session, engine, socket, broadcast) = try await screenSession()
    await session.prepareScreenShare()
    let id = try #require(broadcast.sessionID)
    #expect(session.screenShareState == .awaitingSystem && !engine.screen)
    broadcast.event.yield(.started(id))
    try await sessionEventually { let count = await socket.count("media.offer"); return engine.screen && count > 1 }
    broadcast.sendFrame(id)
    try await sessionEventually { engine.screenFrames == 1 }
    #expect(!session.screenSharing)
    try await acknowledgeLatestScreenOffer(socket)
    try await sessionEventually { session.screenSharing }
    for _ in 0..<3 {
        let offers = await socket.count("media.offer"), answers = await socket.count("media.ready")
        if offers > answers { try await acknowledgeLatestScreenOffer(socket) }
    }
    let offers = await socket.count("media.offer")
    await session.stopScreenShare()
    #expect(!engine.screen && !session.screenSharing && broadcast.stops == 1)
    broadcast.sendFrame(id, timestamp: 200_000_001)
    try await Task.sleep(for: .milliseconds(20))
    #expect(engine.screenFrames == 1)
    try await sessionEventually { await socket.count("media.offer") > offers }
    try await acknowledgeLatestScreenOffer(socket)
    // An already queued negotiationNeeded may require one final coalesced empty offer.
    if session.screenShareState == .stopping { try await acknowledgeLatestScreenOffer(socket) }
    try await sessionEventually { session.screenShareState == .idle }
    await session.leave()
}

@Test @MainActor func screenConflictRollsBackOnlyScreenAndKeepsConversation() async throws {
    let (session, engine, socket, broadcast) = try await screenSession()
    engine.microphone = true; engine.camera = true
    engine.emit(.captureState(microphone: true, camera: true, frontCamera: true))
    await session.prepareScreenShare()
    let id = try #require(broadcast.sessionID)
    broadcast.event.yield(.started(id))
    try await sessionEventually { let count = await socket.count("media.offer"); return engine.screen && count > 1 }
    let rejected = try #require(await socket.last("media.offer"))
    await socket.emit(try SessionFixture.event("error", ["code": "screen_sharing_conflict", "message": "Screen busy"], reply: rejected.id))
    try await sessionEventually { engine.rollbacks == 1 && !engine.screen && broadcast.stops == 1 }
    #expect(engine.microphone && engine.camera && !engine.closed && session.phase == .connected)
    #expect(session.screenShareError != nil)
    await session.leave()
}

@Test @MainActor func screenStopDuringPendingStartWaitsForRemovalAcknowledgement() async throws {
    let (session, engine, socket, broadcast) = try await screenSession()
    await session.prepareScreenShare()
    let id = try #require(broadcast.sessionID)
    broadcast.event.yield(.started(id))
    try await sessionEventually { let count = await socket.count("media.offer"); return engine.screen && count > 1 }
    let startOffer = try #require(await socket.last("media.offer"))
    await session.stopScreenShare()
    #expect(session.screenShareState == .stopping && !engine.screen && broadcast.stops == 1)
    #expect(!session.canStartScreenShare)
    try await acknowledgeLatestScreenOffer(socket)
    try await sessionEventually { await socket.last("media.offer")?.id != startOffer.id }
    #expect(session.screenShareState == .stopping && !session.screenSharing)
    try await acknowledgeLatestScreenOffer(socket)
    try await sessionEventually { session.screenShareState == .idle }
    await session.leave()
}

@Test @MainActor func screenPolicyAndOldLeaseCannotResumeCapture() async throws {
    let (session, engine, socket, broadcast) = try await screenSession()
    await session.prepareScreenShare()
    let id = try #require(broadcast.sessionID)
    broadcast.event.yield(.started(id))
    try await sessionEventually { engine.screen }
    var policy = SessionFixture.policy; policy["version"] = 2; policy["screenBlocked"] = true
    await socket.emit(try SessionFixture.event("media.policy", ["mediaPeerId": SessionFixture.peer.uuidString, "policy": policy]))
    try await sessionEventually { session.screenBlocked && !engine.screen && broadcast.stops == 1 }
    broadcast.event.yield(.resumed(id)); broadcast.sendFrame(id)
    try await Task.sleep(for: .milliseconds(20))
    #expect(!engine.screen && engine.screenFrames == 0 && !session.canStartScreenShare)
    await session.leave()
}

@Test @MainActor func screenKeepsTransportInBackgroundAndLeaveRevokesLease() async throws {
    let (session, engine, socket, broadcast) = try await screenSession()
    await session.prepareScreenShare()
    let id = try #require(broadcast.sessionID)
    broadcast.event.yield(.started(id))
    try await sessionEventually { engine.screen }
    await session.setForeground(false)
    #expect(!engine.closed && !engine.microphone && !engine.camera)
    await session.leave()
    let closes = await socket.closes
    #expect(engine.closed && broadcast.stops == 1 && closes == 1)
    broadcast.sendFrame(id)
    #expect(engine.screenFrames == 0)
}

@Test @MainActor func conferenceSessionProcessesModerationDuringPendingPermission() async throws {
    let sockets = SessionSockets(), engine = SessionEngine(), gate = SessionPermissionGate()
    engine.microphoneGate = gate
    let session = ConferenceSession(repository: try SessionFixture.repository(), title: "Fixture", participant: SessionFixture.member,
        sockets: sockets, makeMedia: { engine })
    session.wantsMicrophone = true
    let socket = try await joinSession(session, sockets: sockets)
    try await sessionEventually { await gate.started }
    var policy = SessionFixture.policy; policy["version"] = 2; policy["microphoneBlocked"] = true
    await socket.emit(try SessionFixture.event("media.policy", ["mediaPeerId": SessionFixture.peer.uuidString, "policy": policy]))
    try await sessionEventually { session.microphoneBlocked && !engine.microphoneAllowed }
    await gate.release()
    try await Task.sleep(for: .milliseconds(15))
    #expect(!engine.microphone && !session.microphone && !session.wantsMicrophone)
    await session.leave()
}

@Test @MainActor func conferenceSessionBackgroundInvalidatesPendingPermissionAndUsesFreshEngine() async throws {
    let sockets = SessionSockets(), gate = SessionPermissionGate()
    var engines: [SessionEngine] = []
    let session = ConferenceSession(repository: try SessionFixture.repository(), title: "Fixture", participant: SessionFixture.member,
        sockets: sockets, makeMedia: { let engine = SessionEngine(); if engines.isEmpty { engine.microphoneGate = gate }; engines.append(engine); return engine })
    session.wantsMicrophone = true
    _ = try await joinSession(session, sockets: sockets)
    try await sessionEventually { await gate.started }
    await session.setForeground(false)
    #expect(session.phase == .suspended && engines[0].closed)
    await session.setForeground(true)
    try await sessionEventually { await sockets.sockets.count == 2 }
    await gate.release()
    try await Task.sleep(for: .milliseconds(15))
    #expect(!engines[0].microphone && !session.microphone && !session.wantsMicrophone)
    #expect(session.phase == .connecting)
    #expect(await sockets.calls == 2)
    await session.leave()
}

@Test @MainActor func conferenceSessionRetriesAreBoundedAndAuthorizationFailureIsTerminal() async throws {
    for retryable in [true, false] {
        let sockets = SessionSockets(fail: retryable)
        let session = ConferenceSession(repository: try SessionFixture.repository(), title: "Fixture", participant: SessionFixture.member,
            sockets: sockets, makeMedia: { SessionEngine() }, sleep: { _ in try await Task.sleep(for: .milliseconds(1)) })
        session.start()
        try await sessionEventually { session.phase == .failed }
        let calls = await sockets.calls
        #expect(calls == (retryable ? 4 : 1))
        await session.leave()
    }
}

@Test @MainActor func conferenceSessionReadyWithoutICEConnectionTimesOutAndCleansMedia() async throws {
    let sockets = SessionSockets(), engine = SessionEngine()
    let session = ConferenceSession(repository: try SessionFixture.repository(), title: "Fixture", participant: SessionFixture.member,
        sockets: sockets, makeMedia: { engine }, sleep: { seconds in
            try await Task.sleep(for: .seconds(seconds == 30 ? 0.03 : seconds))
        })
    let socket = try await joinSession(session, sockets: sockets)
    let ready = try await answerSession(socket)
    await socket.emit(try SessionFixture.event("ack", ["type": "media.ready"], reply: ready.id))
    try await sessionEventually { engine.closed }
    #expect(session.phase == .reconnecting && !session.microphone && !session.camera)
    await session.leave()
}

@Test @MainActor func conferenceSessionMapsNativeTrackThroughSDPMidAndCatalog() async throws {
    let sockets = SessionSockets(), engine = SessionEngine(), trackID = UUID(), owner = UUID(), remotePeer = UUID()
    let catalog: [[String: Any]] = [["id": trackID.uuidString, "streamId": remotePeer.uuidString.lowercased(),
        "mediaPeerId": remotePeer.uuidString, "participantId": owner.uuidString, "kind": "video", "source": "camera"]]
    let session = ConferenceSession(repository: try SessionFixture.repository(), title: "Fixture", participant: SessionFixture.member,
        sockets: sockets, makeMedia: { engine })
    let socket = try await joinSession(session, sockets: sockets, catalog: catalog)
    let native = ConferenceVideoTrack(id: "native-reused-receiver", mid: "1", streamID: nil, isLocal: false)
    engine.emit(.videoTrackAdded(native))
    #expect(session.videoTracks.isEmpty)
    _ = try await answerSession(socket, sdp: "v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\na=mid:1\r\na=sendonly\r\na=msid:\(remotePeer.uuidString.lowercased()) \(trackID.uuidString.lowercased())\r\n")
    try await sessionEventually { session.videoTracks.count == 1 }
    #expect(session.videoTracks[0].id == native.id && session.participantID(for: native) == owner)
    await socket.emit(try SessionFixture.event("media.tracks", ["mediaPeerId": SessionFixture.peer.uuidString, "revision": 2, "tracks": []]))
    try await sessionEventually { session.videoTracks.isEmpty }
    await session.leave()
}

@Test @MainActor func conferenceSessionLeaveReleasesCaptureBeforeUnresponsiveServer() async throws {
    let transport = SessionTransport(), leaveGate = SessionPermissionGate(), sockets = SessionSockets(), engine = SessionEngine()
    await transport.blockLeave(leaveGate)
    let session = ConferenceSession(repository: try SessionFixture.repository(transport: transport), title: "Fixture", participant: SessionFixture.member,
        sockets: sockets, makeMedia: { engine })
    _ = try await joinSession(session, sockets: sockets)
    await session.leave()
    #expect(session.phase == .ended && engine.closed && session.media == nil)
    try await sessionEventually { await leaveGate.started }
    await leaveGate.release()
}

@Test @MainActor func conferenceSessionKickClosesPendingCaptureWithoutAnotherRESTRead() async throws {
    let sockets = SessionSockets(), engine = SessionEngine(), gate = SessionPermissionGate()
    engine.microphoneGate = gate
    let session = ConferenceSession(repository: try SessionFixture.repository(), title: "Fixture", participant: SessionFixture.member,
        sockets: sockets, makeMedia: { engine })
    session.wantsMicrophone = true
    let socket = try await joinSession(session, sockets: sockets)
    try await sessionEventually { await gate.started }
    let kicked = ConferenceParticipant(id: SessionFixture.person, conferenceId: SessionFixture.room,
        userId: SessionFixture.user, displayName: "Fixture", status: "kicked", mediaPolicyVersion: 2)
    await socket.emit(try SessionFixture.event("participant.kicked", ["participant": SessionFixture.object(kicked)]))
    try await sessionEventually { session.phase == .ended && engine.closed }
    await gate.release()
    try await Task.sleep(for: .milliseconds(15))
    #expect(!engine.microphone && !session.microphone && session.media == nil)
    #expect(await sockets.calls == 1)
}

@Test @MainActor func conferenceSessionUsesAssignedWorkerICEAndKeepsRESTPolicy() async throws {
    let transport = SessionTransport(), sockets = SessionSockets(), engine = SessionEngine()
    await transport.setICE(ICEConfiguration(iceServers: [ICEServer(urls: ["turn:rest.fixture.example:3478"])],
        iceTransportPolicy: "relay", expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970))
    let worker = ICEServer(urls: ["turns:worker.fixture.example:5349"], username: "ephemeral", credential: "fixture")
    let session = ConferenceSession(repository: try SessionFixture.repository(transport: transport), title: "Fixture",
        participant: SessionFixture.member, sockets: sockets, makeMedia: { engine })
    _ = try await joinSession(session, sockets: sockets, workerICE: [worker])
    #expect(engine.configuration?.iceServers == [worker])
    #expect(engine.configuration?.iceTransportPolicy == "relay")
    #expect(await session.awaitDeparture())
}

@Test @MainActor func conferenceSessionDepartureWaitsForRESTCompletion() async throws {
    let transport = SessionTransport(), gate = SessionPermissionGate()
    await transport.blockLeave(gate)
    let session = ConferenceSession(repository: try SessionFixture.repository(transport: transport), title: "Fixture",
        participant: SessionFixture.member)
    await session.leave()
    var completed = false
    let barrier = Task { let result = await session.awaitDeparture(); completed = true; return result }
    try await sessionEventually { await gate.started }
    try await Task.sleep(for: .milliseconds(15))
    #expect(!completed && session.phase == .ended && !session.departureUncertain)
    #expect(await transport.leaves == 1)
    await gate.release()
    #expect(await barrier.value)
    #expect(await session.awaitDeparture())
    #expect(await transport.leaves == 1)
}

@Test @MainActor func conferenceSessionUnresponsiveDepartureStaysUnsafeAfterLateCompletion() async throws {
    let transport = SessionTransport(), gate = SessionPermissionGate()
    await transport.blockLeave(gate)
    let session = ConferenceSession(repository: try SessionFixture.repository(transport: transport), title: "Fixture",
        participant: SessionFixture.member, sleep: { _ in try await Task.sleep(for: .milliseconds(20)) })
    await session.leave()
    try await sessionEventually { await gate.started }
    #expect(await session.awaitDeparture() == false)
    #expect(session.departureUncertain && session.phase == .ended)
    await gate.release()
    try await Task.sleep(for: .milliseconds(15))
    #expect(await session.awaitDeparture() == false)
    #expect(await transport.leaves == 1)
}

@Test @MainActor func conferenceSessionScheduledMembershipRejoinsAfterRoomStarts() async throws {
    let transport = SessionTransport(), sockets = SessionSockets()
    let left = ConferenceParticipant(id: SessionFixture.person, conferenceId: SessionFixture.room,
        userId: SessionFixture.user, displayName: "Fixture", status: "left")
    await transport.setMember(left); await transport.setConferenceStatus("scheduled")
    let session = ConferenceSession(repository: try SessionFixture.repository(transport: transport), title: "Fixture",
        participant: left, sockets: sockets, makeMedia: { SessionEngine() })
    session.start()
    try await sessionEventually { session.phase == .prejoin }
    #expect(await transport.joins == 0)
    #expect(await sockets.calls == 0)
    await transport.setConferenceStatus("active")
    session.start()
    try await sessionEventually { await sockets.calls == 1 }
    #expect(await transport.joins == 1)
    #expect(session.participant.canParticipate)
    #expect(await session.awaitDeparture())
}

@Test @MainActor func conferenceSessionLobbyStopsOnTerminalAuthorizationFailure() async throws {
    let transport = SessionTransport()
    await transport.fail("/participants/me", status: 403)
    let waiting = ConferenceParticipant(id: SessionFixture.person, conferenceId: SessionFixture.room,
        userId: SessionFixture.user, displayName: "Fixture", status: "waiting", admissionState: "waiting")
    let session = ConferenceSession(repository: try SessionFixture.repository(transport: transport), title: "Fixture",
        participant: waiting, sleep: { _ in try await Task.sleep(for: .milliseconds(1)) })
    session.observeLobby()
    try await sessionEventually { session.phase == .failed }
    try await Task.sleep(for: .milliseconds(15))
    #expect(await transport.selfReads == 1)
    await session.leave()
}

@Test @MainActor func conferenceSessionWorkerMediaErrorIsPeerScopedAndTerminal() async throws {
    let sockets = SessionSockets(), engine = SessionEngine()
    let session = ConferenceSession(repository: try SessionFixture.repository(), title: "Fixture", participant: SessionFixture.member,
        sockets: sockets, makeMedia: { engine })
    let socket = try await joinSession(session, sockets: sockets)
    await socket.emit(try SessionFixture.event("media.error", ["mediaPeerId": UUID().uuidString, "code": "unsupported_codec_or_simulcast"]))
    try await Task.sleep(for: .milliseconds(15))
    #expect(session.phase == .connecting && !engine.closed)
    await socket.emit(try SessionFixture.event("media.error", ["mediaPeerId": SessionFixture.peer.uuidString, "code": "unsupported_codec_or_simulcast"]))
    try await sessionEventually { session.phase == .failed && engine.closed }
    #expect(await sockets.calls == 1)
    await session.leave()
}

@Test @MainActor func conferenceSessionDoesNotRetryHTTPValidationFailure() async throws {
    let transport = SessionTransport(), sockets = SessionSockets()
    await transport.fail("/participants/me", status: 422)
    let session = ConferenceSession(repository: try SessionFixture.repository(transport: transport), title: "Fixture",
        participant: SessionFixture.member, sockets: sockets, sleep: { _ in try await Task.sleep(for: .milliseconds(1)) })
    session.start()
    try await sessionEventually { session.phase == .failed }
    try await Task.sleep(for: .milliseconds(15))
    #expect(await transport.selfReads == 1)
    #expect(await sockets.calls == 0)
    await session.leave()
}
