import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

struct CalendarWeekStrip: View {
    let selectedDay: Date
    let zone: TimeZone
    let eventDays: [Date]
    let select: (Date) -> Void
    @ScaledMetric private var dayMinimumWidth: CGFloat = 44

    var body: some View {
        ViewThatFits(in: .horizontal) {
            days
            ScrollView(.horizontal, showsIndicators: false) { days }
        }
        .background(MSTheme.surface, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(MSTheme.line))
    }

    private var days: some View {
        let calendar = MeetingCalendar.calendar(in: zone)
        let interval = MeetingCalendar.interval(containing: selectedDay, mode: .week, in: zone)
        return HStack(spacing: 7) {
            ForEach(MeetingCalendar.days(in: interval, zone: zone), id: \.self) { day in
                let selected = calendar.isDate(day, inSameDayAs: selectedDay)
                let hasEvent = eventDays.contains { calendar.isDate($0, inSameDayAs: day) }
                Button { select(day) } label: {
                    VStack(spacing: 8) {
                        Text(calendarText(day, format: "EE", zone: zone)).font(MSTheme.font(10))
                            .accessibilityIdentifier("calendar.weekday.\((calendar.component(.weekday, from: day) + 5) % 7)")
                        Text(calendarText(day, format: "d", zone: zone)).font(MSTheme.font(17, weight: .semibold))
                        Circle().fill(hasEvent ? (selected ? MSTheme.surface : MSTheme.accent) : .clear)
                            .frame(width: 4, height: 4)
                    }.frame(minWidth: dayMinimumWidth, maxWidth: .infinity, minHeight: 74)
                        .background(selected ? MSTheme.accent : MSTheme.surface, in: RoundedRectangle(cornerRadius: 13))
                        .foregroundStyle(selected ? MSTheme.surface : MSTheme.ink)
                }.buttonStyle(.plain).accessibilityLabel(calendarText(day, format: "d MMMM yyyy", zone: zone))
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }.padding(12)
    }
}

struct CalendarDayTimeline<Event: Identifiable, Card: View>: View {
    let events: [Event]
    let zone: TimeZone
    let time: (Event) -> Date
    @ViewBuilder let eventCard: (Event) -> Card
    @ScaledMetric private var timeColumnWidth: CGFloat = 43

    var body: some View {
        let calendar = MeetingCalendar.calendar(in: zone)
        let byHour = Dictionary(grouping: events) { calendar.component(.hour, from: time($0)) }
        let hours = min(9, byHour.keys.min() ?? 9)...max(18, byHour.keys.max() ?? 18)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(hours, id: \.self) { hour in
                HStack(alignment: .top, spacing: 10) {
                    Text(String(format: "%02d:00", hour)).font(MSTheme.font(10)).foregroundStyle(MSTheme.muted)
                        .frame(width: timeColumnWidth, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                        .accessibilityIdentifier("calendar.hour.\(hour)")
                    VStack(spacing: 6) {
                        Rectangle().fill(MSTheme.line).frame(height: 1)
                        ForEach(byHour[hour] ?? [], content: eventCard)
                    }.frame(maxWidth: .infinity, minHeight: 78, alignment: .top)
                }
            }
        }
    }
}
