import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

/// Fixtures are reachable only after explicit entry into the demo workspace.
enum DemoData {
    static let meetingZone = TimeZone(identifier: "Europe/Moscow")!

    struct Meeting: Identifiable {
        let id: Int
        let title: String
        let start: Date?
        let duration: Int?
        let count: Int
        let status: ConferenceTimelineView
        let owner: String
        let cancelled: Bool

        init(_ id: Int, _ title: String, day: Int? = nil, hour: Int = 0, minute: Int = 0,
             duration: Int? = nil, count: Int, status: ConferenceTimelineView = .upcoming,
             owner: String = "Вы", cancelled: Bool = false) {
            self.id = id
            self.title = title
            self.start = day.flatMap { MeetingCalendar.calendar(in: meetingZone).date(from:
                DateComponents(year: 2026, month: 10, day: $0, hour: hour, minute: minute)) }
            self.duration = duration
            self.count = count
            self.status = status
            self.owner = owner
            self.cancelled = cancelled
        }

        var listItem: MeetingListItem<Self> {
            MeetingListItem(value: self, title: tr(title), date: start, duration: duration, status: status,
                            cancelled: cancelled, mine: owner == "Вы", owner: tr(owner), attendees: count)
        }
        // Also used by the demo meeting detail.
        var day: String { start.map { calendarText($0, format: "d", zone: meetingZone) } ?? tr("Без даты") }
        var month: String { start.map { calendarText($0, format: "MMMM", zone: meetingZone) } ?? "" }
        var time: String {
            guard let start else { return tr("В удобное время") }
            let from = calendarText(start, format: "HH:mm", zone: meetingZone)
            guard let duration else { return from }
            return from + " – " + calendarText(start.addingTimeInterval(Double(duration * 60)), format: "HH:mm", zone: meetingZone)
        }
    }

    static let meetings = [
        Meeting(1, "Дизайн-синхронизация", day: 12, hour: 10, duration: 45, count: 5, owner: "Анна Кузнецова"),
        Meeting(2, "Обсуждение новой версии", day: 12, hour: 13, minute: 30, duration: 30, count: 8),
        Meeting(3, "Планы на неделю", day: 13, hour: 11, duration: 30, count: 4),
        Meeting(7, "Комната команды", count: 5),
        Meeting(4, "Рабочая встреча разработки", day: 12, hour: 9, minute: 30, duration: 60, count: 3, status: .active, owner: "Максим Петров"),
        Meeting(5, "Продукт. Следующая глава", day: 9, hour: 14, duration: 45, count: 6, status: .past),
        Meeting(6, "Демо новой версии", day: 8, hour: 11, duration: 60, count: 8, status: .past, owner: "Анна Кузнецова"),
        Meeting(8, "Обсуждение бюджета", day: 7, hour: 16, duration: 30, count: 3, status: .past, cancelled: true)
    ]

}

struct MeetingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        MeetingsDashboard(items: DemoData.meetings.map(\.listItem), zone: DemoData.meetingZone,
            state: model.contentState, retry: { model.contentState = .content },
            actions: MeetingsActions(create: { model.navigate(.newMeeting) }, schedule: { model.navigate(.scheduleMeeting) },
                join: { model.navigate(.joinMeeting) }, calendar: { model.navigate(.calendar) },
                recordings: { model.navigate(.recordings) }, folders: { model.navigate(.folders) },
                notifications: { model.presentWorkspaceNotifications() }),
            open: { meeting in
                if meeting.status == .past { model.navigate(.meetingDetails(meeting.id)) }
                else { model.showDemoPrejoin(title: meeting.title) }
            },
            details: { model.navigate(.meetingDetails($0.id)) }, identifier: { "meeting.\($0.id)" })
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("screen.meetings")
    }
}
