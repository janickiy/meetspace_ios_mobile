import Foundation
import Testing
import MeetSpaceCore
import MeetSpaceAPI

private enum ConferenceFixture {
    static let room = UUID(uuidString: "A1111111-1111-4111-8111-111111111111")!
    static let participantID = UUID(uuidString: "B2222222-2222-4222-8222-222222222222")!
    static let code = String(repeating: "a", count: 32)
    static func participant(role: String = "participant", status: String = "joined", admission: String = "admitted",
                            id: UUID = participantID, room: UUID = room, user: UUID = Fixture.userID) -> ConferenceParticipant {
        ConferenceParticipant(id: id, conferenceId: room, userId: user, displayName: "Fixture", role: role, status: status, admissionState: admission)
    }
    static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: WireJSON.encoder().encode(value)) as! [String: Any]
    }
    static func guestResponse(room: UUID = room, userID: UUID = Fixture.userID) throws -> NetworkResponse {
        var user = Fixture.user(userID); user["guestConferenceId"] = room.uuidString
        return try Fixture.response(["status": "success", "accessToken": "fixture-guest-bearer", "tokenType": "Bearer", "expiresIn": 10800,
            "user": user, "item": object(participant(room: room, user: userID))])
    }
    static func guest(origin: ServerOrigin = Fixture.origin, expiresAt: Date = Date().addingTimeInterval(3600)) throws -> GuestConferenceSession {
        var raw = Fixture.user(); raw["guestConferenceId"] = room.uuidString
        let user = try WireJSON.decoder().decode(AccountUser.self, from: Fixture.data(raw))
        return try GuestConferenceSession(origin: origin, accessToken: "fixture-guest-bearer", expiresAt: expiresAt, user: user, participant: participant())
    }
    static func message(room: UUID = room, sequence: Any = "9007199254740993") -> [String: Any] {
        ["id": Fixture.messageID.uuidString, "sequence": sequence, "conferenceId": room.uuidString,
         "senderId": Fixture.userID.uuidString, "senderName": "Fixture", "clientRequestId": Fixture.messageID.uuidString,
         "text": "hello", "version": 1, "createdAt": "2026-11-01T10:00:00Z", "updatedAt": "2026-11-01T10:00:00Z", "attachments": NSNull()]
    }
    static func repository(_ transport: any RequestTransport) throws -> ConferenceRepository {
        ConferenceRepository(client: AuthenticatedClient(account: try Fixture.account(), credentials: Fixture.credentials(), secureStore: TestSecrets(), transport: transport))
    }
}

@Test func conferenceRoleMatrixKeepsLobbyAndGuestPrivilegesSeparate() throws {
    let owner = ConferenceFixture.participant(role: "owner", id: UUID())
    let host = ConferenceFixture.participant(role: "co_host", id: UUID())
    let regular = ConferenceFixture.participant()
    let guest = ConferenceFixture.participant(role: "guest")
    let waiting = ConferenceFixture.participant(status: "waiting", admission: "waiting")
    #expect(owner.canAdmit && host.canAdmit && !regular.canAdmit && !guest.canAdmit)
    #expect(!waiting.canParticipate && !waiting.canReadHistory && waiting.isWaiting)
    for action in ["mute", "camera", "screen", "kick", "role"] {
        #expect(owner.canModerate(regular, action: action))
        #expect(!owner.canModerate(owner, action: action))
        #expect(!host.canModerate(owner, action: action))
        #expect(!host.canModerate(guest, action: action))
        #expect(!owner.canModerate(waiting, action: action))
    }
    #expect(host.canModerate(regular, action: "mute"))
    #expect(host.canModerate(regular, action: "screen"))
    #expect(host.canModerate(regular, action: "kick"))
    #expect(!host.canModerate(regular, action: "camera"))
    #expect(!host.canModerate(regular, action: "role"))
    #expect(!owner.canModerate(ConferenceFixture.participant(room: UUID()), action: "kick"))
    #expect(throws: ClientError.invalidInput) { try ConferenceModeration(action: "role", role: "owner") }
    #expect(throws: ClientError.invalidInput) { try ConferenceModeration(action: "mute") }
    #expect(throws: ClientError.invalidInput) { try ConferenceModeration(action: "kick", blocked: false) }
    #expect(throws: ClientError.invalidInput) {
        try ConferenceMediaState(connectionID: UUID(), sequence: 9_007_199_254_740_992, microphoneEnabled: true, cameraEnabled: true).validate()
    }
}

@Test func conferenceInviteParsingRejectsCrossOriginAndAmbiguousLinks() throws {
    let code = ConferenceFixture.code
    #expect(try ConferenceInviteGateway.inviteCode(from: code, origin: Fixture.origin) == code)
    #expect(try ConferenceInviteGateway.inviteCode(from: "https://fixture.example/i/" + code, origin: Fixture.origin) == code)
    #expect(try ConferenceInviteGateway.inviteCode(from: "https://fixture.example:443/api/v1/conference-invites/" + code + "/", origin: Fixture.origin) == code)
    for invalid in ["https://other.example/i/" + code, "https://fixture.example:444/i/" + code,
                    "https://fixture.example/i/" + code + "?token=fixture", "https://fixture.example//i/" + code,
                    "https://fixture.example/i/%61" + String(code.dropFirst()), "https://name@fixture.example/i/" + code,
                    "http://fixture.example/i/" + code, String(code.dropFirst())] {
        #expect(throws: (any Error).self) { try ConferenceInviteGateway.inviteCode(from: invalid, origin: Fixture.origin) }
    }
}

@Test func conferenceRESTUsesAuditedTicketMediaAndMessageContracts() async throws {
    let connection = UUID(uuidString: "CAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
    let roomPath = "/api/v1/conferences/" + ConferenceFixture.room.uuidString.lowercased()
    let transport = RoutedTransport { request, _ in
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        let body = try request.httpBody.map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] } ?? [:]
        switch (request.httpMethod, request.url?.path) {
        case ("POST", roomPath + "/ws-ticket"):
            #expect(Set(body.keys) == ["clientId"])
            #expect(body["clientId"] as? String == connection.uuidString.lowercased())
            return try Fixture.response(["ticket": String(repeating: "a", count: 43), "expiresAt": "2099-01-01T00:00:00Z"])
        case ("PUT", roomPath + "/participants/me/media"):
            #expect(Set(body.keys) == ["connectionId", "sequence", "microphoneEnabled", "cameraEnabled", "screenSharing"])
            #expect(body["connectionId"] as? String == connection.uuidString.lowercased())
            #expect(body["sequence"] as? Int == 2)
            return try Fixture.response(["item": ConferenceFixture.object(ConferenceFixture.participant())])
        case ("GET", "/api/v1/webrtc/config"):
            return try Fixture.response(["iceServers": [["urls": ["turns:turn.fixture.example:5349?transport=tcp"], "username": "fixture-ephemeral", "credential": "fixture-secret"]],
                "iceTransportPolicy": "relay", "expiresAt": Date().addingTimeInterval(600).timeIntervalSince1970])
        case ("GET", roomPath + "/messages"), ("GET", roomPath + "/chat/messages/search"):
            #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "limit", value: "50")) == true)
            if request.url?.path.hasSuffix("/search") == true {
                return try Fixture.response(["items": [ConferenceFixture.message()], "nextCursor": "next"])
            }
            return try Fixture.response(["items": [ConferenceFixture.message()], "nextCursor": "next", "unreadCount": 1])
        case ("POST", roomPath + "/messages"):
            #expect(body["clientRequestId"] as? String == Fixture.messageID.uuidString)
            #expect(body["text"] as? String == "hello")
            return try Fixture.response(["item": ConferenceFixture.message()])
        default: Issue.record("Unexpected method/path in conference contract"); throw APIError.invalidResponse
        }
    }
    let repository = try ConferenceFixture.repository(transport)
    _ = try await repository.ticket(ConferenceFixture.room, clientID: connection)
    _ = try await repository.updateMedia(ConferenceFixture.room, state: ConferenceMediaState(connectionID: connection, sequence: 2, microphoneEnabled: true, cameraEnabled: false))
    let ice = try await repository.ice()
    #expect(ice.iceTransportPolicy == "relay" && ice.iceServers.count == 1)
    let page = try await repository.messages(ConferenceFixture.room)
    #expect(page.items.first?.sequence == 9_007_199_254_740_993)
    #expect(page.items.first?.attachments.isEmpty == true)
    _ = try await repository.messages(ConferenceFixture.room, search: "hello")
    _ = try await repository.send(ConferenceFixture.room, draft: MessageDraft(id: Fixture.messageID, text: "hello"))
    #expect(await transport.requests.count == 6)
}

@Test func conferenceGuestSessionCannotSendCredentialsOutsideItsOriginOrRoom() async throws {
    let guest = try ConferenceFixture.guest()
    let transport = RoutedTransport { request, _ in
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-guest-bearer")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        return try Fixture.response(["item": ConferenceFixture.object(ConferenceFixture.participant(role: "guest"))])
    }
    let repository = ConferenceRepository(origin: Fixture.origin, guest: guest, transport: transport)
    _ = try await repository.selfParticipant(ConferenceFixture.room)
    await #expect(throws: ClientError.scopeMismatch) { try await repository.selfParticipant(UUID()) }
    await #expect(throws: ClientError.scopeMismatch) { try await repository.list() }
    await #expect(throws: ClientError.scopeMismatch) { try await repository.joinInvite(code: ConferenceFixture.code) }
    let otherServer = ConferenceRepository(origin: try ServerOrigin("https://other.example"), guest: guest, transport: transport)
    await #expect(throws: ClientError.scopeMismatch) { try await otherServer.selfParticipant(ConferenceFixture.room) }
    #expect(await transport.requests.count == 1)
}

@Test func conferenceGuestResumeUsesBearerOnlyForMatchingInviteAndNeverRefreshes() async throws {
    let transport = RoutedTransport { request, _ in
        if request.httpMethod == "GET" {
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return try Fixture.response(["item": ["id": ConferenceFixture.room.uuidString, "title": "Conference", "status": "active"]])
        }
        #expect(request.url?.path.hasSuffix("/guest") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-guest-bearer")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        return try ConferenceFixture.guestResponse()
    }
    let gateway = ConferenceInviteGateway(origin: Fixture.origin, transport: transport)
    let resumed = try await gateway.guestJoin(code: ConferenceFixture.code, displayName: " Guest ", resume: ConferenceFixture.guest())
    #expect(resumed.conferenceID == ConferenceFixture.room && resumed.user.id == Fixture.userID)
    #expect(await transport.requests.count == 2)
    let expiredResponse = RoutedTransport { _, _ in NetworkResponse(status: 401) }
    let repository = ConferenceRepository(origin: Fixture.origin, guest: resumed, transport: expiredResponse)
    await #expect(throws: ClientError.sessionExpired) { try await repository.selfParticipant(ConferenceFixture.room) }
    #expect(await expiredResponse.requests.count == 1)
    #expect(await expiredResponse.requests.allSatisfy { !$0.url!.path.contains("refresh") })
}

@Test func conferenceRejectsScopeMismatchAndInvalidICEBeforeReturningState() async throws {
    let transport = RoutedTransport { request, _ in
        if request.url?.path.hasSuffix("/messages") == true {
            return try Fixture.response(["items": [ConferenceFixture.message(room: UUID())], "unreadCount": 0])
        }
        return try Fixture.response(["item": ConferenceFixture.object(ConferenceFixture.participant(user: UUID()))])
    }
    let repository = try ConferenceFixture.repository(transport)
    await #expect(throws: ClientError.scopeMismatch) { try await repository.messages(ConferenceFixture.room) }
    await #expect(throws: ClientError.scopeMismatch) { try await repository.selfParticipant(ConferenceFixture.room) }
    #expect(throws: (any Error).self) {
        try WireJSON.decoder().decode(ConferenceMessage.self, from: Fixture.data(ConferenceFixture.message(sequence: 42)))
    }
    #expect(throws: ClientError.invalidInput) { try ICEConfiguration(iceServers: [], iceTransportPolicy: "relay").validated() }
    #expect(throws: ClientError.invalidInput) { try ICEConfiguration(iceServers: [ICEServer(urls: ["https://fixture.example"])]).validated() }
    #expect(throws: ClientError.invalidInput) { try ICEConfiguration(iceServers: [], expiresAt: Date().addingTimeInterval(-1).timeIntervalSince1970).validated() }
    #expect(try ICEConfiguration(iceServers: []).validated().iceTransportPolicy == "all")
}
