import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

struct DestinationView: View {
    @Bindable var model: AppModel
    let route: AppRoute
    var body: some View {
        Group {
            switch route {
            case .thread(let index): ThreadView(model: model, personIndex: index)
            case .conversation(let id):
                if let messaging = model.identity.messaging { LiveThreadView(model: messaging, id: id, calls: model.identity.calls, openRecipient: { model.navigate(.conversation($0)) }).id(id) }
            case .interfaceCatalog: ScreenCatalog(model: model)
            case .calendar:
                if model.isDemo { CalendarScreen(model: model) }
                else if let calendar = model.identity.calendar {
                    LiveCalendarView(model: calendar) { meeting in Task { await model.identity.conferences?.join(meeting) } }
                }
            case .folders:
                if model.isDemo { LibraryView(model: model, route: route) }
                else if let folders = model.identity.folders {
                    LiveFoldersView(model: folders, openConversation: { model.navigate(.conversation($0)) },
                        openConference: { meeting in Task { await model.identity.conferences?.join(meeting) } })
                }
            case .recordings, .recording:
                if model.isDemo { LibraryView(model: model, route: route) }
                else if let recordings = model.identity.recordings { LiveRecordingsView(model: recordings) }
            case .meetingDetails(let id): MeetingDetailView(model: model, meetingID: id)
            case .newMeeting, .scheduleMeeting, .joinMeeting: MeetingFormView(model: model, route: route)
            case .prejoin, .call, .personalCall: CallPreviewView(model: model, route: route)
            case .notificationSettings:
                if model.isDemo { SettingsDetailView(model: model, route: route) }
                else if let settings = model.identity.settings {
                    AccountSettingsContent(model: settings, section: .notifications).task { await settings.load() }
                }
            case .audioSettings, .videoSettings, .appearance, .connection, .accounts:
                SettingsDetailView(model: model, route: route)
            case .deploy, .fingerprint, .preflight, .install, .complete, .installError:
                InstallerCatalogNotice(model: model)
            }
        }.navigationTitle(tr(route.title)).msInlineTitle()
    }
}

/// Catalog destinations stay inert; only the explicit welcome action opens live SSH setup.
private struct InstallerCatalogNotice: View {
    @Bindable var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Label("Установщик сервера", systemImage: "server.rack")
                    .font(MSTheme.font(28, weight: .semibold, relativeTo: .title))
                FeatureNotice("В демо-каталоге подключение к VPS и установка не выполняются. Чтобы настроить свой сервер, вернитесь на приветственный экран и выберите «Развернуть свой сервер».")
                    .accessibilityIdentifier("installer.demoNotice")
                Button("На приветственный экран") { model.leaveDemo() }
                    .buttonStyle(MSButtonStyle(primary: false))
                    .accessibilityIdentifier("installer.returnToWelcome")
            }.padding(24).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }.background(MSTheme.background)
    }
}

extension AppRoute {
    var title: String {
        switch self {
        case .calendar: "Календарь"
        case .recordings: "Записи встреч"
        case .recording: "Запись встречи"
        case .folders: "Папки"
        case .prejoin: "Перед встречей"
        case .call: "Встреча"
        case .personalCall: "Личный звонок"
        case .meetingDetails: "О встрече"
        case .newMeeting: "Новая встреча"
        case .scheduleMeeting: "Запланировать встречу"
        case .joinMeeting: "Войти по ссылке"
        case .thread, .conversation: "Чат"
        case .audioSettings: "Аудио"
        case .videoSettings: "Видео"
        case .notificationSettings: "Уведомления"
        case .appearance: "Оформление"
        case .connection: "Подключение"
        case .accounts: "Аккаунты"
        case .interfaceCatalog: "Каталог экранов"
        case .deploy: "Свой сервер"
        case .fingerprint: "Отпечаток сервера"
        case .preflight: "Проверка сервера"
        case .install: "Установка"
        case .complete: "Завершение"
        case .installError: "Ошибка установки"
        }
    }
}

private struct ScreenCatalog: View {
    @Bindable var model: AppModel
    private let routes: [AppRoute] = [.calendar, .recordings, .recording(0), .folders, .prejoin, .call, .personalCall,
                                      .deploy, .fingerprint, .preflight, .install, .complete, .installError]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                FeatureNotice("Каталог демо-экранов. Незавершённые сценарии отмечены внутри; операции с сервером не выполняются.")
                ForEach(routes, id: \.self) { route in
                    Button { model.navigate(route) } label: {
                        HStack { Text(tr(route.title)); Spacer(); Image(systemName: "chevron.right") }.frame(minHeight: 44).msCard(padding: 10)
                    }.buttonStyle(.plain)
                }
                Button(tr("Вход")) { model.leaveDemo(); model.show(.login) }.buttonStyle(MSButtonStyle(primary: false))
                Button(tr("Регистрация")) { model.leaveDemo(); model.show(.register) }.buttonStyle(MSButtonStyle(primary: false))
            }.padding(24).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }.background(MSTheme.background)
    }
}

private struct MeetingDetailView: View {
    @Bindable var model: AppModel
    let meetingID: Int
    var meeting: DemoData.Meeting { DemoData.meetings.first { $0.id == meetingID } ?? DemoData.meetings[0] }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(tr(meeting.title)).font(MSTheme.font(28, weight: .semibold, relativeTo: .title))
                Label("\(meeting.day) \(tr(meeting.month)) · \(meeting.time)", systemImage: "calendar")
                Label("\(meeting.count)", systemImage: "person.2")
                HStack { Text(tr(meeting.owner)); Spacer(); Text(tr("Организатор")).foregroundStyle(MSTheme.muted) }.msCard()
                FeatureNotice()
                Button(tr("Перед встречей")) { model.navigate(.prejoin) }.buttonStyle(MSButtonStyle())
                Button(tr("Записи встречи")) { model.navigate(.recordings) }.buttonStyle(MSButtonStyle(primary: false))
            }.padding(24).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }.background(MSTheme.background)
    }
}

private struct MeetingFormView: View {
    @Bindable var model: AppModel
    let route: AppRoute
    @State private var title: String = ""
    @State private var date: Date = Date()
    @State private var link: String = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                FeatureNotice()
                if route == .joinMeeting {
                    Text(tr("Ссылка на встречу")).font(MSTheme.font(12, weight: .semibold))
                    TextField("https://…", text: $link).msURLInput().textFieldStyle(.plain).msCard()
                } else {
                    Text(tr("Название встречи")).font(MSTheme.font(12, weight: .semibold))
                    TextField(tr("Название встречи"), text: $title).textFieldStyle(.plain).msCard()
                    if route == .scheduleMeeting { DatePicker(tr("Дата и время"), selection: $date).msCard() }
                }
                Button(tr("Продолжить")) {}.buttonStyle(MSButtonStyle()).disabled(true)
            }.padding(24).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }.background(MSTheme.background)
    }
}

private struct CalendarScreen: View {
    @Bindable var model: AppModel
    @State private var date: Date = Date(timeIntervalSince1970: 1_792_022_400)
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                DatePicker(tr("Выберите день"), selection: $date, displayedComponents: .date).datePickerStyle(.graphical).msCard()
                FeatureNotice("Календарь показывает локальный выбор даты. Серверные встречи ещё не подключены.")
                Button(tr("Запланировать встречу")) { model.navigate(.scheduleMeeting) }.buttonStyle(MSButtonStyle())
            }.padding(24).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }.background(MSTheme.background)
    }
}
