import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

struct LiveMeetingsView: View {
    @Bindable var model: ConferenceWorkspace
    var calendar: CalendarModel?
    var recordings: RecordingsModel?
    var openCalendar: () -> Void = {}
    var openRecordings: () -> Void = {}
    var openFolders: () -> Void = {}
    var openNotifications: () -> Void = {}
    @State private var scheduling = false
    @State private var selected: Conference?
    @State private var creating = false
    @State private var joining = false
    @State private var title = ""
    @State private var invitation = ""
    @State private var waitingRoom = false
    @State private var openRecordingAfterDismiss = false
    var body: some View {
        MeetingsDashboard(items: model.meetings.map(listItem), zone: calendar?.zone ?? .current,
            state: model.state == .empty ? .content : model.state, error: model.error,
            retry: { Task { await model.load() } },
            loadMore: model.hasMore ? { await model.loadMore() } : nil, loadingMore: model.loadingMore,
            actions: MeetingsActions(create: { creating = true }, schedule: {
                if calendar != nil { scheduling = true } else { openCalendar() }
            }, join: { joining = true }, calendar: openCalendar, recordings: openRecordings,
                folders: openFolders, notifications: openNotifications),
            open: { meeting in
                if meeting.isClosed { selected = meeting }
                else { Task { await model.join(meeting) } }
            }, details: { selected = $0 }, identifier: { "conference.\($0.id.uuidString.lowercased())" })
            .disabled(model.busy).accessibilityIdentifier("screen.liveMeetings")
            .refreshable { await model.load() }
            .task {
                await calendar?.restorePreferences()
                await model.load()
            }
            .sheet(isPresented: $scheduling) {
                if let calendar { ScheduleMeetingForm(model: calendar, didSave: { Task { await model.load() } }) }
            }
            .sheet(item: $selected, onDismiss: {
                if openRecordingAfterDismiss { openRecordingAfterDismiss = false; openRecordings() }
            }) { meeting in
                LiveMeetingDetails(item: listItem(meeting), zone: calendar?.zone ?? .current, workspace: model,
                    recordings: recordings, openRecording: { openRecordingAfterDismiss = true; selected = nil })
            }
            .sheet(isPresented: $creating) {
                NavigationStack {
                    Form {
                        TextField(tr("Название встречи"), text: $title).accessibilityIdentifier("conferenceTitle")
                        Toggle(tr("Комната ожидания"), isOn: $waitingRoom)
                        Text(tr("Допуск участников определяется настройками и приглашением сервера."))
                            .font(.footnote).foregroundStyle(.secondary)
                        if let error = model.error { Text(tr(error)).foregroundStyle(MSTheme.danger) }
                        Button(tr("Создать встречу")) {
                            Task { if await model.create(title: title, waitingRoom: waitingRoom) { creating = false; title = "" } }
                        }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
                            .accessibilityIdentifier("conferenceCreateSubmit")
                    }.navigationTitle(tr("Новая встреча")).msInlineTitle()
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tr("Отмена")) { creating = false } } }
                        .disabled(model.busy).interactiveDismissDisabled(model.busy)
                }
            }
            .sheet(isPresented: $joining) {
                NavigationStack {
                    Form {
                        TextField(tr("Ссылка или код приглашения"), text: $invitation).msURLInput()
                            .accessibilityIdentifier("conferenceInvitation")
                        if let error = model.error { Text(tr(error)).foregroundStyle(MSTheme.danger) }
                        Button(tr("Продолжить")) {
                            Task { if await model.joinInvitation(invitation) { joining = false; invitation = "" } }
                        }.disabled(invitation.isEmpty || model.busy).accessibilityIdentifier("invitationJoinSubmit")
                    }.navigationTitle(tr("Встреча по приглашению")).msInlineTitle()
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tr("Отмена")) { joining = false } } }
                        .disabled(model.busy).interactiveDismissDisabled(model.busy)
                }
            }

    }
    private func listItem(_ meeting: Conference) -> MeetingListItem<Conference> {
        let status: ConferenceTimelineView = meeting.isClosed ? .past : meeting.status == "active" ? .active : .upcoming
        let date = meeting.scheduledAt ?? meeting.startedAt ?? meeting.finishedAt
        return MeetingListItem(value: meeting, title: meeting.title, date: date, duration: meeting.plannedDurationMin,
                               status: status, cancelled: meeting.status == "cancelled", mine: meeting.ownerId == model.repository.userID)
    }
}

func conferenceStatus(_ status: String) -> String {
    switch status {
    case "active": "Идёт встреча"
    case "created": "Готова к началу"
    case "scheduled": "Запланирована"
    case "finished": "Завершена"
    case "cancelled": "Отменена"
    default: "Встреча"
    }
}

struct GuestConferenceForm: View {
    @Bindable var app: AppModel
    let completed: () -> Void
    @State private var server = ""
    @State private var invitation = ""
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                TextField(tr("HTTPS-адрес сервера"), text: $server).msURLInput()
                TextField(tr("Ссылка или код приглашения"), text: $invitation).msURLInput()
                TextField(tr("Ваше имя"), text: $name)
                Text(tr("Гостевой доступ действует только для этой встречи."))
                    .font(.footnote).foregroundStyle(.secondary)
                if let error = app.guestError { Text(tr(error)).foregroundStyle(MSTheme.danger) }
                Button(tr("Продолжить")) {
                    Task {
                        if await app.joinGuest(server: server, invitation: invitation, name: name) {
                            dismiss(); completed()
                        }
                    }
                }.disabled(app.guestBusy || server.isEmpty || invitation.isEmpty || name.isEmpty)
                if app.guestBusy { ProgressView() }
            }.navigationTitle(tr("Войти как гость")).msInlineTitle()
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tr("Отмена")) { dismiss() }.disabled(app.guestBusy) } }
                .interactiveDismissDisabled(app.guestBusy)
                .onAppear { server = app.configuration.server?.url.absoluteString ?? "" }
        }
    }
}
