import Foundation
import Testing
import MeetSpaceCore
@testable import MeetSpaceRealtime

private enum ConferenceFixture {
    static let conference = UUID(), peer = UUID(), participant = UUID()
    static func event(_ type: String, payload: [String: Any], scope: UUID = conference,
                      reply: UUID? = nil, version: Int = 1) throws -> Data {
        var object: [String: Any] = ["version": version, "id": UUID().uuidString.lowercased(), "type": type,
            "conferenceId": scope.uuidString.lowercased(), "timestamp": "2026-11-05T12:00:00.123Z", "data": payload]
        if let reply { object["replyTo"] = reply.uuidString.lowercased() }
        return try JSONSerialization.data(withJSONObject: object)
    }
    static func member(scope: UUID = conference) -> [String: Any] {
        ["id": participant.uuidString, "conferenceId": scope.uuidString, "displayName": "Fixture",
         "role": "participant", "status": "joined", "online": true, "microphoneEnabled": false,
         "cameraEnabled": false, "screenSharing": false]
    }
    static func track(stream: String = peer.uuidString.lowercased(), source: String = "camera") -> [String: Any] {
        ["id": UUID().uuidString, "mediaPeerId": peer.uuidString, "participantId": participant.uuidString,
         "streamId": stream, "kind": "video", "source": source]
    }
}

@Test func conferenceEnvelopeChecksScopeAndPreservesUnknownEvents() throws {
    let reply = UUID()
    let raw = try ConferenceFixture.event("future.event", payload: ["nested": ["items": [1, 2, 3]],
        "revision": Int64.max], reply: reply)
    let event = try ConferenceEnvelope.decode(raw, conferenceID: ConferenceFixture.conference)
    #expect(event.type == "future.event" && event.replyTo == reply)
    guard case .object(let data) = event.data else { Issue.record("Missing object"); return }
    #expect(data["revision"] == .integer(Int64.max))
    #expect(throws: ConferenceSignalError.invalidEnvelope) {
        try ConferenceEnvelope.decode(raw, conferenceID: UUID())
    }
    let incompatible = try ConferenceFixture.event("conference.state", payload: [:], version: 2)
    #expect(throws: ConferenceSignalError.invalidEnvelope) {
        try ConferenceEnvelope.decode(incompatible, conferenceID: ConferenceFixture.conference)
    }
    let malformed = Data("{\"version\":1}".utf8)
    #expect(throws: ConferenceSignalError.invalidEnvelope) {
        try ConferenceEnvelope.decode(malformed, conferenceID: ConferenceFixture.conference)
    }
}

@Test func conferenceCommandsUseLowercaseScopeAndExplicitICEEndMarker() throws {
    let request = UUID()
    let payload = ConferenceSignalICE(mediaPeerId: ConferenceFixture.peer, candidate: nil)
    let raw = try ConferenceEnvelope.command(type: "media.ice", conferenceID: ConferenceFixture.conference,
        data: payload, id: request)
    let json = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
    #expect(json["id"] as? String == request.uuidString.lowercased())
    #expect(json["conferenceId"] as? String == ConferenceFixture.conference.uuidString.lowercased())
    #expect(json["replyTo"] == nil)
    let data = try #require(json["data"] as? [String: Any])
    #expect(data["mediaPeerId"] as? String == ConferenceFixture.peer.uuidString.lowercased())
    #expect(data["candidate"] is NSNull)
    let decoded = try ConferenceEnvelope.decode(raw, conferenceID: ConferenceFixture.conference).payload(ConferenceSignalICE.self)
    #expect(decoded.candidate == nil)
    #expect(throws: ConferenceSignalError.invalidPayload) {
        try ConferenceEnvelope.command(type: "media.join", conferenceID: ConferenceFixture.conference, data: ["array"])
    }
}

@Test func conferenceStateAndTrackCatalogRejectCrossScopeAndMisboundSources() throws {
    let state = try ConferenceFixture.event("conference.state", payload: [
        "connectionId": UUID().uuidString, "participantId": ConferenceFixture.participant.uuidString,
        "status": "active", "participants": [ConferenceFixture.member()]])
    let decoded = try ConferenceEnvelope.decode(state, conferenceID: ConferenceFixture.conference).payload(ConferenceSignalState.self)
    #expect(decoded.participants.count == 1 && decoded.participants[0].online)
    let foreign = try ConferenceFixture.event("conference.state", payload: [
        "connectionId": UUID().uuidString, "participantId": ConferenceFixture.participant.uuidString,
        "status": "active", "participants": [ConferenceFixture.member(scope: UUID())]])
    let envelope = try ConferenceEnvelope.decode(foreign, conferenceID: ConferenceFixture.conference)
    #expect(throws: ConferenceSignalError.invalidPayload) { try envelope.payload(ConferenceSignalState.self) }
    let good = ConferenceFixture.track()
    let tracks = try ConferenceFixture.event("media.tracks", payload: ["mediaPeerId": ConferenceFixture.peer.uuidString,
        "revision": 4, "tracks": [good]])
    #expect(try ConferenceEnvelope.decode(tracks, conferenceID: ConferenceFixture.conference)
        .payload(ConferenceSignalTracks.self).tracks.count == 1)
    for bad in [[good, good], [ConferenceFixture.track(stream: UUID().uuidString.lowercased())],
                [ConferenceFixture.track(source: "microphone")]] {
        let bytes = try ConferenceFixture.event("media.tracks", payload: ["mediaPeerId": ConferenceFixture.peer.uuidString,
            "revision": 5, "tracks": bad])
        let event = try ConferenceEnvelope.decode(bytes, conferenceID: ConferenceFixture.conference)
        #expect(throws: ConferenceSignalError.invalidPayload) { try event.payload(ConferenceSignalTracks.self) }
    }
}

@Test func conferenceICERequiresCandidateFieldAndBoundsNativeInput() throws {
    let missing = try ConferenceFixture.event("media.ice", payload: ["mediaPeerId": ConferenceFixture.peer.uuidString])
    let event = try ConferenceEnvelope.decode(missing, conferenceID: ConferenceFixture.conference)
    #expect(throws: ConferenceSignalError.invalidPayload) { try event.payload(ConferenceSignalICE.self) }
    for candidate in [ConferenceSignalCandidate(candidate: String(repeating: "x", count: 4097)),
                      ConferenceSignalCandidate(candidate: "candidate:fixture", sdpMLineIndex: -1),
                      ConferenceSignalCandidate(candidate: "candidate:fixture\r\na=unexpected"),
                      ConferenceSignalCandidate(candidate: "candidate:fixture", sdpMid: String(repeating: "x", count: 17))] {
        #expect(throws: ConferenceSignalError.invalidPayload) { try candidate.validate() }
    }
    try ConferenceSignalCandidate(candidate: "candidate:fixture", sdpMid: "0", sdpMLineIndex: 0).validate()
}

@Test func conferenceNegotiationCoalescesRevisionsAndIgnoresUnrelatedAcknowledgements() throws {
    var gate = NegotiationGate()
    let started = gate.begin()
    let initial = try #require(started)
    try gate.sentOffer(requestID: UUID())
    let ready = UUID(); try gate.sentReady(requestID: ready)
    try gate.remote(revision: 4); try gate.remote(revision: 2); try gate.changed()
    let coalesced = gate.begin()
    #expect(coalesced == nil)
    let unrelated = gate.acknowledge(requestID: UUID())
    #expect(!unrelated)
    #expect(gate.pending?.id == initial.id)
    let acknowledged = gate.acknowledge(requestID: ready)
    #expect(acknowledged)
    let resumed = gate.begin()
    let next = try #require(resumed)
    #expect(next.revision == 4 && next.localRevision == 1)
    try gate.sentOffer(requestID: UUID()); let nextReady = UUID(); try gate.sentReady(requestID: nextReady)
    let stale = gate.acknowledge(requestID: ready)
    #expect(!stale)
    let finished = gate.acknowledge(requestID: nextReady)
    #expect(finished)
    let unchanged = gate.begin()
    #expect(unchanged == nil)
    try gate.changed(); _ = gate.begin(); try gate.rollback()
    #expect(gate.pending == nil)
    let retried = gate.begin()
    #expect(retried != nil)
    #expect(throws: ConferenceSignalError.invalidPayload) { try gate.remote(revision: -1) }
}

@Test func conferenceSocketRequestAndFramingEnforceTrustBoundaries() throws {
    let origin = try ServerOrigin("https://fixture.example:9443")
    let request = try URLSessionConferenceSocketFactory.request(origin: origin, conferenceID: ConferenceFixture.conference,
        ticket: String(repeating: "a", count: 43))
    #expect(request.url?.scheme == "wss" && request.url?.port == 9443)
    #expect(request.url?.path == "/api/v1/conferences/\(ConferenceFixture.conference.uuidString.lowercased())/ws")
    #expect(request.value(forHTTPHeaderField: "Origin") == "https://fixture.example:9443")
    #expect(request.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") == "go-recorder.v1")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil && request.value(forHTTPHeaderField: "Cookie") == nil)
    for ticket in ["", String(repeating: "a", count: 44), String(repeating: "a", count: 42) + "\n", "ticket/?"] {
        #expect(throws: ConferenceSignalError.invalidTicket) {
            try URLSessionConferenceSocketFactory.request(origin: origin, conferenceID: ConferenceFixture.conference, ticket: ticket)
        }
    }
    #expect(throws: ConferenceSignalError.invalidEnvelope) { try ConferenceSocketFraming.incoming(.data(Data("{}".utf8))) }
    #expect(throws: ConferenceSignalError.invalidEnvelope) {
        try ConferenceSocketFraming.incoming(.string(String(repeating: "x", count: 1_048_577)))
    }
    #expect(throws: ConferenceSignalError.invalidEnvelope) { try ConferenceSocketFraming.outgoing(Data([0xFF])) }
    #expect(throws: ConferenceSignalError.invalidEnvelope) { try ConferenceSocketFraming.outgoing(Data("[]".utf8)) }
    #expect(throws: ConferenceSignalError.invalidEnvelope) {
        try ConferenceSocketFraming.outgoing(JSONSerialization.data(withJSONObject: ["sdp": String(repeating: "x", count: 65_536)]))
    }
    #expect(try ConferenceSocketFraming.incoming(.string("{}")) == Data("{}".utf8))
}

@Test func conferenceSocketHandshakeRequiresNegotiatedSubprotocol() async throws {
    for negotiated in [nil, "unexpected"] as [String?] {
        let delegate = ConferenceSocketDelegate()
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: URL(string: "wss://fixture.example")!)
        // Invoke the native callback without resuming a task or opening a network connection.
        delegate.urlSession(session, webSocketTask: task, didOpenWithProtocol: negotiated)
        await #expect(throws: ConferenceSignalError.unsupportedProtocol) {
            for try await _ in delegate.opened { Issue.record("Unsupported handshake opened"); return }
        }
        session.invalidateAndCancel()
    }
    let delegate = ConferenceSocketDelegate()
    let session = URLSession(configuration: .ephemeral)
    let task = session.webSocketTask(with: URL(string: "wss://fixture.example")!)
    delegate.urlSession(session, webSocketTask: task, didOpenWithProtocol: "go-recorder.v1")
    var opens = 0
    for try await _ in delegate.opened { opens += 1 }
    #expect(opens == 1)
    session.invalidateAndCancel()
}
