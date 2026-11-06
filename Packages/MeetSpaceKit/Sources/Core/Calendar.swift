import Foundation

public enum CalendarDisplayMode: String, Codable, CaseIterable, Sendable { case week, month, list }
public enum ConferenceTimelineView: String, CaseIterable, Sendable { case upcoming, active, past }
public enum ConferenceTimelineScope: String, CaseIterable, Sendable { case all, owned, participating }

public struct ConferenceTimelinePage: Decodable, Sendable {
    public let items: [Conference]
    public let nextCursor: String?
    public init(items: [Conference], nextCursor: String? = nil) { self.items = items; self.nextCursor = nextCursor }
}

public struct CalendarPreferences: Codable, Equatable, Sendable {
    public var timeZoneIdentifier: String
    public var displayMode: CalendarDisplayMode
    public init(timeZoneIdentifier: String = TimeZone.current.identifier, displayMode: CalendarDisplayMode = .week) {
        self.timeZoneIdentifier = timeZoneIdentifier; self.displayMode = displayMode
    }
    public func validated() throws -> Self {
        guard TimeZone(identifier: timeZoneIdentifier) != nil else { throw ClientError.invalidInput }
        return self
    }
}

public protocol CalendarPreferencesStore: Sendable {
    func load() async throws -> CalendarPreferences
    func save(_ preferences: CalendarPreferences) async throws
}

public actor MemoryCalendarPreferencesStore: CalendarPreferencesStore {
    private var value: CalendarPreferences
    public init(_ value: CalendarPreferences = CalendarPreferences()) { self.value = value }
    public func load() -> CalendarPreferences { value }
    public func save(_ preferences: CalendarPreferences) throws { value = try preferences.validated() }
}

/// The server stores an instant, not a wall-clock time or a named timezone.
public enum MeetingCalendar {
    public static func calendar(in zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone; calendar.locale = Locale(identifier: "ru_RU")
        calendar.firstWeekday = 2; calendar.minimumDaysInFirstWeek = 4
        return calendar
    }
    public static func interval(containing date: Date, mode: CalendarDisplayMode, in zone: TimeZone) -> DateInterval {
        let calendar = calendar(in: zone)
        // Calendar arithmetic preserves local midnight on 23/25-hour DST days.
        return calendar.dateInterval(of: mode == .week ? .weekOfYear : .month, for: date)!
    }
    public static func days(in interval: DateInterval, zone: TimeZone) -> [Date] {
        let calendar = calendar(in: zone)
        var values: [Date] = []; var current = interval.start
        while current < interval.end, values.count < 42 {
            values.append(current)
            guard let next = calendar.date(byAdding: .day, value: 1, to: current), next > current else { break }
            current = next
        }
        return values
    }
    public static func includes(_ instant: Date, interval: DateInterval) -> Bool {
        instant >= interval.start && instant < interval.end
    }
    public static func timelineDate(_ meeting: Conference) -> Date {
        meeting.finishedAt ?? meeting.scheduledAt ?? meeting.createdAt
    }
    public static func isValidInstant(_ date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite && date.timeIntervalSince1970 >= -62_135_596_800 && date.timeIntervalSince1970 < 253_402_300_800
    }
    public static func validateSchedule(at: Date, duration: Int?, now: Date = Date()) throws {
        guard isValidInstant(at), at > now, duration.map({ (1...1440).contains($0) }) ?? true else { throw ClientError.invalidInput }
    }
}
