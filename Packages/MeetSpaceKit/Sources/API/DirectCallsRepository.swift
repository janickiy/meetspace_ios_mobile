import Foundation
import MeetSpaceCore

public protocol DirectCallsServing: Sendable {
    var origin: ServerOrigin { get }
    var userID: UUID { get }
    func create(targetUserID: UUID, clientRequestID: UUID, clientID: UUID) async throws -> DirectCall
    func active() async throws -> DirectCall?
    func read(_ id: UUID) async throws -> DirectCall
    func accept(_ id: UUID, clientID: UUID) async throws -> DirectCall
    func decline(_ id: UUID, clientID: UUID) async throws -> DirectCall
    func cancel(_ id: UUID, clientID: UUID) async throws -> DirectCall
    func end(_ id: UUID, clientID: UUID) async throws -> DirectCall
    func heartbeat(_ id: UUID, clientID: UUID) async throws -> DirectCall
}

public struct DirectCallsRepository: DirectCallsServing {
    public let origin: ServerOrigin
    public let userID: UUID
    private let client: AuthenticatedClient
    public init(client: AuthenticatedClient) {
        self.client = client; origin = client.account.server; userID = client.account.user.id
    }
    public func create(targetUserID: UUID, clientRequestID: UUID, clientID: UUID) async throws -> DirectCall {
        try accountOnly()
        guard targetUserID != userID, [targetUserID, clientRequestID, clientID].allSatisfy(DirectCall.validID) else { throw ClientError.invalidInput }
        struct Body: Encodable { let targetUserId: String; let clientRequestId: String; let clientId: String }
        let item = try result(await client.request("POST", path: ["calls"], body: WireJSON.encoder().encode(
            Body(targetUserId: sid(targetUserID), clientRequestId: sid(clientRequestID), clientId: sid(clientID)))))
        guard item.callerUserId == userID, item.calleeUserId == targetUserID, item.callerClientId == sid(clientID)
        else { throw ClientError.scopeMismatch }
        return item
    }
    public func active() async throws -> DirectCall? {
        try accountOnly()
        let item = try decodeJSON(ItemResponse<DirectCall?>.self, from: await client.request("GET", path: ["calls", "active"])).item
        guard let item else { return nil }
        let checked = try validate(item)
        guard checked.isActive else { throw APIError.invalidResponse }
        return checked
    }
    public func read(_ id: UUID) async throws -> DirectCall {
        try accountOnly(); try valid(id)
        return try result(await client.request("GET", path: ["calls", sid(id)]), expected: id)
    }
    public func accept(_ id: UUID, clientID: UUID) async throws -> DirectCall { try await change(id, action: "accept", clientID: clientID) }
    public func decline(_ id: UUID, clientID: UUID) async throws -> DirectCall { try await change(id, action: "decline", clientID: clientID) }
    public func cancel(_ id: UUID, clientID: UUID) async throws -> DirectCall { try await change(id, action: "cancel", clientID: clientID) }
    public func end(_ id: UUID, clientID: UUID) async throws -> DirectCall { try await change(id, action: "end", clientID: clientID) }
    public func heartbeat(_ id: UUID, clientID: UUID) async throws -> DirectCall { try await change(id, action: "heartbeat", clientID: clientID) }
    private func change(_ id: UUID, action: String, clientID: UUID) async throws -> DirectCall {
        try accountOnly(); try valid(id); try valid(clientID)
        struct Body: Encodable { let clientId: String }
        let body = action == "decline" ? Data("{}".utf8) : try WireJSON.encoder().encode(Body(clientId: sid(clientID)))
        // Expired calls return a successful terminal state for any action. Do not infer success
        // from HTTP 200 alone or require the requested target state in this repository.
        return try result(await client.request("POST", path: ["calls", sid(id), action], body: body), expected: id)
    }
    private func result(_ response: NetworkResponse, expected: UUID? = nil) throws -> DirectCall {
        let item = try validate(decodeJSON(ItemResponse<DirectCall>.self, from: response).item)
        guard expected == nil || item.id == expected else { throw ClientError.scopeMismatch }
        return item
    }
    private func validate(_ call: DirectCall) throws -> DirectCall {
        do { return try call.validated(for: userID) }
        catch ClientError.invalidInput { throw APIError.invalidResponse }
    }
    private func accountOnly() throws {
        guard client.account.user.guestConferenceId == nil else { throw ClientError.scopeMismatch }
    }
    private func valid(_ id: UUID) throws { guard DirectCall.validID(id) else { throw ClientError.invalidInput } }
    private func sid(_ id: UUID) -> String { id.uuidString.lowercased() }
}
