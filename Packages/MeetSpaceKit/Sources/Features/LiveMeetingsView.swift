import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

struct LiveMeetingsView: View {
    @Bindable var model: ConferenceWorkspace
    var openCalendar: () -> Void = {}
    var openRecordings: () -> Void = {}
    var openFolders: () -> Void = {}
    @State private var creating = false
    @State private var joining = false
    @State private var title = ""
    @State private var invitation = ""
    @State private var waitingRoom = false
    @State private var query = ""
    @State private var finishing: Conference?
    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Встречи") {
                IconButton("arrow.clockwise", label: "Обновить") { Task { await model.load() } }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        Button { creating = true } label: { Label(tr("Новая встреча"), systemImage: "video.badge.plus") }
                            .buttonStyle(MSButtonStyle()).accessibilityIdentifier("createConference")
                        Button { joining = true } label: { Label(tr("По ссылке"), systemImage: "link") }
                            .buttonStyle(MSButtonStyle(primary: false)).accessibilityIdentifier("joinInvitation")
                    }
                    SearchBox(text: $query, placeholder: "Поиск встреч")
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 20) { workspaceActions }
                        VStack(alignment: .leading, spacing: 8) { workspaceActions }
                    }
                    if let error = model.error { Text(tr(error)).foregroundStyle(MSTheme.danger) }
                    StateContent(state: model.state, retry: { Task { await model.load() } }) {
                        ForEach(model.meetings.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }) { meeting in
                            HStack(spacing: 14) {
                                Image(systemName: "video").font(.system(size: 25)).foregroundStyle(MSTheme.accent)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(meeting.title).font(MSTheme.font(16, weight: .semibold))
                                    Text(tr(conferenceStatus(meeting.status))).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
                                }
                                Spacer()
                                if !meeting.isClosed {
                                    Button(tr("Войти")) { Task { await model.join(meeting) } }
                                        .accessibilityIdentifier("conference.\(meeting.id.uuidString.lowercased())")
                                    if meeting.ownerId == model.repository.userID {
                                        Menu {
                                            Button(tr("Завершить встречу"), role: .destructive) { finishing = meeting }
                                        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                                            .accessibilityLabel(tr("Управление встречей"))
                                    }
                                }
                            }.msCard()
                        }
                    }
                }.padding(20).frame(maxWidth: 1120).frame(maxWidth: .infinity)
            }.refreshable { await model.load() }
        }.background(MSTheme.background).toolbar(.hidden).disabled(model.busy)
            .accessibilityIdentifier("screen.liveMeetings")
            .task { await model.load() }
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
            .confirmationDialog(tr("Завершить встречу для всех участников?"), isPresented: Binding(get: { finishing != nil }, set: { if !$0 { finishing = nil } })) {
                Button(tr("Завершить встречу"), role: .destructive) {
                    if let conference = finishing { Task { await model.finish(conference) } }
                    finishing = nil
                }
            }
    }
    private var workspaceActions: some View {
        Group {
            Button(action: openCalendar) { Label(tr("Календарь"), systemImage: "calendar") }.accessibilityIdentifier("meetingsCalendar")
            Button(action: openRecordings) { Label(tr("Записи"), systemImage: "play.rectangle") }.accessibilityIdentifier("meetingsRecordings")
            Button(action: openFolders) { Label(tr("Папки"), systemImage: "folder") }.accessibilityIdentifier("meetingsFolders")
        }.frame(minHeight: 44)
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
