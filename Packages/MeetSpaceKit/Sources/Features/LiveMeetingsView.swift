import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

struct LiveMeetingsView: View {
    @Bindable var model: ConferenceWorkspace
    var calendar: CalendarModel?
    var recordings: RecordingsModel?
    var folders: FoldersModel?
    var openRecording: (UUID) -> Void = { _ in }
    var openCalendar: () -> Void = {}
    var openRecordings: () -> Void = {}
    var openFolders: () -> Void = {}
    var openNotifications: () -> Void = {}
    @State private var scheduling = false
    @State private var selected: Conference?
    @State private var creating = false
    @State private var joining = false
    @State private var invitation = ""
    @State private var initialMaterials = false
    @State private var afterDetails: (() -> Void)?
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
                if meeting.isClosed { initialMaterials = true; selected = meeting }
                else { Task { await model.join(meeting) } }
            }, details: { initialMaterials = false; selected = $0 }, identifier: { "conference.\($0.id.uuidString.lowercased())" })
            .disabled(model.busy)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("screen.liveMeetings")
            .refreshable { await model.load() }
            .task {
                await calendar?.restorePreferences()
                await model.load()
            }
            .workspaceFormPresentation(isPresented: $scheduling) {
                ScheduleMeetingForm(model: calendar, workspace: model, didSave: { Task { await model.load() } })
            }
            .workspaceFormPresentation(item: $selected, onDismiss: {
                let action = afterDetails
                afterDetails = nil
                action?()
            }) { meeting in
                LiveMeetingDetails(item: listItem(meeting), zone: calendar?.zone ?? .current, workspace: model,
                    recordings: recordings, folders: folders, openRecording: { id in endDetails { openRecording(id) } },
                    openCall: { endDetails { Task { await model.join(meeting) } } },
                    close: { selected = nil },
                    showingMaterials: initialMaterials)
            }
            .workspaceFormPresentation(isPresented: $creating) {
                ScheduleMeetingForm(model: calendar, workspace: model, initiallyPlanned: false,
                                    didSave: { Task { await model.load() } })
            }
            .workspaceFormPresentation(isPresented: $joining) {
                WorkspaceFormSheet(title: "Подключиться по ссылке", identifier: "invitation", closeAction: .cancel,
                                   busy: model.busy, close: { joining = false }) {
                    Text(tr("Вставьте ссылку, которую прислал организатор встречи.")).foregroundStyle(MSTheme.muted)
                    WorkspaceFormField(title: "Ссылка на встречу") {
                        TextField(tr("https://meet.example.org/…"), text: $invitation).msURLInput()
                            .textFieldStyle(.plain).workspaceFormInput()
                            .accessibilityLabel(tr("Ссылка или код приглашения")).accessibilityIdentifier("conferenceInvitation")
                    }
                    if let error = model.error { Text(tr(error)).foregroundStyle(MSTheme.danger) }
                    Button {
                        Task { if await model.joinInvitation(invitation) { joining = false; invitation = "" } }
                    } label: {
                        HStack {
                            Text(tr("Продолжить")).fixedSize(horizontal: false, vertical: true)
                            Image(systemName: "arrow.right").accessibilityHidden(true)
                        }
                    }.buttonStyle(MSButtonStyle()).disabled(invitation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
                        .accessibilityIdentifier("invitationJoinSubmit")
                }
            }

    }
    /// Закрывает сведения о встрече и откладывает переход до закрытия окна.
    /// - Parameter action: Действие, которое нужно выполнить после закрытия.
    private func endDetails(then action: @escaping () -> Void) {
        afterDetails = action
        selected = nil
    }

    /// Преобразует серверную встречу в данные карточки списка.
    /// - Parameter meeting: Встреча с датой, статусом и данными организатора.
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
        WorkspaceFormSheet(title: "Войти как гость", identifier: "guest", closeAction: .cancel,
                           busy: app.guestBusy, close: { dismiss() }) {
            WorkspaceFormField(title: "HTTPS-адрес сервера") {
                TextField(tr("HTTPS-адрес сервера"), text: $server).msURLInput().textFieldStyle(.plain).workspaceFormInput()
            }
            WorkspaceFormField(title: "Ссылка или код приглашения") {
                TextField(tr("Ссылка или код приглашения"), text: $invitation).msURLInput().textFieldStyle(.plain).workspaceFormInput()
            }
            WorkspaceFormField(title: "Ваше имя") {
                TextField(tr("Ваше имя"), text: $name).textFieldStyle(.plain).workspaceFormInput()
            }
            Text(tr("Гостевой доступ действует только для этой встречи.")).font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
            if let error = app.guestError { Text(tr(error)).foregroundStyle(MSTheme.danger) }
            Button(tr("Продолжить")) {
                Task {
                    if await app.joinGuest(server: server, invitation: invitation, name: name) {
                        dismiss(); completed()
                    }
                }
            }.buttonStyle(MSButtonStyle()).disabled(app.guestBusy || server.isEmpty || invitation.isEmpty || name.isEmpty)
            if app.guestBusy { ProgressView().frame(maxWidth: .infinity) }
        }.onAppear { server = app.configuration.server?.url.absoluteString ?? "" }
    }
}
