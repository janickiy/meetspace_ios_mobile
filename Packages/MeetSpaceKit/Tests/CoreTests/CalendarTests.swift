import Foundation
import Testing
import MeetSpaceCore

private func calendarInstant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

@Test func calendarPeriodsRespectDSTAndExclusiveMonthBoundary() throws {
    let ny = try #require(TimeZone(identifier: "America/New_York"))
    let spring = MeetingCalendar.interval(containing: calendarInstant("2026-03-08T12:00:00Z"), mode: .week, in: ny)
    let autumn = MeetingCalendar.interval(containing: calendarInstant("2026-11-01T12:00:00Z"), mode: .week, in: ny)
    #expect(spring.duration == 167 * 3600)
    #expect(autumn.duration == 169 * 3600)
    #expect(MeetingCalendar.days(in: spring, zone: ny).count == 7)
    #expect(MeetingCalendar.days(in: autumn, zone: ny).count == 7)
    for day in MeetingCalendar.days(in: spring, zone: ny) { #expect(MeetingCalendar.calendar(in: ny).component(.hour, from: day) == 0) }
    let leap = MeetingCalendar.interval(containing: calendarInstant("2028-02-15T12:00:00Z"), mode: .month, in: ny)
    #expect(MeetingCalendar.days(in: leap, zone: ny).count == 29)
    #expect(MeetingCalendar.includes(leap.start, interval: leap))
    #expect(!MeetingCalendar.includes(leap.end, interval: leap))
}

@Test func calendarPresentationDoesNotChangeInstantAcrossZonesOrRepeatedHours() throws {
    let moscow = try #require(TimeZone(identifier: "Europe/Moscow"))
    let ny = try #require(TimeZone(identifier: "America/New_York"))
    let instant = calendarInstant("2026-11-01T21:30:00Z")
    #expect(MeetingCalendar.calendar(in: moscow).component(.day, from: instant) == 2)
    #expect(MeetingCalendar.calendar(in: ny).component(.day, from: instant) == 1)
    let first = calendarInstant("2026-11-01T01:30:00-04:00"), second = calendarInstant("2026-11-01T01:30:00-05:00")
    #expect(second.timeIntervalSince(first) == 3600)
    #expect(MeetingCalendar.calendar(in: ny).component(.hour, from: first) == 1)
    #expect(MeetingCalendar.calendar(in: ny).component(.hour, from: second) == 1)
    #expect(throws: ClientError.invalidInput) { try MeetingCalendar.validateSchedule(at: Date(timeIntervalSince1970: .infinity), duration: 30) }
    #expect(throws: ClientError.invalidInput) { try MeetingCalendar.validateSchedule(at: Date().addingTimeInterval(3600), duration: 1441) }
}
