import Foundation
import Testing
import MeetSpaceCore
import MeetSpaceAPI

private enum CallFixture {
    static let id = UUID(uuidString: "AB111111-1111-4111-8111-111111111111")!
    static let peer = UUID(uuidString: "BC222222-2222-4222-8222-222222222222")!
    static let callerClient = UUID(uuidString: "CD333333-3333-4333-8333-333333333333")!
    static let calleeClient = UUID(uuidString: "DE444444-4444-4444-8444-444444444444")!
    static let room = UUID(uuidString: "EF555555-5555-4555-8555-555555555555")!
    static let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    static func object(status: DirectCallStatus = .ringing, version: Int64 = 1, caller: UUID = Fixture.userID) -> [String: Any] {
        let accepted = status == .accepted || status == .ended
        return ["id": id.uuidString.lowercased(), "conversationId": Fixture.conversationID.uuidString.lowercased(),
                "conferenceId": accepted ? room.uuidString.lowercased() : NSNull(),
                "callerUserId": caller.uuidString.lowercased(), "calleeUserId": peer.uuidString.lowercased(),
                "callerClientId": callerClient.uuidString.lowercased(),
                "acceptedByClientId": accepted ? calleeClient.uuidString.lowercased() : NSNull(),
                "status": status.rawValue, "version": version, "createdAt": "2026-11-06T10:00:00Z",
                "expiresAt": "2026-11-06T10:00:45Z", "acceptedAt": accepted ? "2026-11-06T10:00:15Z" : NSNull(),
                "endedAt": status.isTerminal ? "2026-11-06T10:00:30Z" : NSNull(),
                "caller": ["id": caller.uuidString.lowercased(), "displayName": "Caller"],
                "callee": ["id": peer.uuidString.lowercased(), "displayName": "Callee"], "durationSec": 0]
    }
    static func call(status: DirectCallStatus = .ringing) throws -> DirectCall {
        try WireJSON.decoder().decode(DirectCall.self, from: Fixture.data(object(status: status)))
    }
    static func repository(_ transport: any RequestTransport) throws -> DirectCallsRepository {
        DirectCallsRepository(client: AuthenticatedClient(account: try Fixture.account(), credentials: Fixture.credentials(), secureStore: TestSecrets(), transport: transport))
    }
}

@Test func directCallOwnershipSeparatesOtherDevicesAndAccountScope() throws {
    let ringing = try CallFixture.call()
    #expect(ringing.isActive && !ringing.isTerminal)
    #expect(ringing.ownsMedia(userID: Fixture.userID, clientID: CallFixture.callerClient))
    #expect(!ringing.ownsMedia(userID: Fixture.userID, clientID: UUID()))
    #expect(!ringing.ownsMedia(userID: CallFixture.peer, clientID: CallFixture.calleeClient))
    #expect(ringing.peer(for: Fixture.userID)?.id == CallFixture.peer)
    #expect(ringing.peer(for: UUID()) == nil)
    #expect(throws: ClientError.scopeMismatch) { try ringing.validated(for: UUID()) }
    for status in DirectCallStatus.allCases {
        let call = try CallFixture.call(status: status).validated(for: Fixture.userID)
        #expect(call.isTerminal == status.isTerminal)
    }
    let accepted = try CallFixture.call(status: .accepted)
    #expect(accepted.ownsMedia(userID: CallFixture.peer, clientID: CallFixture.calleeClient))
    #expect(!accepted.ownsMedia(userID: CallFixture.peer, clientID: CallFixture.callerClient))
}

@Test func directCallsEmitCanonicalUUIDsExactActionBodiesAndAcceptExpiredActionResult() async throws {
    let path = "/api/v1/calls/" + CallFixture.id.uuidString.lowercased()
    let transport = RoutedTransport { request, _ in
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        let body = try request.httpBody.map { try JSONSerialization.jsonObject(with: $0) as! [String: String] } ?? [:]
        switch (request.httpMethod, request.url?.path) {
        case ("POST", "/api/v1/calls"):
            #expect(body == ["targetUserId": CallFixture.peer.uuidString.lowercased(),
                             "clientRequestId": Fixture.messageID.uuidString.lowercased(), "clientId": CallFixture.callerClient.uuidString.lowercased()])
        case ("GET", "/api/v1/calls/active"), ("GET", path):
            #expect(request.httpBody == nil)
        case ("POST", path + "/decline"):
            #expect(body.isEmpty)
        case ("POST", path + "/accept"), ("POST", path + "/cancel"), ("POST", path + "/end"), ("POST", path + "/heartbeat"):
            #expect(body == ["clientId": CallFixture.callerClient.uuidString.lowercased()])
            // Backend expires before applying an action and can return missed with HTTP 200.
            return try Fixture.response(["item": CallFixture.object(status: .missed, version: 2)])
        default: Issue.record("Unexpected direct-call request"); throw APIError.invalidResponse
        }
        return try Fixture.response(["item": CallFixture.object()])
    }
    let repository = try CallFixture.repository(transport)
    _ = try await repository.create(targetUserID: CallFixture.peer, clientRequestID: Fixture.messageID, clientID: CallFixture.callerClient)
    _ = try await repository.active(); _ = try await repository.read(CallFixture.id)
    #expect(try await repository.accept(CallFixture.id, clientID: CallFixture.callerClient).status == .missed)
    _ = try await repository.decline(CallFixture.id, clientID: CallFixture.callerClient)
    _ = try await repository.cancel(CallFixture.id, clientID: CallFixture.callerClient)
    _ = try await repository.end(CallFixture.id, clientID: CallFixture.callerClient)
    _ = try await repository.heartbeat(CallFixture.id, clientID: CallFixture.callerClient)
    #expect(await transport.requests.count == 8)
}

@Test func directCallsRejectMismatchedAndMalformedServerState() async throws {
    var mismatchedPeer = CallFixture.object(); mismatchedPeer["caller"] = ["id": UUID().uuidString, "displayName": "Other"]
    var missingRoom = CallFixture.object(status: .accepted); missingRoom["conferenceId"] = NSNull()
    var wrongClient = CallFixture.object(); wrongClient["callerClientId"] = CallFixture.callerClient.uuidString
    var unknownStatus = CallFixture.object(); unknownStatus["status"] = "future-status"
    for object in [mismatchedPeer, missingRoom, wrongClient, unknownStatus, CallFixture.object(version: 0)] {
        let response = try Fixture.response(["item": object])
        let repository = try CallFixture.repository(RoutedTransport { _, _ in response })
        await #expect(throws: APIError.invalidResponse) { try await repository.read(CallFixture.id) }
    }
    let foreign = try Fixture.response(["item": CallFixture.object(caller: UUID())])
    let foreignRepository = try CallFixture.repository(RoutedTransport { _, _ in foreign })
    await #expect(throws: ClientError.scopeMismatch) { try await foreignRepository.active() }
    let valid = try Fixture.response(["item": CallFixture.object()])
    let repository = try CallFixture.repository(RoutedTransport { _, _ in valid })
    await #expect(throws: ClientError.scopeMismatch) { try await repository.read(UUID()) }
    let terminal = try Fixture.response(["item": CallFixture.object(status: .missed)])
    await #expect(throws: APIError.invalidResponse) { try await CallFixture.repository(RoutedTransport { _, _ in terminal }).active() }
}

@Test func directCallsPreserveHTTPFailuresAndRejectInvalidIDsBeforeTransport() async throws {
    for status in [403, 404, 409, 422, 429, 503] {
        let transport = RoutedTransport { _, _ in NetworkResponse(status: status) }
        let repository = try CallFixture.repository(transport)
        await #expect(throws: APIError.httpStatus(status)) { try await repository.accept(CallFixture.id, clientID: CallFixture.calleeClient) }
        #expect(await transport.requests.count == 1)
    }
    let transport = RoutedTransport { _, _ in try Fixture.response(["item": NSNull()]) }
    let repository = try CallFixture.repository(transport)
    #expect(try await repository.active() == nil)
    await #expect(throws: ClientError.invalidInput) { try await repository.read(CallFixture.zero) }
    await #expect(throws: ClientError.invalidInput) { try await repository.end(CallFixture.id, clientID: CallFixture.zero) }
    await #expect(throws: ClientError.invalidInput) {
        try await repository.create(targetUserID: Fixture.userID, clientRequestID: UUID(), clientID: UUID())
    }
    #expect(await transport.requests.count == 1)
}
