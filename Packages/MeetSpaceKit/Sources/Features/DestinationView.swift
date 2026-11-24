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
                if let messaging = model.identity.messaging { LiveThreadView(model: messaging, app: model, id: id, calls: model.identity.calls, openRecipient: { model.navigate(.conversation($0)) }).id(id) }
            case .interfaceCatalog: ScreenCatalog(model: model)
            case .calendar:
                if model.isDemo { CalendarScreen(model: model) }
                else if let calendar = model.identity.calendar {
                    LiveCalendarView(model: calendar) { meeting in Task { await model.identity.conferences?.join(meeting) } }
                }
            case .demoFolder:
                if model.isDemo { LibraryView(model: model, route: route) }
            case .folders:
                if model.isDemo { LibraryView(model: model, route: route) }
                else if let folders = model.identity.folders {
                    LiveFoldersView(model: folders, openConversation: { model.navigate(.conversation($0)) },
                        openConference: { meeting in Task { await model.identity.conferences?.join(meeting) } })
                }
            case .recordings, .recording:
                if model.isDemo { LibraryView(model: model, route: route) }
                else if let recordings = model.identity.recordings {
                    LiveRecordingsView(model: recordings) { model.navigate(.liveRecording($0)) }
                }
            case .liveRecording(let id):
                if let recordings = model.identity.recordings {
                    LiveRecordingDetail(model: recordings, id: id)
                }
            case .meetingDetails(let id): MeetingDetailView(model: model, meetingID: id)
            case .newMeeting, .scheduleMeeting, .joinMeeting: MeetingFormView(model: model, route: route)
            case .prejoin, .call, .personalCall, .contactCall: CallPreviewView(model: model, route: route)
            case .notificationSettings:
                if model.isDemo { SettingsDetailView(model: model, route: route) }
                else if let settings = model.identity.settings {
                    LiveAccountNotificationSettings(settings: settings, push: model.identity.notifications)
                        .task { if !settings.loaded { await settings.load() } }
                }
            case .connection: AccountConnectionPage(app: model, wide: false)
            case .accounts:
                ScrollView { AccountSwitcherView(app: model, wide: false) }.background(MSTheme.background)
            case .audioSettings, .videoSettings, .appearance:
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
        case .recording, .liveRecording: "Просмотр записи"
        case .folders, .demoFolder: "Папки"
        case .prejoin: "Перед встречей"
        case .call: "Встреча"
        case .personalCall, .contactCall: "Личный звонок"
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
                    Button {
                        if route == .prejoin { model.showDemoPrejoin() }
                        else { model.navigate(route) }
                    } label: {
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
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        if let meeting = model.demoMeetings.meetings.first(where: { $0.id == meetingID }) {
            DemoMeetingDetails(model: model, meeting: meeting, showingMaterials: false,
                close: { dismiss() }, openCall: { model.showDemoPrejoin(title: tr(meeting.title)) },
                openRecording: { model.navigate(.recording($0)) })
                .msHideRootBar()
        }
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
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize

    private var zone: TimeZone { DemoData.meetingZone }
    private var calendar: Calendar { MeetingCalendar.calendar(in: zone) }
    private var weekMeetings: [DemoData.Meeting] {
        let interval = MeetingCalendar.interval(containing: date, mode: .week, in: zone)
        return model.demoMeetings.meetings.filter { $0.start.map { MeetingCalendar.includes($0, interval: interval) } ?? false }
            .sorted { ($0.start ?? date) < ($1.start ?? date) }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                if sizeClass == .regular && geometry.size.width >= 600 && !typeSize.isAccessibilitySize {
                    tabletCalendar(width: geometry.size.width)
                } else {
                    VStack(alignment: .leading, spacing: 24) {
                        DatePicker(tr("Выберите день"), selection: $date, displayedComponents: .date).datePickerStyle(.graphical).msCard()
                        FeatureNotice("Календарь показывает локальный выбор даты. Серверные встречи ещё не подключены.")
                        Button(tr("Запланировать встречу")) { model.navigate(.scheduleMeeting) }.buttonStyle(MSButtonStyle())
                    }.padding(24).frame(maxWidth: 720).frame(maxWidth: .infinity)
                }
            }
        }.background(MSTheme.background)
    }

    private func tabletCalendar(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                VStack(alignment: .leading, spacing: 7) {
                    Text(tr("Календарь")).font(MSTheme.font(28, weight: .semibold, relativeTo: .title)).accessibilityAddTraits(.isHeader)
                    Text(tr("Время для важных разговоров.")).font(MSTheme.font(13)).foregroundStyle(MSTheme.muted)
                }
                Spacer()
                IconButton("plus", label: "Запланировать встречу") { model.navigate(.scheduleMeeting) }
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text(calendarText(date, format: "LLLL yyyy", zone: zone).capitalized)
                            .font(MSTheme.font(20, weight: .semibold))
                        Spacer()
                        Button(tr("Сегодня")) { date = Date() }.buttonStyle(MSTextButtonStyle())
                        IconButton("chevron.left", label: "Предыдущая неделя") { moveWeek(-1) }
                        IconButton("chevron.right", label: "Следующая неделя") { moveWeek(1) }
                    }
                    CalendarWeekStrip(selectedDay: date, zone: zone, eventDays: weekMeetings.compactMap(\.start)) { date = $0 }
                    Text(calendarText(date, format: "d MMMM", zone: zone))
                        .font(MSTheme.font(15, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    let events = weekMeetings.filter { $0.start.map { calendar.isDate($0, inSameDayAs: date) } ?? false }
                    CalendarDayTimeline(events: events, zone: zone, time: { $0.start ?? date }) { meeting in
                        Button { model.navigate(.meetingDetails(meeting.id)) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(tr(meeting.title)).font(MSTheme.font(14, weight: .semibold))
                                if let start = meeting.start {
                                    Text(calendarText(start, format: "HH:mm", zone: zone)).font(MSTheme.font(11))
                                        .foregroundStyle(MSTheme.muted)
                                }
                            }.padding(12).frame(maxWidth: .infinity, minHeight: 65, alignment: .leading)
                                .background(MSTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain)
                    }
                }
                if width >= 840 {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(tr("На этой неделе")).font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
                        Text(tr("Хороший ритм")).font(MSTheme.font(21, weight: .semibold))
                        ForEach(weekMeetings.prefix(5)) { meeting in
                            Button { model.navigate(.meetingDetails(meeting.id)) } label: {
                                Text(tr(meeting.title)).frame(minHeight: 44).multilineTextAlignment(.leading)
                            }.buttonStyle(.plain)
                        }
                        Label(MeetingDateText.zoneLabel(zone), systemImage: "clock")
                            .font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
                    }.frame(maxWidth: .infinity, alignment: .leading).msCard(padding: 22).frame(width: 280)
                }
            }
        }.padding(.horizontal, width >= 780 ? 48 : 24).padding(.vertical, 24)
    }

    private func moveWeek(_ offset: Int) {
        if let day = calendar.date(byAdding: .weekOfYear, value: offset, to: date) { date = day }
    }
}
