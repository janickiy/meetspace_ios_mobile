import Foundation
import Testing
import MeetSpaceCore
import MeetSpaceAPI
@testable import MeetSpaceFeatures

private enum CalendarFixture {
    static let first = UUID(uuidString: "A1111111-1111-4111-8111-111111111111")!
    static let second = UUID(uuidString: "A2222222-2222-4222-8222-222222222222")!
    static let at = ISO8601DateFormatter().date(from: "2099-02-10T10:00:00Z")!
    static var period: DateInterval { MeetingCalendar.interval(containing: at, mode: .month, in: TimeZone(secondsFromGMT: 0)!) }
    static func meeting(_ id: UUID = first, at: Date = at, status: String = "scheduled", owner: UUID = Fixture.userID) -> Conference {
        Conference(id: id, ownerId: owner, title: "Запланированная встреча", status: status, createdAt: at.addingTimeInterval(-3600), updatedAt: at, scheduledAt: at, plannedDurationMin: 30)
    }
    static func object(_ value: Conference) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: WireJSON.encoder().encode(value)) as! [String: Any]
    }
    static func repository(_ transport: any RequestTransport) throws -> CalendarRepository {
        CalendarRepository(client: AuthenticatedClient(account: try Fixture.account(), credentials: Fixture.credentials(), secureStore: TestSecrets(), transport: transport))
    }
}

@Test func calendarRESTSerializesUTCAndUsesAuditedScheduleCancelTimeline() async throws {
    let path = "/api/v1/conferences/" + CalendarFixture.first.uuidString.lowercased()
    let at = CalendarFixture.at
    let transport = RoutedTransport { request, _ in
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        switch (request.httpMethod, request.url?.path) {
        case ("GET", "/api/v1/me/conferences"):
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
            #expect(query["view"] == "upcoming" && query["scope"] == "owned" && query["sort"] == "oldest")
            #expect(query["from"] == "2099-02-01T00:00:00Z" && query["to"] == "2099-03-01T00:00:00Z")
            // Backend includes `to`; client must omit the next period's first event.
            return try Fixture.response(["items": [CalendarFixture.object(CalendarFixture.meeting()), CalendarFixture.object(CalendarFixture.meeting(CalendarFixture.second, at: CalendarFixture.period.end))], "nextCursor": NSNull()])
        case ("POST", "/api/v1/conferences"), ("PUT", path + "/schedule"):
            let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as! [String: Any]
            #expect(body["scheduledAt"] as? String == "2099-02-10T10:00:00Z")
            #expect(body["plannedDurationMin"] as? Int == 30)
            if request.httpMethod == "POST" { #expect(body["title"] as? String == "Встреча") }
            else { #expect(Set(body.keys) == ["scheduledAt", "plannedDurationMin"]) }
            return try Fixture.response(["item": CalendarFixture.object(CalendarFixture.meeting())])
        case ("POST", path + "/cancel"): return try Fixture.response(["item": CalendarFixture.object(CalendarFixture.meeting(status: "cancelled"))])
        default: Issue.record("Unexpected calendar endpoint"); throw APIError.invalidResponse
        }
    }
    let repository = try CalendarFixture.repository(transport)
    let page = try await repository.timeline(view: .upcoming, scope: .owned, interval: CalendarFixture.period)
    #expect(page.items.map(\.id) == [CalendarFixture.first])
    _ = try await repository.create(title: "  Встреча  ", at: at, duration: 30, waitingRoom: true)
    _ = try await repository.reschedule(CalendarFixture.first, at: at, duration: 30)
    _ = try await repository.cancel(CalendarFixture.first)
    await #expect(throws: ClientError.invalidInput) { try await repository.reschedule(CalendarFixture.first, at: Date.distantPast, duration: 30) }
    #expect(await transport.requests.count == 4)
}

@Test @MainActor func calendarPartialFeedsAndPaginationDoNotHideFailuresOrDuplicateMeetings() async throws {
    let transport = RoutedTransport { request, _ in
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        let view = query.first { $0.name == "view" }?.value
        if view == "active" { return NetworkResponse(status: 403) }
        if view == "past" { return try Fixture.response(["items": [], "nextCursor": NSNull()]) }
        let more = query.contains { $0.name == "cursor" }
        return try Fixture.response(["items": more ? [CalendarFixture.object(CalendarFixture.meeting()), CalendarFixture.object(CalendarFixture.meeting(CalendarFixture.second))] : [CalendarFixture.object(CalendarFixture.meeting())], "nextCursor": more ? NSNull() : "cursor-fixture" as Any])
    }
    let model = CalendarModel(repository: try CalendarFixture.repository(transport), preferences: MemoryCalendarPreferencesStore(CalendarPreferences(timeZoneIdentifier: "UTC", displayMode: .month)), now: CalendarFixture.at)
    await model.initialize()
    #expect(model.meetings.count == 1 && model.hasMore && model.feedErrors.count == 1)
    await model.load(more: true)
    #expect(model.meetings.count == 2 && !model.hasMore && model.feedErrors.count == 1)
    #expect(!model.canManage(CalendarFixture.meeting(owner: UUID())))
    #expect(!model.canManage(CalendarFixture.meeting(status: "active")))
    #expect(model.canManage(CalendarFixture.meeting()))
    model.close(); #expect(model.meetings.isEmpty)
}

private actor CalendarGate {
    private(set) var waiting = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func hold() async { waiting += 1; await withCheckedContinuation { continuations.append($0) } }
    func release() { for c in continuations { c.resume() }; continuations = [] }
}

@Test @MainActor func calendarCloseFencesInflightLoadsAndAmbiguousCreateRequiresReview() async throws {
    let gate = CalendarGate()
    let transport = RoutedTransport { request, _ in
        if request.httpMethod == "POST" { throw APIError.timeout }
        await gate.hold()
        return try Fixture.response(["items": [CalendarFixture.object(CalendarFixture.meeting())], "nextCursor": NSNull()])
    }
    let model = CalendarModel(repository: try CalendarFixture.repository(transport), now: CalendarFixture.at)
    #expect(await model.create(title: "Встреча", at: CalendarFixture.at, duration: 30, waitingRoom: false) == false)
    #expect(model.creationUncertain)
    #expect(await model.create(title: "Встреча", at: CalendarFixture.at, duration: 30, waitingRoom: false) == false)
    #expect(await transport.requests.count == 1)
    model.acknowledgeCreationCheck(); #expect(!model.creationUncertain)
    let load = Task { await model.load() }
    for _ in 0..<1000 { if await gate.waiting == 3 { break }; await Task.yield() }
    #expect(await gate.waiting == 3)
    model.close(); await gate.release(); await load.value
    #expect(model.meetings.isEmpty && model.state == .empty && !model.loading && model.error == nil)
}
