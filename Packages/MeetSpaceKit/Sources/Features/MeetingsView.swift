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
        var status: ConferenceTimelineView
        let owner: String
        var cancelled: Bool

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

    }

    static let meetings = [
        Meeting(1, "Дизайн-синхронизация", day: 12, hour: 10, duration: 45, count: 5, owner: "Анна Кузнецова"),
        Meeting(2, "Обсуждение новой версии", day: 12, hour: 13, minute: 30, duration: 30, count: 8),
        Meeting(3, "Планы на неделю", day: 13, hour: 11, duration: 30, count: 4),
        Meeting(7, "Комната команды", count: 5),
        Meeting(4, "Рабочая встреча разработки", day: 12, hour: 9, minute: 30, duration: 60, count: 3, status: .active, owner: "Максим Петров"),
        Meeting(9, "Ежедневная синхронизация", day: 16, hour: 10, count: 6, status: .active),
        Meeting(5, "Продукт. Следующая глава", day: 9, hour: 14, duration: 45, count: 6, status: .past),
        Meeting(6, "Демо новой версии", day: 8, hour: 11, duration: 60, count: 8, status: .past, owner: "Анна Кузнецова"),
        Meeting(8, "Обсуждение бюджета", day: 7, hour: 16, duration: 30, count: 3, status: .past, cancelled: true)
    ]

}

@MainActor @Observable final class DemoMeetingsState {
    var meetings = DemoData.meetings
    var members: [Int: MeetingMembership] = [9: .left]

    func start(_ id: Int) {
        guard let index = meetings.firstIndex(where: { $0.id == id && $0.owner == "Вы" && $0.status == .upcoming }) else { return }
        meetings[index].status = .active
    }

    func finish(_ id: Int) {
        guard let index = meetings.firstIndex(where: { $0.id == id && $0.owner == "Вы" && $0.status != .past }) else { return }
        meetings[index].cancelled = meetings[index].status == .upcoming
        meetings[index].status = .past
        members.removeValue(forKey: id)
    }
}

struct MeetingsView: View {
    @Bindable var model: AppModel
    @State private var selected: DemoData.Meeting?
    @State private var initialMaterials = false
    @State private var afterDetails: (() -> Void)?

    var body: some View {
        MeetingsDashboard(items: model.demoMeetings.meetings.map(\.listItem), zone: DemoData.meetingZone,
            state: model.contentState, retry: { model.contentState = .content },
            actions: MeetingsActions(create: { model.navigate(.newMeeting) }, schedule: { model.navigate(.scheduleMeeting) },
                join: { model.navigate(.joinMeeting) }, calendar: { model.navigate(.calendar) },
                recordings: { model.navigate(.recordings) }, folders: { model.navigate(.folders) },
                notifications: { model.presentWorkspaceNotifications() }),
            open: { meeting in
                if meeting.status == .past { initialMaterials = true; selected = meeting }
                else { model.showDemoPrejoin(title: meeting.title) }
            },
            details: { initialMaterials = false; selected = $0 }, identifier: { "meeting.\($0.id)" })
            .workspaceFormPresentation(item: $selected, onDismiss: {
                let action = afterDetails
                afterDetails = nil
                action?()
            }) { meeting in
                DemoMeetingDetails(model: model, meeting: meeting, showingMaterials: initialMaterials,
                    close: { selected = nil }, openCall: {
                        afterDetails = { model.showDemoPrejoin(title: tr(meeting.title)) }
                        selected = nil
                    }, openRecording: { id in
                        afterDetails = { model.navigate(.recording(id)) }
                        selected = nil
                    })
            }
    }
}

struct DemoMeetingDetails: View {
    let model: AppModel
    let meeting: DemoData.Meeting
    @State var showingMaterials: Bool
    let close: () -> Void
    let openCall: () -> Void
    let openRecording: (Int) -> Void
    @State private var showingFolders = false

    var body: some View {
        let item = meeting.listItem
        let member = model.demoMeetings.members[meeting.id] ?? MeetingMembership.none
        Group {
            if showingMaterials {
                WorkspaceFormSheet(title: "Материалы встречи", identifier: "meetingMaterials", centered: true, close: close) {
                    Button(tr("О встрече")) { showingMaterials = false }
                    Text(verbatim: item.title).font(MSTheme.font(18, weight: .semibold))
                    let entries = model.demoRecordings.filter { $0.title == item.title }
                    if entries.isEmpty { Text(tr("Для этой встречи пока нет записей.")).foregroundStyle(MSTheme.muted) }
                    ForEach(entries) { entry in
                        Button {
                            if let index = Int(entry.id) { openRecording(index) }
                        } label: {
                            Label(tr(entry.kind.title), systemImage: entry.kind.icon)
                        }.buttonStyle(MSButtonStyle(primary: false))
                    }
                }
            } else {
                MeetingActionCard(item: item, scheduled: meeting.start, started: meeting.status == .active ? meeting.start : nil,
                    zone: DemoData.meetingZone, waitingRoom: false, membership: member,
                    invitation: .demo(meeting.id),
                    call: {
                        if item.mine && item.status == .upcoming { model.demoMeetings.start(meeting.id) }
                        openCall()
                    }, toggleMembership: {
                        model.demoMeetings.members[meeting.id] = member == .joined || meeting.status == .upcoming ? .left : .joined
                    }, folder: { showingFolders = true }, materials: { showingMaterials = true },
                    finish: { model.demoMeetings.finish(meeting.id); close() }, close: close)
            }
        }.sheet(isPresented: $showingFolders) {
            WorkspaceFolderPicker(demo: model.demoFolders, item: .meeting(meeting.id), title: item.title)
        }
    }
}
