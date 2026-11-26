import Foundation
import Testing
import MeetSpaceAPI
@testable import MeetSpaceFeatures

private actor InboxPagesFixture {
    let first = UUID()
    let second = UUID()
    private(set) var acknowledged: [UUID] = []
    private var failSecondOnce = true
    private var cycle: Bool

    /// Готовит страницы уведомлений с обычной или циклической пагинацией.
    /// - Parameter cycle: Повторять ли курсор для проверки защиты от цикла.
    init(cycle: Bool = false) { self.cycle = cycle }

    /// Возвращает страницу входящих уведомлений или ответ на изменение отметки о прочтении.
    /// - Parameter request: Запрос тестируемого клиента.
    func respond(_ request: URLRequest) throws -> NetworkResponse {
        guard let url = request.url else { throw APIError.invalidResponse }
        if request.httpMethod == "GET" {
            let tail = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "cursor" })?.value == "next"
            let next: Any = !tail || cycle ? "next" : NSNull() as Any
            return try Fixture.response(["items": [item(tail ? second : first)], "nextCursor": next,
                                         "unreadCount": 2 - acknowledged.count])
        }
        guard let id = UUID(uuidString: url.deletingLastPathComponent().lastPathComponent), url.lastPathComponent == "read" else {
            throw APIError.invalidResponse
        }
        if id == second && failSecondOnce {
            failSecondOnce = false
            return NetworkResponse(status: 503)
        }
        if !acknowledged.contains(id) { acknowledged.append(id) }
        return try Fixture.response(["item": item(id)])
    }

    /// Формирует тестовое уведомление о готовности записи.
    /// - Parameter id: Идентификатор уведомления.
    private func item(_ id: UUID) -> [String: Any] {
        var result: [String: Any] = ["id": id.uuidString, "userId": Fixture.userID.uuidString,
                                     "type": "recording.ready", "payload": [:], "createdAt": "2026-11-22T10:00:00Z"]
        if acknowledged.contains(id) { result["readAt"] = "2026-11-22T10:01:00Z" }
        return result
    }
}

@Test @MainActor func inboxReadAllPaginatesKeepsAcknowledgedStateAndRetriesAfterAnError() async throws {
    let fixture = InboxPagesFixture()
    let transport = RoutedTransport { request, _ in try await fixture.respond(request) }
    let client = AuthenticatedClient(account: try Fixture.account(), credentials: Fixture.credentials(), secureStore: TestSecrets(), transport: transport)
    let inbox = WorkspaceInbox()
    await inbox.refresh(using: client, demo: false)
    #expect(inbox.events.count == 1 && inbox.unread == 2 && inbox.more)
    await inbox.readAll()
    #expect(inbox.error != nil && inbox.unread == 1)
    #expect(inbox.events.map(\.isRead) == [true, false])
    #expect(await fixture.acknowledged == [fixture.first])
    await inbox.readAll()
    #expect(inbox.error == nil && inbox.unread == 0 && !inbox.more)
    #expect(inbox.events.map(\.isRead) == [true, true])
    let reads = await transport.requests.filter { $0.httpMethod == "POST" }
    #expect(reads.filter { $0.url?.path.contains(fixture.first.uuidString.lowercased()) == true }.count == 1)
    #expect(await fixture.acknowledged == [fixture.first, fixture.second])
    _ = try await client.close()
}

@Test @MainActor func inboxReadAllStopsOnACyclicServerCursorWithoutClaimingSuccess() async throws {
    let fixture = InboxPagesFixture(cycle: true)
    let client = AuthenticatedClient(account: try Fixture.account(), credentials: Fixture.credentials(), secureStore: TestSecrets(),
                                     transport: RoutedTransport { request, _ in try await fixture.respond(request) })
    let inbox = WorkspaceInbox()
    await inbox.refresh(using: client, demo: false)
    await inbox.readAll()
    #expect(inbox.error != nil && inbox.unread == 1 && !inbox.busy)
    #expect(await fixture.acknowledged == [fixture.first])
    _ = try await client.close()
}
