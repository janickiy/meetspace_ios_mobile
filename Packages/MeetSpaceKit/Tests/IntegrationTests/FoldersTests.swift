import Foundation
import Testing
import MeetSpaceCore
import MeetSpaceAPI
import MeetSpaceFeatures

private enum FolderFixture {
    static let id = UUID(uuidString: "F1111111-1111-4111-8111-111111111111")!
    static func object(_ id: UUID = id) -> [String: Any] {
        ["id": id.uuidString, "name": "Проект", "position": 0, "itemCount": 1, "conversationCount": 1,
         "conferenceCount": 0, "createdAt": "2026-11-06T10:00:00Z", "updatedAt": "2026-11-06T10:00:00Z"]
    }
    static func repository(_ transport: any RequestTransport) throws -> FoldersRepository {
        FoldersRepository(client: AuthenticatedClient(account: try Fixture.account(), credentials: Fixture.credentials(), secureStore: TestSecrets(), transport: transport))
    }
}

@Test func folderValidationNormalizesUnicodeAndRejectsHiddenControls() throws {
    #expect(try FolderValidation.text("  Cafe\u{301}  ", maximum: 50, required: true) == "Café")
    #expect(try FolderValidation.text("👩‍💻", maximum: 50, required: true) == "👩‍💻")
    for name in [" ", String(repeating: "я", count: 51), "a\u{202E}b", "a\nb", "a\0b"] {
        #expect(throws: ClientError.invalidInput) { try FolderValidation.text(name, maximum: 50, required: true) }
    }
}

@Test func folderDeletionAndRemovalNeverDeleteUnderlyingContent() async throws {
    let path = "/api/v1/folders/" + FolderFixture.id.uuidString.lowercased()
    let transport = RoutedTransport { request, _ in
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
        if request.url?.path == path { #expect(request.httpMethod == "DELETE"); return try Fixture.response(["status": "success"]) }
        #expect(request.url?.path == path + "/items/conversation/" + Fixture.conversationID.uuidString.lowercased())
        #expect(request.httpMethod == "DELETE")
        return try Fixture.response(["item": FolderFixture.object()])
    }
    let repository = try FolderFixture.repository(transport)
    _ = try await repository.setItem(FolderFixture.id, kind: .conversation, id: Fixture.conversationID, included: false)
    try await repository.delete(FolderFixture.id)
    #expect(await transport.requests.count == 2)
}

@Test func foldersUseOpaquePaginationAndCompleteOrderAndRejectScopeMismatch() async throws {
    let other = UUID()
    let transport = RoutedTransport { request, _ in
        let path = request.url!.path
        if path == "/api/v1/folder-items" {
            let q = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            #expect(q.contains(URLQueryItem(name: "folderId", value: FolderFixture.id.uuidString.lowercased())))
            #expect(q.contains(URLQueryItem(name: "before", value: "opaque+/cursor=")))
            #expect(q.contains(URLQueryItem(name: "type", value: "conversation")))
            let conversation = try JSONSerialization.jsonObject(with: Fixture.conversation())
            return try Fixture.response(["items": [["type": "conversation", "item": conversation, "inFolder": true]], "nextCursor": "next"])
        }
        if path == "/api/v1/folders/order" {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: [String]]
            #expect(body["ids"] == [other.uuidString.lowercased(), FolderFixture.id.uuidString.lowercased()])
            return try Fixture.response(["items": [FolderFixture.object(other), FolderFixture.object()]])
        }
        return try Fixture.response(["item": FolderFixture.object(other)])
    }
    let repository = try FolderFixture.repository(transport)
    let page = try await repository.items(FolderFixture.id, candidates: true, filter: .conversation, before: "opaque+/cursor=")
    #expect(page.items.first?.conversation?.id == Fixture.conversationID && page.items.first?.inFolder == true)
    #expect(try await repository.order([other, FolderFixture.id]).count == 2)
    await #expect(throws: ClientError.invalidInput) { try await repository.order([other, other]) }
    await #expect(throws: ClientError.scopeMismatch) { try await repository.rename(FolderFixture.id, name: "Новое") }
    #expect(await transport.requests.count == 3)
}

private actor FolderGate {
    var continuation: CheckedContinuation<Void, Never>?
    var waiting = false
    func wait() async { waiting = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
@Test @MainActor func foldersDiscardResponsesAfterAccountClosed() async throws {
    let gate = FolderGate()
    let transport = RoutedTransport { _, _ in
        await gate.wait(); return try Fixture.response(["items": [FolderFixture.object()]])
    }
    let model = FoldersModel(repository: try FolderFixture.repository(transport))
    let loading = Task { await model.load() }
    for _ in 0..<100 { if await gate.waiting { break }; try await Task.sleep(for: .milliseconds(5)) }
    #expect(await gate.waiting)
    model.close(); await gate.release(); await loading.value
    #expect(model.folders.isEmpty && model.selected == nil && model.error == nil)
    #expect(await model.save(name: "Новая") == false)
    #expect(await transport.requests.count == 1)
}

@Test func foldersRejectMalformedListsPagesAndGuestScopes() async throws {
    var negative = FolderFixture.object(); negative["itemCount"] = -1
    var inconsistent = FolderFixture.object(); inconsistent["conversationCount"] = 2
    let invalidLists = [[FolderFixture.object(), FolderFixture.object()], [negative], [inconsistent],
                        (0..<101).map { _ in FolderFixture.object(UUID()) }]
    for list in invalidLists {
        let data = try Fixture.data(["items": list])
        let transport = RoutedTransport { _, _ in NetworkResponse(status: 200, headers: ["content-type": "application/json"], data: data) }
        let repository = try FolderFixture.repository(transport)
        await #expect(throws: APIError.invalidResponse) { try await repository.list() }
    }
    let conversation = try JSONSerialization.jsonObject(with: Fixture.conversation())
    let duplicatePage = try Fixture.data(["items": [["type": "conversation", "item": conversation], ["type": "conversation", "item": conversation]]])
    let oversizedCursor = try Fixture.data(["items": [], "nextCursor": String(repeating: "x", count: 4097)])
    let repeatingCursor = try Fixture.data(["items": [], "nextCursor": "previous"])
    for data in [duplicatePage, oversizedCursor, repeatingCursor] {
        let transport = RoutedTransport { _, _ in NetworkResponse(status: 200, headers: ["content-type": "application/json"], data: data) }
        let repository = try FolderFixture.repository(transport)
        await #expect(throws: APIError.invalidResponse) { try await repository.items(FolderFixture.id, before: "previous") }
    }
    var raw = Fixture.user(); raw["guestConferenceId"] = UUID().uuidString
    let guest = AccountRecord(server: Fixture.origin, user: try WireJSON.decoder().decode(AccountUser.self, from: Fixture.data(raw)))
    let transport = RoutedTransport { _, _ in Issue.record("Guest folders request escaped account scope"); throw APIError.invalidResponse }
    let repository = FoldersRepository(client: AuthenticatedClient(account: guest, credentials: Fixture.credentials(), secureStore: TestSecrets(), transport: transport))
    await #expect(throws: ClientError.scopeMismatch) { try await repository.list() }
    await #expect(throws: ClientError.scopeMismatch) { try await repository.delete(FolderFixture.id) }
    #expect(await transport.requests.isEmpty)
}

@Test @MainActor func foldersRefreshRevokesRemovedSelectionAndPendingPage() async throws {
    let gate = FolderGate()
    let transport = RoutedTransport { request, _ in
        if request.url?.path == "/api/v1/folders" { return try Fixture.response(["items": []]) }
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if query.contains(where: { $0.name == "before" }) { await gate.wait() }
        let conversation = try JSONSerialization.jsonObject(with: Fixture.conversation())
        return try Fixture.response(["items": [["type": "conversation", "item": conversation]], "nextCursor": "next"])
    }
    let model = FoldersModel(repository: try FolderFixture.repository(transport))
    let folder = try WireJSON.decoder().decode(PersonalFolder.self, from: Fixture.data(FolderFixture.object()))
    await model.open(folder)
    #expect(model.items.count == 1 && model.nextCursor == "next")
    let nextPage = Task { await model.loadItems(more: true) }
    for _ in 0..<100 { if await gate.waiting { break }; try await Task.sleep(for: .milliseconds(5)) }
    #expect(await gate.waiting)
    await model.load()
    #expect(model.selected == nil && model.items.isEmpty && !model.loadingItems && model.nextCursor == nil)
    await gate.release(); await nextPage.value
    #expect(model.selected == nil && model.items.isEmpty && !model.loadingItems && model.nextCursor == nil)
    model.close()
}
