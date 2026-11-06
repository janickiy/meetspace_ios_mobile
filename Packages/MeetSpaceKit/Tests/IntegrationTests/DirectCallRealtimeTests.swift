import Foundation
import Testing
import MeetSpaceCore
import MeetSpaceRealtime

@Test func directCallEventHasAccountScopeWithoutConversationEnvelope() throws {
    let caller = UUID(), callee = UUID()
    let call = DirectCall(id: UUID(), conversationId: UUID(), callerUserId: caller, calleeUserId: callee,
        callerClientId: UUID().uuidString.lowercased(), status: .ringing, version: 1,
        createdAt: Date(), expiresAt: Date().addingTimeInterval(45),
        caller: DirectCallPeer(id: caller, displayName: "Caller"), callee: DirectCallPeer(id: callee, displayName: "Callee"))
    let payload = try JSONSerialization.jsonObject(with: WireJSON.encoder().encode(call))
    let data = try JSONSerialization.data(withJSONObject: ["version": 1, "id": UUID().uuidString,
        "type": "call.updated", "data": ["call": payload]])
    let decoded = try UserEvent.decode(data)
    let event = try #require(decoded)
    #expect(event.type == "call.updated")
    #expect(event.conversationID == nil)
    #expect(event.call?.id == call.id)
    #expect(try event.call?.validated(for: callee).id == call.id)
    #expect(throws: ClientError.scopeMismatch) { try event.call?.validated(for: UUID()) }
}

@Test func malformedCallEventsCannotBecomeChatEvents() throws {
    let missingCall = try JSONSerialization.data(withJSONObject: ["version": 1, "id": UUID().uuidString,
        "type": "call.updated", "data": ["conversationId": UUID().uuidString]])
    #expect(throws: RealtimeError.self) { try UserEvent.decode(missingCall) }
    let unknown = Data(#"{"version":1,"type":"future.call.feature","data":[]}"#.utf8)
    #expect(try UserEvent.decode(unknown) == nil)
}
