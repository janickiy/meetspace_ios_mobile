import Foundation
import Testing
import MeetSpaceCore
import MeetSpaceAPI
import MeetSpaceStorage
import MeetSpaceRealtime
@testable import MeetSpaceFeatures

private struct ChatActionSockets: RealtimeSocketFactory {
    func connect(_ url: URL) async throws -> any RealtimeSocket { throw APIError.offline }
}
private func chatResponse(_ messages: [ChatMessage]) throws -> NetworkResponse {
    let items = try messages.map { try JSONSerialization.jsonObject(with: WireJSON.encoder().encode($0)) }
    return try Fixture.response(["items": items, "unreadCount": 0])
}
private func chatTransport(_ messages: [ChatMessage]) -> RoutedTransport {
    RoutedTransport { request, _ in
        if request.url!.path.hasSuffix("/messages") || request.url!.path.hasSuffix("/messages/search") { return try chatResponse(messages) }
        return try Fixture.response(["item": JSONSerialization.jsonObject(with: Fixture.conversation())])
    }
}
private func chatClient(_ transport: RoutedTransport) throws -> AuthenticatedClient {
    AuthenticatedClient(account: try Fixture.account(), credentials: Fixture.credentials(), secureStore: TestSecrets(), transport: transport)
}

@Test @MainActor func betaChatBulkRemovalPersistsWithoutServerDeleteAndFiltersSearch() async throws {
    let messages = try [Fixture.message(id: UUID(), sequence: "1", text: "one"), Fixture.message(id: UUID(), sequence: "2", text: "two")]
    let transport = chatTransport(messages), store = MemoryHiddenChatMessagesStore()
    let client = try chatClient(transport)
    let first = MessagingModel(client: client, sockets: ChatActionSockets(), hiddenMessages: store)
    await first.open(Fixture.conversationID)
    await first.searchMessages("one")
    first.beginMessageSelection(); first.toggleAllMessages()
    #expect(first.selectedMessages.map(\.text) == ["one", "two"])
    first.reply = messages[0]; first.editing = messages[1]; first.text = "edited"
    #expect(await first.hideSelectedMessages())
    #expect(first.timeline.messages.isEmpty && first.searchResults.isEmpty && first.historyState == .empty)
    #expect(first.reply == nil && first.editing == nil && first.text.isEmpty)
    await first.reloadHistory(Fixture.conversationID)
    #expect(first.timeline.messages.isEmpty)
    await first.close()
    let reopened = MessagingModel(client: client, sockets: ChatActionSockets(), hiddenMessages: store)
    await reopened.open(Fixture.conversationID)
    #expect(reopened.timeline.messages.isEmpty)
    #expect(await transport.requests.allSatisfy { $0.httpMethod != "DELETE" })
    await reopened.close(); _ = try await client.close()
}

private actor BrokenHiddenMessages: HiddenChatMessagesStore {
    let failRead: Bool
    init(failRead: Bool = false) { self.failRead = failRead }
    func load(scope: String) throws -> Set<UUID> { if failRead { throw ClientError.storage }; return [] }
    func hide(_ ids: Set<UUID>, scope: String) throws -> Set<UUID> { throw ClientError.storage }
}
@Test @MainActor func betaChatFailedLocalRemovalKeepsSelectionAndHistory() async throws {
    let message = try Fixture.message(), transport = chatTransport([message]), client = try chatClient(transport)
    let model = MessagingModel(client: client, sockets: ChatActionSockets(), hiddenMessages: BrokenHiddenMessages())
    await model.open(Fixture.conversationID); model.beginMessageSelection(message)
    #expect(await model.hideSelectedMessages() == false)
    #expect(model.selectedMessageIDs == [message.id] && model.timeline.messages.count == 1)
    #expect(model.error != nil && !model.hidingMessages)
    await model.close(); _ = try await client.close()
}
@Test @MainActor func betaChatUnreadableHiddenStoreDoesNotResurrectMessages() async throws {
    let message = try Fixture.message(), transport = chatTransport([message]), client = try chatClient(transport)
    let model = MessagingModel(client: client, sockets: ChatActionSockets(), hiddenMessages: BrokenHiddenMessages(failRead: true))
    await model.open(Fixture.conversationID)
    #expect(model.timeline.messages.isEmpty && model.historyState == .failed)
    #expect(await transport.requests.isEmpty)
    await model.close(); _ = try await client.close()
}
@Test func betaChatHiddenIDsHaveDurableOriginAndAccountIsolation() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let store = DeviceHiddenChatMessagesStore(baseDirectory: base), id = UUID()
    let a = try Fixture.account(), b = try Fixture.account(UUID()), c = try Fixture.account(server: ServerOrigin("https://other.example"))
    #expect(try await store.hide([id], scope: a.id) == [id])
    let reopened = DeviceHiddenChatMessagesStore(baseDirectory: base)
    #expect(try await reopened.load(scope: a.id) == [id])
    #expect(try await reopened.load(scope: b.id).isEmpty)
    #expect(try await reopened.load(scope: c.id).isEmpty)
    let files = try FileManager.default.contentsOfDirectory(at: base.appendingPathComponent("MeetSpaceHiddenMessages-v1"), includingPropertiesForKeys: nil)
    #expect(files.count == 1)
    let bytes = try String(contentsOf: #require(files.first), encoding: .utf8)
    #expect(bytes == id.uuidString.lowercased() + "\n")
    try Data("not-a-uuid\n".utf8).write(to: #require(files.first))
    await #expect(throws: ClientError.storage) { try await reopened.load(scope: a.id) }
}
@Test @MainActor func betaChatSelectionRejectsForeignAndDeletedMessages() async throws {
    let good = try Fixture.message(), deleted = try Fixture.message(id: UUID(), deleted: true)
    let transport = chatTransport([good, deleted]), client = try chatClient(transport)
    let model = MessagingModel(client: client, sockets: ChatActionSockets(), hiddenMessages: MemoryHiddenChatMessagesStore())
    await model.open(Fixture.conversationID)
    model.beginMessageSelection(); model.toggleAllMessages()
    #expect(model.selectedMessages.map(\.id) == [good.id])
    model.toggleMessageSelection(deleted.id)
    model.toggleMessageSelection(UUID())
    #expect(model.selectedMessageIDs == [good.id])
    let foreign = try Fixture.message(conversation: UUID())
    await model.delete(foreign)
    #expect(await transport.requests.allSatisfy { $0.httpMethod != "DELETE" })
    await model.close(); _ = try await client.close()
}
@Test func betaChatForwardRejectsWrongDestinationAndReusesSuppliedIdempotencyKey() async throws {
    let source = Fixture.conversationID, destination = UUID(), key = UUID(), message = try Fixture.message()
    let transport = RoutedTransport { request, _ in
        let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as! [String: Any]
        #expect((body["clientRequestId"] as? String)?.lowercased() == key.uuidString.lowercased())
        #expect((body["sourceId"] as? String)?.lowercased() == source.uuidString.lowercased())
        return try chatResponse([message]) // Deliberately substituted source-conversation response.
    }
    let client = try chatClient(transport), repository = MessagingRepository(client: client)
    for _ in 0..<2 {
        await #expect(throws: APIError.invalidResponse) { try await repository.forward(destination, source: source, messages: [message.id], requestID: key) }
    }
    #expect(await transport.requests.count == 2)
    await #expect(throws: ClientError.invalidInput) { try await repository.forward(destination, source: source, messages: [message.id, message.id], requestID: key) }
    #expect(await transport.requests.count == 2)
    _ = try await client.close()
}
@Test func betaChatForwardedMessagesRetainAttributionAndCannotBeEdited() throws {
    var object = try JSONSerialization.jsonObject(with: WireJSON.encoder().encode(Fixture.message())) as! [String: Any]
    object["forwardedFrom"] = ["senderName": "Original sender"]; object["pinned"] = true
    let message = try WireJSON.decoder().decode(ChatMessage.self, from: Fixture.data(object))
    #expect(message.forwardedFrom?.senderName == "Original sender" && message.pinned)
    #expect(!message.canEdit(as: Fixture.userID) && message.isActionable)
    #expect(message.shareText == "Fixture")
    #expect(try Fixture.message(deleted: true).shareText.isEmpty)
}

@Test func betaChatForwardAcceptsServerAttributedMessageAndDeleteRequiresTombstone() async throws {
    let destination = UUID(), source = Fixture.conversationID, original = try Fixture.message()
    var forwardedObject = try JSONSerialization.jsonObject(with: WireJSON.encoder().encode(Fixture.message(id: UUID(), conversation: destination))) as! [String: Any]
    forwardedObject["forwardedFrom"] = ["senderName": "Original author"]
    let forwardedData = try Fixture.data(["items": [forwardedObject]])
    let invalidDeleteData = try Fixture.data(["item": JSONSerialization.jsonObject(with: WireJSON.encoder().encode(original))])
    let transport = RoutedTransport { request, _ in NetworkResponse(status: 200, headers: ["content-type": "application/json"], data: request.httpMethod == "POST" ? forwardedData : invalidDeleteData) }
    let client = try chatClient(transport), repository = MessagingRepository(client: client)
    let result = try await repository.forward(destination, source: source, messages: [original.id], requestID: UUID())
    #expect(result.first?.forwardedFrom?.senderName == "Original author")
    await #expect(throws: APIError.invalidResponse) { try await repository.delete(source, message: original.id) }
    _ = try await client.close()
}

@Test func betaChatDirectRecipientMustMatchRequestedUser() async throws {
    let requested = UUID()
    for (type, peerID) in [("direct", UUID()), ("group", requested), ("direct", requested)] {
        var object = try JSONSerialization.jsonObject(with: Fixture.conversation()) as! [String: Any]
        object["type"] = type; object["peer"] = ["id": peerID.uuidString, "displayName": "Recipient"]
        let data = try Fixture.data(["item": object])
        let transport = RoutedTransport { _, _ in NetworkResponse(status: 200, headers: ["content-type": "application/json"], data: data) }
        let client = try chatClient(transport), repository = MessagingRepository(client: client)
        if type == "direct", peerID == requested { #expect(try await repository.direct(userID: requested).peer?.id == requested) }
        else { await #expect(throws: APIError.invalidResponse) { try await repository.direct(userID: requested) } }
        _ = try await client.close()
    }
}

private actor DirectRecipientGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
@Test @MainActor func betaChatCancelledRecipientResolutionNeverForwardsAndBlocksSecondSelection() async throws {
    let message = try Fixture.message(), recipient = UUID(), gate = DirectRecipientGate()
    var directObject = try JSONSerialization.jsonObject(with: Fixture.conversation()) as! [String: Any]
    directObject["peer"] = ["id": recipient.uuidString, "displayName": "Recipient"]
    let directData = try Fixture.data(["item": directObject])
    let transport = RoutedTransport { request, _ in
        if request.url!.path.hasSuffix("/direct") {
            await gate.wait() // Deliberately returns a response even when its caller was cancelled.
            return NetworkResponse(status: 200, headers: ["content-type": "application/json"], data: directData)
        }
        if request.url!.path.hasSuffix("/messages") { return try chatResponse([message]) }
        return try Fixture.response(["item": JSONSerialization.jsonObject(with: Fixture.conversation())])
    }
    let client = try chatClient(transport)
    let model = MessagingModel(client: client, sockets: ChatActionSockets(), hiddenMessages: MemoryHiddenChatMessagesStore())
    await model.open(Fixture.conversationID)
    let pending = Task { try await model.forward([message], toUser: recipient, requestID: UUID()) }
    while !(await gate.entered) { await Task.yield() }
    #expect(model.forwarding)
    await #expect(throws: ClientError.invalidInput) { try await model.forward([message], to: UUID(), requestID: UUID()) }
    pending.cancel(); await gate.release()
    await #expect(throws: CancellationError.self) { try await pending.value }
    #expect(!model.forwarding)
    #expect(await transport.requests.filter { $0.url!.path.hasSuffix("/direct") }.count == 1)
    #expect(await transport.requests.allSatisfy { !$0.url!.path.hasSuffix("/forward") })
    await model.close(); _ = try await client.close()
}

@Test func betaChatAcceptsPublishedPluralPinUpdateEvent() throws {
    let event = try #require(try UserEvent.decode(Fixture.data([
        "version": 1, "id": UUID().uuidString, "type": "conversation.pins.updated",
        "data": ["conversationId": Fixture.conversationID.uuidString]
    ])))
    #expect(event.type == "conversation.pins.updated" && event.conversationID == Fixture.conversationID)
    #expect(event.message == nil) // The active conversation is reloaded for conversation-only events.
}

@Test @MainActor func demoForwardAndBulkDeleteAreScopedToTheVisibleConversation() throws {
    let store = DemoChatStore()
    let source = 0, target = 1
    let original = try #require(store.history[source]?.first)
    let second = try #require(store.history[source]?.last)
    #expect(store.forward(original.id, from: source, to: target))
    let copy = try #require(store.history[target]?.last)
    #expect(copy.id != original.id && copy.own && copy.forwarded == original.author)
    #expect(copy.files == original.files && copy.text == original.text)
    #expect(store.forward(copy.id, from: target, to: source))
    let forwardedAgain = try #require(store.history[source]?.last)
    #expect(forwardedAgain.forwarded == original.author)
    store.remove([original.id, second.id], in: source)
    #expect(store.history[source]?.contains(where: { $0.id == original.id || $0.id == second.id }) == false)
    #expect(store.history[target]?.last == copy)
    #expect(!store.forward(original.id, from: source, to: target))
    #expect(store.updated == [source, target])
}

@Test @MainActor func demoCommentActionsUseOnlyTheSelectedSessionAndConversation() throws {
    let store = DemoChatStore()
    let chat = 1, other = 0
    let original = try #require(store.history[chat]?.first)
    let outgoing = store.history[chat]?.first(where: \.own)
    let own = try #require(outgoing)
    let otherHistory = store.history[other]

    #expect(!store.edit(original.id, text: "Изменено", in: chat))
    store.deleteOwn(original.id, in: chat)
    #expect(store.history[chat]?.first == original)
    #expect(!store.reply(to: original.id, text: "Ответ", in: other))
    #expect(!store.reply(to: original.id, text: "   ", in: chat))
    #expect(store.reply(to: original.id, text: "  Ответ  ", in: chat))
    let reply = try #require(store.history[chat]?.last)
    #expect(reply.own && reply.replyTo == original.id && reply.text == "Ответ")

    #expect(store.edit(own.id, text: "Обновлённый текст", in: chat))
    store.togglePin(own.id, in: chat)
    store.toggleReaction("👍", for: own.id, in: chat)
    let edited = try #require(store.history[chat]?.first(where: { $0.id == own.id }))
    #expect(edited.edited && edited.text == "Обновлённый текст" && edited.files == own.files)
    #expect(edited.pinned && edited.reaction == "👍")
    store.toggleReaction("👍", for: own.id, in: chat)
    #expect(store.history[chat]?.first(where: { $0.id == own.id })?.reaction == nil)
    #expect(store.forward(own.id, from: chat, to: chat))
    let forwarded = try #require(store.history[chat]?.last)
    #expect(!store.edit(forwarded.id, text: "Изменено", in: chat))

    store.deleteOwn(own.id, in: chat)
    let deleted = try #require(store.history[chat]?.first(where: { $0.id == own.id }))
    #expect(deleted.deleted && !deleted.pinned && !deleted.canEdit && deleted.shareText.isEmpty)
    #expect(!store.forward(own.id, from: chat, to: other))
    #expect(!store.reply(to: own.id, text: "Ответ", in: chat))
    #expect(store.history[chat]?.last == forwarded)
    #expect(store.history[other] == otherHistory)
    let fresh = try #require(DemoChatStore().history[chat])
    #expect(fresh.count == 3 && !fresh.contains(where: \.deleted))
    #expect(fresh.first(where: \.own)?.text == own.text)
}

@Test @MainActor func forwardingReturnsTheConfirmedDestinationAndPreservesSourceHistory() async throws {
    let message = try Fixture.message(text: "Материалы встречи")
    let destination = UUID(), requestID = UUID()
    let forwarded = try Fixture.message(id: UUID(), requestID: requestID, conversation: destination, text: message.text)
    var copy = try JSONSerialization.jsonObject(with: WireJSON.encoder().encode(forwarded)) as! [String: Any]
    copy["forwardedFrom"] = ["senderName": message.senderName]
    let response = try Fixture.response(["items": [copy]])
    let transport = RoutedTransport { request, _ in
        if request.url?.lastPathComponent == "forward" {
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/api/v1/conversations/\(destination.uuidString.lowercased())/messages/forward")
            let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as! [String: Any]
            #expect((body["sourceId"] as? String).flatMap(UUID.init(uuidString:)) == Fixture.conversationID)
            #expect((body["clientRequestId"] as? String).flatMap(UUID.init(uuidString:)) == requestID)
            #expect((body["messageIds"] as? [String])?.compactMap(UUID.init(uuidString:)) == [message.id])
            return response
        }
        if request.url?.lastPathComponent == "messages" { return try chatResponse([message]) }
        return try Fixture.response(["item": JSONSerialization.jsonObject(with: Fixture.conversation())])
    }
    let client = try chatClient(transport)
    let model = MessagingModel(client: client, sockets: ChatActionSockets(), hiddenMessages: MemoryHiddenChatMessagesStore())
    await model.open(Fixture.conversationID)
    let confirmedDestination = try await model.forward([message], to: destination, requestID: requestID)
    #expect(confirmedDestination == destination)
    #expect(model.timeline.messages.map(\.id) == [message.id])
    await model.close()
    _ = try await client.close()
}

@Test func chatHeaderPersonalActionsUseAccountScopedEndpoints() async throws {
    let id = Fixture.conversationID
    let transport = RoutedTransport { request, _ in
        if request.httpMethod == "PATCH" {
            let payload = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Bool]
            #expect(payload == ["notificationsEnabled": false])
            var item = try #require(JSONSerialization.jsonObject(with: Fixture.conversation()) as? [String: Any])
            item["notificationsEnabled"] = false
            return try Fixture.response(["item": item])
        }
        return NetworkResponse(status: 204)
    }
    let repository = try MessagingRepository(client: chatClient(transport))
    let updated = try await repository.setNotifications(id, enabled: false)
    #expect(updated.id == id && !updated.notificationsEnabled)
    try await repository.clearDirectHistory(id)
    try await repository.hideDirectConversation(id)
    let requests = await transport.requests
    let path = "/api/v1/conversations/" + id.uuidString.lowercased()
    #expect(requests.compactMap(\.httpMethod) == ["PATCH", "POST", "POST"])
    #expect(requests.map { $0.url?.path } == [path + "/preferences", path + "/clear-history", path + "/hide"])
}
