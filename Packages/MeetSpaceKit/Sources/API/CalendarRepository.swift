import Foundation
import MeetSpaceCore

public struct CalendarRepository: Sendable {
    public let userID: UUID
    private let client: AuthenticatedClient
    private let conferences: ConferenceRepository
    public init(client: AuthenticatedClient) {
        self.client = client; userID = client.account.user.id; conferences = ConferenceRepository(client: client)
    }
    public func timeline(view: ConferenceTimelineView, scope: ConferenceTimelineScope = .all,
                         interval: DateInterval, cursor: String? = nil, limit: Int = 100) async throws -> ConferenceTimelinePage {
        guard MeetingCalendar.isValidInstant(interval.start), MeetingCalendar.isValidInstant(interval.end), interval.duration > 0,
              (1...100).contains(limit), cursor.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true else { throw ClientError.invalidInput }
        let formatter = ISO8601DateFormatter()
        var query = [URLQueryItem(name: "view", value: view.rawValue), URLQueryItem(name: "scope", value: scope.rawValue),
                     URLQueryItem(name: "sort", value: "oldest"), URLQueryItem(name: "from", value: formatter.string(from: interval.start)),
                     URLQueryItem(name: "to", value: formatter.string(from: interval.end)), URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        let page = try decodeJSON(ConferenceTimelinePage.self, from: await client.request("GET", path: ["me", "conferences"], query: query))
        guard page.items.count <= limit, Set(page.items.map(\.id)).count == page.items.count,
              page.nextCursor.map({ !$0.isEmpty && $0.utf8.count <= 256 && $0 != cursor }) ?? true,
              page.items.allSatisfy(Self.validMeeting) else { throw APIError.invalidResponse }
        // The backend's upper bound is inclusive. UI periods are explicitly half-open.
        return ConferenceTimelinePage(items: page.items.filter { MeetingCalendar.includes(MeetingCalendar.timelineDate($0), interval: interval) }, nextCursor: page.nextCursor)
    }
    public func create(title: String, at: Date, duration: Int?, waitingRoom: Bool) async throws -> Conference {
        try MeetingCalendar.validateSchedule(at: at, duration: duration)
        let result = try await conferences.create(title: title, waitingRoomEnabled: waitingRoom, scheduledAt: at, plannedDurationMin: duration)
        guard Self.validMeeting(result), result.status == "scheduled", result.scheduledAt != nil else { throw APIError.invalidResponse }
        return result
    }
    public func reschedule(_ id: UUID, at: Date, duration: Int?) async throws -> Conference {
        try MeetingCalendar.validateSchedule(at: at, duration: duration)
        struct Body: Encodable { let scheduledAt: Date; let plannedDurationMin: Int? }
        let result = try decodeJSON(ItemResponse<Conference>.self, from: await client.request("PUT", path: ["conferences", id.uuidString.lowercased(), "schedule"],
            body: WireJSON.encoder().encode(Body(scheduledAt: at, plannedDurationMin: duration)))).item
        guard result.id == id, result.ownerId == userID, result.status == "scheduled" else { throw ClientError.scopeMismatch }
        guard Self.validMeeting(result), result.scheduledAt != nil else { throw APIError.invalidResponse }
        return result
    }
    public func cancel(_ id: UUID) async throws -> Conference {
        let result = try await conferences.transition(id, action: "cancel")
        guard result.ownerId == userID, result.status == "cancelled", Self.validMeeting(result) else { throw ClientError.scopeMismatch }
        return result
    }
    private static func validMeeting(_ meeting: Conference) -> Bool {
        [meeting.createdAt, meeting.updatedAt, meeting.scheduledAt, meeting.finishedAt, meeting.startedAt].compactMap { $0 }.allSatisfy(MeetingCalendar.isValidInstant)
            && (meeting.plannedDurationMin.map({ (1...1440).contains($0) && meeting.scheduledAt != nil }) ?? true)
            && (1...200).contains(meeting.title.unicodeScalars.count)
    }
}
