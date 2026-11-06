import Foundation
import Testing
import MeetSpaceCore
import MeetSpaceAPI

private enum PushFixture {
    static let id = UUID(uuidString: "AB999999-9999-4999-8999-999999999999")!
    static func device(platform: String = "ios") -> [String: Any] {
        // RegisterDevice returns its original value, so Go zero dates are legitimate here.
        ["id": id.uuidString.lowercased(), "platform": platform, "provider": "http",
         "createdAt": "0001-01-01T00:00:00Z", "updatedAt": "0001-01-01T00:00:00Z"]
    }
    static func repository(_ transport: any RequestTransport, account: AccountRecord? = nil) throws -> NotificationDeviceRepository {
        NotificationDeviceRepository(client: AuthenticatedClient(account: try account ?? Fixture.account(), credentials: Fixture.credentials(), secureStore: TestSecrets(), transport: transport))
    }
}

@Test func notificationDeviceContractUsesOnlyOrdinaryTokenFieldsAndScopedRevoke() async throws {
    let transport = RoutedTransport { request, _ in
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        switch (request.httpMethod, request.url?.path) {
        case ("GET", "/api/v1/integrations/capabilities"):
            return try Fixture.response(["email": "noop", "push": "http", "calendar": "noop", "calendarOAuthConfigured": false, "mockConnectAllowed": false])
        case ("POST", "/api/v1/notifications/devices"):
            let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as! [String: String]
            #expect(body == ["platform": "ios", "token": "fixture-ordinary-push-token"])
            return try Fixture.response(["item": PushFixture.device()])
        case ("GET", "/api/v1/notifications/devices"):
            return try Fixture.response(["items": [PushFixture.device()]])
        case ("DELETE", "/api/v1/notifications/devices/" + PushFixture.id.uuidString.lowercased()):
            #expect(request.httpBody == nil)
            return NetworkResponse(status: 204)
        default: Issue.record("Unexpected push-device request"); throw APIError.invalidResponse
        }
    }
    let repository = try PushFixture.repository(transport)
    #expect(try await repository.capabilities().push == "http")
    let item = try await repository.register(token: "fixture-ordinary-push-token")
    #expect(item.id == PushFixture.id && item.isActive)
    let binding = PushDeviceBinding(origin: repository.origin, userID: repository.userID, deviceID: item.id)
    let encoded = try WireJSON.encoder().encode(binding)
    #expect(try WireJSON.decoder().decode(PushDeviceBinding.self, from: encoded) == binding)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("token"))
    #expect(try await repository.devices().count == 1)
    try await repository.revoke(binding.deviceID)
    #expect(await transport.requests.count == 4)
}

@Test func notificationPreferencesPreserveCategoriesAndDoNotPretendVoIPSupport() async throws {
    let desired = NotificationPreferences(invitation: false, reminder: true, recording: false, email: false, push: true)
    let transport = RoutedTransport { request, _ in
        #expect(request.url?.path == "/api/v1/notifications/preferences")
        if request.httpMethod == "PUT" {
            let object = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as! [String: Bool]
            #expect(object == ["invitation": false, "reminder": true, "recording": false, "email": false, "push": true])
        }
        return NetworkResponse(status: 200, headers: ["content-type": "application/json"], data: try WireJSON.encoder().encode(desired))
    }
    let repository = try PushFixture.repository(transport)
    #expect(try await repository.preferences() == desired)
    #expect(try await repository.savePreferences(desired) == desired)
}

@Test func notificationDevicesRejectInvalidInputAndServerMetadataWithoutLeakingTokens() async throws {
    let transport = RoutedTransport { _, _ in try Fixture.response(["item": PushFixture.device(platform: "android")]) }
    let repository = try PushFixture.repository(transport)
    for token in ["short", String(repeating: "a", count: 8193), "token with space", "token\ncontrol"] {
        await #expect(throws: ClientError.invalidInput) { try await repository.register(token: token) }
    }
    #expect(await transport.requests.isEmpty)
    await #expect(throws: APIError.invalidResponse) { try await repository.register(token: "fixture-valid-token") }
    for status in [403, 404, 409, 429, 503] {
        let responseTransport = RoutedTransport { _, _ in NetworkResponse(status: status) }
        let responseRepository = try PushFixture.repository(responseTransport)
        await #expect(throws: APIError.httpStatus(status)) { try await responseRepository.register(token: "fixture-valid-token") }
        #expect(await responseTransport.requests.count == 1)
    }
}

@Test func callAndPushRepositoriesRejectGuestCredentialsBeforeAnyRequest() async throws {
    var raw = Fixture.user(); raw["guestConferenceId"] = UUID().uuidString
    let guest = AccountRecord(server: Fixture.origin, user: try WireJSON.decoder().decode(AccountUser.self, from: Fixture.data(raw)))
    let transport = RoutedTransport { _, _ in Issue.record("Guest account escaped scope"); throw APIError.invalidResponse }
    let client = AuthenticatedClient(account: guest, credentials: Fixture.credentials(), secureStore: TestSecrets(), transport: transport)
    let calls = DirectCallsRepository(client: client), push = NotificationDeviceRepository(client: client)
    await #expect(throws: ClientError.scopeMismatch) { try await calls.active() }
    await #expect(throws: ClientError.scopeMismatch) { try await calls.create(targetUserID: UUID(), clientRequestID: UUID(), clientID: UUID()) }
    await #expect(throws: ClientError.scopeMismatch) { try await push.register(token: "fixture-valid-token") }
    await #expect(throws: ClientError.scopeMismatch) { try await push.revoke(PushFixture.id) }
    #expect(await transport.requests.isEmpty)
}
