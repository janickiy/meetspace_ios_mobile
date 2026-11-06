import Foundation
import SwiftUI
import Testing
import MeetSpaceCore
import MeetSpaceAPI
import MeetSpaceMedia
import MeetSpaceRealtime
import MeetSpaceCalling
@testable import MeetSpaceFeatures

private enum CallFixture {
    static let user = UUID(), peer = UUID(), device = UUID(), room = UUID(), member = UUID(), call = UUID(), conversation = UUID()
    static let origin = try! ServerOrigin("https://direct-call.fixture.example")
    static let person = DirectCallPeer(id: peer, displayName: "Собеседник")
    static func value(_ status: DirectCallStatus = .ringing, version: Int64 = 1, incoming: Bool = false,
                      device: UUID = CallFixture.device, acceptedDevice: UUID = CallFixture.device) -> DirectCall {
        let start = Date().addingTimeInterval(-60), accepted = status == .accepted || status == .ended
        return DirectCall(id: call, conversationId: conversation, conferenceId: accepted ? room : nil,
            callerUserId: incoming ? peer : user, calleeUserId: incoming ? user : peer,
            callerClientId: device.uuidString.lowercased(), acceptedByClientId: accepted ? acceptedDevice.uuidString.lowercased() : nil,
            status: status, version: version, createdAt: start, expiresAt: start.addingTimeInterval(180),
            acceptedAt: accepted ? start.addingTimeInterval(10) : nil, endedAt: status.isTerminal ? Date() : nil,
            caller: DirectCallPeer(id: incoming ? peer : user, displayName: incoming ? "Собеседник" : "Вы"),
            callee: DirectCallPeer(id: incoming ? user : peer, displayName: incoming ? "Вы" : "Собеседник"))
    }
    static var membership: ConferenceParticipant {
        ConferenceParticipant(id: member, conferenceId: room, userId: user, displayName: "Вы")
    }
    static func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    static func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: WireJSON.encoder().encode(value)) }
    static func event(_ type: String, _ value: [String: Any], reply: UUID? = nil) throws -> Data {
        var data: [String: Any] = ["version": 1, "id": UUID().uuidString, "conferenceId": room.uuidString,
            "timestamp": "2026-11-06T12:00:00Z", "type": type, "data": value]
        if let reply { data["replyTo"] = reply.uuidString }; return try json(data)
    }
    static func conference(_ transport: CallConferenceTransport = CallConferenceTransport()) throws -> ConferenceRepository {
        let user = try WireJSON.decoder().decode(AccountUser.self, from: json(["id": Self.user.uuidString,
            "email": "fixture@example.test", "displayName": "Вы", "isAdmin": false,
            "createdAt": "2026-11-06T12:00:00Z", "updatedAt": "2026-11-06T12:00:00Z"]))
        return ConferenceRepository(client: AuthenticatedClient(account: AccountRecord(server: origin, user: user),
            credentials: SessionCredentials(accessToken: "fixture", sessionCookie: nil, expiresAt: Date().addingTimeInterval(3600)),
            secureStore: CallSecrets(), transport: transport))
    }
}
private actor CallSecrets: SecureStore {
    func read(_ key: CredentialKey) -> Data? { nil }
    func write(_ value: Data, for key: CredentialKey) {}
    func delete(_ key: CredentialKey) {}
}
private actor CallGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var started = false
    func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
private final class CallClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock() }
}
private actor CallService: DirectCallsServing {
    nonisolated let origin = CallFixture.origin
    nonisolated let userID = CallFixture.user
    var value: DirectCall?
    var createIDs: [UUID] = []
    var createsFail = 0
    var cancelFails = false
    var accepts = 0, cancels = 0, ends = 0, declines = 0, heartbeats = 0, reads = 0
    var acceptGate: CallGate?
    var createReplyGate: CallGate?
    var heartbeatGate: CallGate?
    init(_ value: DirectCall? = nil) { self.value = value }
    func set(_ value: DirectCall?) { self.value = value }
    func failCreate() { createsFail = 1 }
    func failCancel() { cancelFails = true }
    func blockAccept(_ gate: CallGate) { acceptGate = gate }
    func blockCreateReply(_ gate: CallGate) { createReplyGate = gate }
    func blockHeartbeat(_ gate: CallGate) { heartbeatGate = gate }
    func create(targetUserID: UUID, clientRequestID: UUID, clientID: UUID) async throws -> DirectCall {
        createIDs.append(clientRequestID)
        if createsFail > 0 { createsFail -= 1; throw APIError.timeout }
        let call = CallFixture.value(device: clientID); value = call
        if let createReplyGate { await createReplyGate.wait() }
        return call
    }
    func active() -> DirectCall? { value?.isActive == true ? value : nil }
    func read(_ id: UUID) throws -> DirectCall { reads += 1; guard let value else { throw APIError.httpStatus(404) }; return value }
    func accept(_ id: UUID, clientID: UUID) async -> DirectCall {
        accepts += 1
        if let acceptGate { await acceptGate.wait() }
        let call = CallFixture.value(.accepted, version: 2, incoming: true, acceptedDevice: clientID); value = call; return call
    }
    func decline(_ id: UUID, clientID: UUID) -> DirectCall {
        declines += 1; let call = CallFixture.value(.declined, version: 3, incoming: true); value = call; return call
    }
    func cancel(_ id: UUID, clientID: UUID) throws -> DirectCall {
        cancels += 1
        if cancelFails { throw APIError.timeout }
        let call = CallFixture.value(.cancelled, version: 3, device: clientID); value = call; return call
    }
    func end(_ id: UUID, clientID: UUID) -> DirectCall {
        ends += 1; let call = CallFixture.value(.ended, version: 3, incoming: value?.calleeUserId == userID, device: clientID, acceptedDevice: clientID); value = call; return call
    }
    func heartbeat(_ id: UUID, clientID: UUID) async throws -> DirectCall {
        heartbeats += 1
        if let heartbeatGate { await heartbeatGate.wait() }
        return try read(id)
    }
}
@MainActor private final class CallSystem: SystemCalling {
    let events: AsyncStream<SystemCallEvent>
    let continuation: AsyncStream<SystemCallEvent>.Continuation
    let isAvailable: Bool
    var incoming: [UUID] = [], starts: [UUID] = [], completed: [(UUID, Bool)] = []
    var ended: [(UUID, SystemCallEndReason)] = [], connected: [UUID] = []
    var invalidated = false, failStart = false
    var startGate: CallGate?
    var lastAnswer: SystemCallAction?
    init(available: Bool = true) { isAvailable = available; (events, continuation) = AsyncStream.makeStream() }
    func reportIncoming(_ descriptor: SystemCallDescriptor, completion: @escaping @Sendable (Result<Void, SystemCallingError>) -> Void) {
        incoming.append(descriptor.id); completion(.success(()))
    }
    func requestStart(_ descriptor: SystemCallDescriptor) async throws {
        if let startGate { await startGate.wait() }
        if failStart { throw SystemCallingError.requestRejected }
        starts.append(descriptor.id); emit(.action(action(.start, id: descriptor.id)))
    }
    func requestAnswer(callID: UUID) {
        let value = action(.answer, id: callID); lastAnswer = value; emit(.action(value))
    }
    func requestEnd(callID: UUID) { emit(.action(action(.end, id: callID))) }
    func requestMuted(_ muted: Bool, callID: UUID) { emit(.action(action(.setMuted(muted), id: callID))) }
    func completeAction(id: UUID, succeeded: Bool) { completed.append((id, succeeded)) }
    func reportConnecting(callID: UUID, at date: Date?) {}
    func reportConnected(callID: UUID, at date: Date?) { connected.append(callID) }
    func reportEnded(callID: UUID, reason: SystemCallEndReason, at date: Date?) { ended.append((callID, reason)) }
    func updateCall(_ descriptor: SystemCallDescriptor) {}
    func invalidate() { invalidated = true }
    func action(_ kind: SystemCallAction.Kind, id: UUID = CallFixture.call) -> SystemCallAction {
        SystemCallAction(id: UUID(), callID: id, kind: kind, deadline: Date().addingTimeInterval(30))
    }
    func emit(_ event: SystemCallEvent) { continuation.yield(event) }
}
private actor CallConferenceTransport: RequestTransport {
    var paths: [String] = []
    var ticketClients: [String] = []
    func send(_ request: URLRequest, limit: Int, uploadFile: URL?, progress: TransferProgress?) throws -> NetworkResponse {
        let path = request.url!.path; paths.append(path)
        let value: Any
        if path.hasSuffix("/participants/me") { value = ["item": try CallFixture.object(CallFixture.membership)] }
        else if path.hasSuffix("/webrtc/config") { value = ["iceServers": [["urls": ["stun:fixture.example:3478"]]], "iceTransportPolicy": "all"] }
        else if path.hasSuffix("/ws-ticket") {
            let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String])
            ticketClients.append(try #require(body["clientId"]))
            value = ["ticket": String(repeating: "a", count: 43), "expiresAt": "2099-11-06T12:00:00Z"]
        } else if path.hasSuffix("/media") { value = ["item": try CallFixture.object(CallFixture.membership)] }
        else { throw APIError.httpStatus(404) }
        return NetworkResponse(status: 200, headers: ["content-type": "application/json"], data: try CallFixture.json(value))
    }
}
private actor CallSocket: ConferenceSocket {
    let stream: AsyncThrowingStream<Data, Error>
    let continuation: AsyncThrowingStream<Data, Error>.Continuation
    let peer = UUID()
    var ready: UUID?
    var closes = 0
    init() { (stream, continuation) = AsyncThrowingStream.makeStream() }
    func begin() throws {
        continuation.yield(try CallFixture.event("conference.state", ["connectionId": UUID().uuidString,
            "participantId": CallFixture.member.uuidString, "status": "active", "participants": [CallFixture.object(CallFixture.membership)]]))
    }
    func send(_ data: Data) throws {
        let event = try ConferenceEnvelope.decode(data, conferenceID: CallFixture.room)
        if event.type == "media.join" {
            continuation.yield(try CallFixture.event("media.joined", ["mediaPeerId": peer.uuidString,
                "maxPeers": 2, "tracks": [], "videoCapture": ["maxWidth": 1280, "maxHeight": 720, "maxFrameRate": 30]], reply: event.id))
        } else if event.type == "media.offer" {
            struct Offer: Decodable { let negotiationId: UUID }
            continuation.yield(try CallFixture.event("media.answer", ["mediaPeerId": peer.uuidString,
                "negotiationId": event.payload(Offer.self).negotiationId.uuidString,
                "sdp": "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:0\r\n"], reply: event.id))
        } else if event.type == "media.ready" { ready = event.id }
    }
    func acknowledge() throws {
        continuation.yield(try CallFixture.event("ack", ["type": "media.ready"], reply: #require(ready)))
    }
    func receive() async throws -> Data {
        var iterator = stream.makeAsyncIterator()
        guard let value = try await iterator.next() else { throw RealtimeError.disconnected }; return value
    }
    func close() { closes += 1; continuation.finish() }
}
private actor CallSockets: ConferenceSocketFactory {
    var created: [CallSocket] = []
    func connect(origin: ServerOrigin, conferenceID: UUID, ticket: String) async throws -> any ConferenceSocket {
        let socket = CallSocket(); created.append(socket); try await socket.begin(); return socket
    }
}
@MainActor private final class CallEngine: ConferenceMediaEngine {
    let events: AsyncStream<ConferenceMediaEvent>
    let continuation: AsyncStream<ConferenceMediaEvent>.Continuation
    let localVideoTrackID = "fixture-camera"
    var microphone = false, camera = false, closed = false
    var cameraFailures = 0, cameraAttempts = 0
    var configuration: ConferenceMediaConfiguration?
    init() { (events, continuation) = AsyncStream.makeStream() }
    func configure(_ configuration: ConferenceMediaConfiguration) { self.configuration = configuration }
    func makeOffer(iceRestart: Bool) -> ConferenceMediaOffer { ConferenceMediaOffer(sdp: "v=0\r\n", publications: []) }
    func applyAnswer(_ sdp: String) { continuation.yield(.connectionState(.connected)) }
    func addRemoteCandidate(_ candidate: ConferenceICECandidate) {}
    func setPublicationPermissions(microphone: Bool, camera: Bool) {}
    func setMicrophoneEnabled(_ enabled: Bool) { microphone = enabled; capture() }
    func setCameraEnabled(_ enabled: Bool) throws {
        if enabled {
            cameraAttempts += 1
            if cameraFailures > 0 { cameraFailures -= 1; throw ConferenceMediaError.cameraPermissionDenied }
        }
        camera = enabled; capture()
    }
    func switchCamera() {}
    func setSpeakerEnabled(_ enabled: Bool) throws {}
    func suspend() { microphone = false; camera = false; capture() }
    func close() { closed = true; microphone = false; camera = false; continuation.finish() }
    func videoView(trackID: String, mirrored: Bool) -> AnyView { AnyView(Color.clear) }
    func capture() { continuation.yield(.captureState(microphone: microphone, camera: camera, frontCamera: true)) }
}
@MainActor private func callEventually(_ predicate: @escaping @MainActor () async -> Bool) async throws {
    for _ in 0..<300 { if await predicate() { return }; try await Task.sleep(for: .milliseconds(4)) }
    throw APIError.timeout
}
@MainActor private func coordinator(_ service: CallService, system: CallSystem, sockets: CallSockets = CallSockets(),
    transport: CallConferenceTransport = CallConferenceTransport(), engine: CallEngine = CallEngine(),
    canUse: @escaping @MainActor () -> Bool = { true }, now: @escaping @Sendable () -> Date = { Date() }) throws -> DirectCallCoordinator {
    DirectCallCoordinator(repository: service, conferenceRepository: try CallFixture.conference(transport), system: system,
        sockets: sockets, makeMedia: { engine }, canUseMedia: canUse, clientID: CallFixture.device, now: now)
}

@Test @MainActor func directCallRetriesUnknownCreateWithSameIdempotencyKey() async throws {
    let service = CallService(), system = CallSystem(), calls = try coordinator(service, system: system)
    await service.failCreate()
    await calls.startOutgoing(peer: CallFixture.person)
    #expect(calls.uncertain && calls.pendingPeer != nil)
    await calls.startOutgoing(peer: CallFixture.person)
    let keys = await service.createIDs
    #expect(keys.count == 2 && keys[0] == keys[1])
    #expect(!calls.uncertain && calls.currentCall?.status == .ringing)
    await calls.close(); #expect(!system.invalidated)
}

@Test @MainActor func directCallReconcilesLostCreateResponseIntoOneSystemStartBeforeMedia() async throws {
    let service = CallService(), system = CallSystem(), sockets = CallSockets()
    let calls = try coordinator(service, system: system, sockets: sockets)
    await service.failCreate(); await calls.startOutgoing(peer: CallFixture.person)
    #expect(calls.uncertain && calls.pendingPeer != nil && system.starts.isEmpty)
    await service.set(CallFixture.value(.accepted, version: 2)); await calls.reconcile()
    try await callEventually { await sockets.created.count == 1 }
    #expect(system.starts == [CallFixture.call])
    #expect(!calls.uncertain && calls.pendingPeer == nil)
    await calls.reconcile()
    #expect(system.starts.count == 1)
    await calls.close()
}

@Test @MainActor func directCallRejectsMeetingConflictBeforeCreatingOrAccepting() async throws {
    let service = CallService(CallFixture.value(incoming: true)), system = CallSystem()
    let calls = try coordinator(service, system: system, canUse: { false })
    await calls.startOutgoing(peer: CallFixture.person)
    #expect(await service.createIDs.isEmpty)
    await calls.reconcile(); await calls.answer()
    #expect(await service.accepts == 0)
    #expect(calls.error != nil)
    await calls.close()
}

@Test @MainActor func directCallIncomingMultiDeviceAcceptanceClosesOnlyLocalCallKit() async throws {
    let service = CallService(CallFixture.value(incoming: true)), system = CallSystem(), sockets = CallSockets()
    let calls = try coordinator(service, system: system, sockets: sockets)
    await calls.reconcile()
    #expect(system.incoming == [CallFixture.call])
    await service.set(CallFixture.value(.accepted, version: 2, incoming: true, acceptedDevice: UUID()))
    await calls.reconcile()
    #expect(calls.otherDevice && calls.mediaSession == nil)
    #expect(system.ended.contains { $0.1 == .answeredElsewhere })
    #expect(await sockets.created.isEmpty)
    await calls.end()
    #expect(await service.ends == 0)
    await calls.close()
}

@Test @MainActor func directCallDoesNotTrustSocketDTOAndRejectsOlderRESTVersion() async throws {
    let service = CallService(CallFixture.value(.cancelled, version: 4)), system = CallSystem()
    let calls = try coordinator(service, system: system)
    await calls.receive(CallFixture.value(.accepted, version: 9))
    #expect(calls.mediaSession == nil && calls.currentCall == nil)
    await service.set(CallFixture.value(version: 3)); await calls.reconcile()
    await service.set(CallFixture.value(.cancelled, version: 4)); await calls.reconcile()
    #expect(calls.currentCall?.status == .cancelled)
    await service.set(CallFixture.value(version: 2)); await calls.reconcile()
    #expect(calls.currentCall?.status == .cancelled)
    await calls.close()
}

@Test @MainActor func directCallStartRejectionCancelsOwnedRing() async throws {
    let service = CallService(), system = CallSystem(); system.failStart = true
    let calls = try coordinator(service, system: system)
    await calls.startOutgoing(peer: CallFixture.person)
    #expect(await service.cancels == 1)
    #expect(calls.currentCall?.status == .cancelled && calls.mediaSession == nil)
    await calls.close()
}

@Test @MainActor func directCallStartRejectionPreservesUnknownServerCancellation() async throws {
    let service = CallService(), system = CallSystem(); system.failStart = true
    await service.failCancel()
    let calls = try coordinator(service, system: system)
    await calls.startOutgoing(peer: CallFixture.person)
    #expect(await service.cancels == 1)
    #expect(calls.uncertain && calls.ending && calls.pendingPeer == nil)
    #expect(calls.currentCall?.status == .ringing && calls.mediaSession == nil)
    await calls.reconcile()
    #expect(calls.uncertain && calls.ending && system.starts.isEmpty)
    await calls.close()
}

@Test @MainActor func directCallPOSTAndReconciliationAwaitTheSameRejectedSystemStart() async throws {
    let service = CallService(), system = CallSystem(), createReply = CallGate(), systemReply = CallGate()
    await service.blockCreateReply(createReply)
    system.failStart = true; system.startGate = systemReply
    let calls = try coordinator(service, system: system)
    var returned = false
    var returnedStatus: DirectCallStatus?
    let creation = Task { @MainActor in
        await calls.startOutgoing(peer: CallFixture.person)
        returnedStatus = calls.currentCall?.status; returned = true
    }
    try await callEventually { await createReply.started }
    // The server has committed; the startup poll owns a blocked CallKit request before POST returns.
    let reconciliation = Task { await calls.reconcile() }
    try await callEventually { await systemReply.started }
    await createReply.release()
    // Let the released POST continuation run while the explicit system gate stays closed.
    // A completed create here would skip the lifecycle result that it promises its caller.
    for _ in 0..<30 { await Task.yield() }
    #expect(!returned && calls.busy)
    await systemReply.release()
    await creation.value; await reconciliation.value
    #expect(returnedStatus == .cancelled)
    #expect(await service.cancels == 1)
    #expect(calls.currentCall?.status == .cancelled && calls.mediaSession == nil)
    await calls.close()
}

@Test @MainActor func directCallAnswerWaitsForSFUReadyWithoutWaitingForSystemAudioActivation() async throws {
    let service = CallService(CallFixture.value(incoming: true)), system = CallSystem()
    let sockets = CallSockets(), transport = CallConferenceTransport(), engine = CallEngine()
    let calls = try coordinator(service, system: system, sockets: sockets, transport: transport, engine: engine)
    await calls.reconcile(); await calls.answer()
    try await callEventually { await sockets.created.first?.ready != nil }
    let action = try #require(system.lastAnswer), socket = try #require(await sockets.created.first)
    #expect(!system.completed.contains { $0.0 == action.id })
    try await socket.acknowledge()
    try await callEventually { system.completed.contains { $0.0 == action.id && $0.1 } }
    #expect(calls.mediaSession?.phase == .connected)
    #expect(await transport.ticketClients == [CallFixture.device.uuidString.lowercased()])
    #expect(engine.configuration?.audioActivation == .callKit)
    #expect(!engine.camera)
    await calls.setForeground(false)
    #expect(!engine.closed && calls.mediaSession?.phase == .connected)
    await calls.end()
    try await callEventually { await service.ends == 1 }
    #expect(engine.closed)
    let paths = await transport.paths
    #expect(!paths.contains { $0.hasSuffix("/join") || $0.hasSuffix("/leave") || $0.hasSuffix("/messages") })
    #expect(!paths.contains("/api/v1/conferences/" + CallFixture.room.uuidString.lowercased()))
    await calls.close()
}

@Test @MainActor func directCallLateAcceptAfterAccountCloseNeverCreatesMediaAndCompensates() async throws {
    let gate = CallGate(), service = CallService(CallFixture.value(incoming: true)), system = CallSystem(), sockets = CallSockets()
    await service.blockAccept(gate)
    let calls = try coordinator(service, system: system, sockets: sockets)
    await calls.reconcile(); await calls.answer()
    try await callEventually { await gate.started }
    await calls.close(); await gate.release()
    try await callEventually { await service.ends == 1 }
    #expect(await sockets.created.isEmpty)
    #expect(calls.mediaSession == nil && !system.invalidated)
}

@Test @MainActor func directCallAnswerTimeoutStopsCaptureAndDoesNotLaterFulfill() async throws {
    let service = CallService(CallFixture.value(incoming: true)), system = CallSystem(), sockets = CallSockets(), engine = CallEngine()
    let calls = try coordinator(service, system: system, sockets: sockets, engine: engine)
    await calls.reconcile(); await calls.answer()
    try await callEventually { await sockets.created.first?.ready != nil }
    let action = try #require(system.lastAnswer)
    system.emit(.timedOut(action))
    try await callEventually { engine.closed }
    #expect(!system.completed.contains { $0.0 == action.id && $0.1 })
    #expect(calls.mediaSession == nil)
    await calls.close()
}

@Test @MainActor func directCallHeartbeatWatchdogClosesCaptureWhileRenewalIsHung() async throws {
    let service = CallService(CallFixture.value(.accepted, version: 2)), system = CallSystem(available: false)
    let engine = CallEngine(), sockets = CallSockets(), clock = CallClock(), gate = CallGate()
    await service.blockHeartbeat(gate)
    let calls = try coordinator(service, system: system, sockets: sockets, engine: engine, now: { clock.now() })
    await calls.reconcile()
    try await callEventually { await sockets.created.first?.ready != nil }
    clock.advance(11); await calls.tick()
    try await callEventually { await gate.started }
    clock.advance(25); await calls.tick()
    #expect(calls.ending && calls.mediaSession == nil && engine.closed)
    await gate.release()
    await calls.close()
}

@Test @MainActor func directCallDuplicateSystemActionCompletesExactlyOnce() async throws {
    let service = CallService(CallFixture.value(.accepted, version: 2)), system = CallSystem()
    let calls = try coordinator(service, system: system)
    await calls.reconcile()
    let action = system.action(.setMuted(true))
    system.emit(.action(action)); system.emit(.action(action))
    try await callEventually { system.completed.contains { $0.0 == action.id } }
    system.emit(.timedOut(action))
    try await Task.sleep(for: .milliseconds(20))
    #expect(system.completed.filter { $0.0 == action.id }.count == 1)
    #expect(!calls.microphoneWanted && !calls.ending)
    await calls.close()
}

@Test @MainActor func directCallInitialInactiveAudioSnapshotPreservesOutgoingVideoIntent() async throws {
    let service = CallService(), system = CallSystem(), calls = try coordinator(service, system: system)
    await calls.startOutgoing(peer: CallFixture.person, isVideo: true)
    system.emit(.audioActivationChanged(false))
    try await Task.sleep(for: .milliseconds(20))
    #expect(calls.cameraWanted && calls.mediaSession == nil)
    await calls.close()
}

@Test @MainActor func directCallCameraRetryUsesActualCaptureAfterInitialPermissionDenial() async throws {
    let service = CallService(), system = CallSystem(available: false), engine = CallEngine(), sockets = CallSockets()
    engine.cameraFailures = 1
    let calls = try coordinator(service, system: system, sockets: sockets, engine: engine)
    await calls.startOutgoing(peer: CallFixture.person, isVideo: true)
    await service.set(CallFixture.value(.accepted, version: 2)); await calls.reconcile()
    try await callEventually { engine.cameraAttempts == 1 }
    #expect(calls.cameraWanted && !engine.camera)
    await calls.toggleCamera()
    try await callEventually { calls.mediaSession?.camera == true }
    #expect(engine.cameraAttempts == 2 && calls.cameraWanted)
    await calls.close()
}
