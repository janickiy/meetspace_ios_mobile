import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

struct LiveCalendarView: View {
    @Bindable var model: CalendarModel
    var onJoin: (Conference) -> Void = { _ in }
    @State private var creating = false
    @State private var selected: Conference?
    @State private var choosingZone = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var dayMinimumWidth: CGFloat = 44
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        ViewThatFits(in: .horizontal) {
                            HStack { heading.fixedSize(); Spacer(); headerActions }
                            VStack(alignment: .leading, spacing: 8) { heading; headerActions }
                        }
                        Text(tr("Время для важных разговоров.")).font(MSTheme.font(13)).foregroundStyle(MSTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Picker(tr("Вид календаря"), selection: Binding(get: { model.preferences.displayMode }, set: { mode in Task { await model.selectMode(mode) } })) {
                        Text(tr("Неделя")).tag(CalendarDisplayMode.week)
                        Text(tr("Месяц")).tag(CalendarDisplayMode.month)
                        Text(tr("Список")).tag(CalendarDisplayMode.list)
                    }.pickerStyle(.segmented).accessibilityIdentifier("calendar.mode")
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            scopeMenu.fixedSize(horizontal: true, vertical: false)
                            Spacer()
                            timeZoneButton.fixedSize(horizontal: true, vertical: false)
                        }
                        VStack(alignment: .leading, spacing: 12) { scopeMenu; timeZoneButton }
                    }
                    if let error = model.error { Text(tr(error)).foregroundStyle(MSTheme.danger) }
                    if model.creationUncertain {
                        Button(tr("Список проверен — разрешить новое создание")) { model.acknowledgeCreationCheck() }
                            .disabled(model.loading).accessibilityIdentifier("calendar.acknowledgeCreation")
                    }
                    if geometry.size.width >= 840 && !typeSize.isAccessibilitySize {
                        HStack(alignment: .top, spacing: 24) {
                            VStack(alignment: .leading, spacing: 18) { periodControls; calendarBody }
                                .frame(maxWidth: .infinity)
                            sidePanel.frame(width: 280)
                        }
                    } else { periodControls; calendarBody }
                    if model.loading { ProgressView().frame(maxWidth: .infinity).accessibilityLabel(tr("Загрузка календаря")) }
                    if !model.feedErrors.isEmpty {
                        Text(tr("Не все данные загружены")).font(MSTheme.font(14, weight: .semibold))
                        ForEach(model.feedErrors, id: \.self) { Text(tr($0)).foregroundStyle(MSTheme.danger) }
                        Button(tr("Повторить")) { Task { await model.load() } }
                    }
                    if model.hasMore {
                        Button(tr("Загрузить ещё встречи")) { Task { await model.load(more: true) } }
                            .buttonStyle(MSButtonStyle(primary: false)).disabled(model.loading).accessibilityIdentifier("calendar.more")
                        Text(tr("В следующих страницах могут быть другие встречи выбранного периода."))
                            .font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
                    }
                }.padding(.horizontal, geometry.size.width >= 780 ? 48 : 20)
                    .padding(.vertical, geometry.size.width >= 700 ? 24 : 20)
                    .frame(maxWidth: .infinity)
            }.refreshable { await model.load() }
        }.background(MSTheme.background).foregroundStyle(MSTheme.ink)
            .accessibilityIdentifier("screen.liveCalendar")
            .task { await model.initialize() }
            .workspaceFormPresentation(isPresented: $creating) { ScheduleMeetingForm(model: model) }
            .sheet(item: $selected) { meeting in CalendarMeetingDetail(model: model, meeting: meeting, onJoin: onJoin) }
            .sheet(isPresented: $choosingZone) {
                CalendarTimeZonePicker(selected: model.preferences.timeZoneIdentifier) { identifier in Task { await model.selectTimeZone(identifier) } }
            }
    }
    private var heading: some View {
        Text(tr("Календарь")).font(MSTheme.font(28, weight: .semibold, relativeTo: .title))
            .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("calendar.heading")
    }
    private var headerActions: some View {
        HStack {
            IconButton("arrow.clockwise", label: "Обновить") { Task { await model.load() } }
            IconButton("plus", label: "Запланировать встречу") { creating = true }.accessibilityIdentifier("calendar.schedule")
        }
    }
    private var scopeTitle: String {
        switch model.scope {
        case .all: "Все встречи"
        case .owned: "Я организатор"
        case .participating: "Я участник"
        }
    }
    private var scopeMenu: some View {
        Menu {
            Picker(tr("Встречи"), selection: Binding(get: { model.scope }, set: { value in Task { await model.selectScope(value) } })) {
                Text(tr("Все встречи")).tag(ConferenceTimelineScope.all)
                Text(tr("Я организатор")).tag(ConferenceTimelineScope.owned)
                Text(tr("Я участник")).tag(ConferenceTimelineScope.participating)
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(tr(scopeTitle)).font(MSTheme.font(17)).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                    .accessibilityIdentifier("calendar.scopeTitle")
                Image(systemName: "chevron.up.chevron.down").font(MSTheme.font(10)).accessibilityHidden(true)
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(MSTheme.accent)
            .accessibilityLabel(tr("Встречи")).accessibilityValue(tr(scopeTitle)).accessibilityIdentifier("calendar.scope")
    }
    private var timeZoneButton: some View {
        Button { choosingZone = true } label: {
            Label {
                Text(model.zone.identifier).accessibilityIdentifier("calendar.timeZoneTitle")
            } icon: {
                Image(systemName: "clock").accessibilityHidden(true)
            }
                .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading).frame(minHeight: 44)
        }.font(MSTheme.font(12)).accessibilityIdentifier("calendar.timeZone")
    }
    private var periodControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack { periodTitle; Spacer(); navigationButtons }
            VStack(alignment: .leading) { periodTitle; navigationButtons }
        }
    }
    private var periodTitle: some View {
        Text(calendarText(model.selectedDay, format: "LLLL yyyy", zone: model.zone).capitalized)
            .font(MSTheme.font(20, weight: .semibold, relativeTo: .title2)).accessibilityAddTraits(.isHeader)
            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("calendar.periodTitle")
    }
    private var navigationButtons: some View {
        HStack(spacing: 0) {
            Button(tr("Сегодня")) { Task { await model.selectDay(Date()) } }.buttonStyle(MSTextButtonStyle())
                .accessibilityIdentifier("calendar.today")
            IconButton("chevron.left", label: "Предыдущий период") { Task { await model.movePeriod(-1) } }.accessibilityIdentifier("calendar.previous")
            IconButton("chevron.right", label: "Следующий период") { Task { await model.movePeriod(1) } }.accessibilityIdentifier("calendar.next")
        }
    }
    @ViewBuilder private var calendarBody: some View {
        VStack(alignment: .leading, spacing: 20) {
            if model.preferences.displayMode != .list {
                if model.preferences.displayMode == .week { weekStrip }
                else { monthGrid }
                Text(calendarText(model.selectedDay, format: "d MMMM", zone: model.zone))
                    .font(MSTheme.font(15, weight: .semibold)).accessibilityAddTraits(.isHeader)
                agenda
            } else {
                if model.meetings.isEmpty && !model.loading && model.feedErrors.isEmpty { emptyDay }
                ForEach(model.meetings) { event in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(calendarText(MeetingCalendar.timelineDate(event), format: "EEEE, d MMMM", zone: model.zone))
                            .font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
                        eventCard(event)
                    }
                }
            }
        }
    }
    private var weekStrip: some View {
        CalendarWeekStrip(selectedDay: model.selectedDay, zone: model.zone,
                          eventDays: model.meetings.map(MeetingCalendar.timelineDate)) { day in
            Task { await model.selectDay(day) }
        }
    }
    private var monthGrid: some View {
        ViewThatFits(in: .horizontal) {
            monthGridContent
            ScrollView(.horizontal) { monthGridContent }
        }
    }
    private var monthGridContent: some View {
        let days = MeetingCalendar.days(in: model.interval, zone: model.zone)
        let leading = (model.calendar.component(.weekday, from: model.interval.start) + 5) % 7
        let weekdays = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: dayMinimumWidth), spacing: 3), count: 7), spacing: 5) {
            ForEach(0..<weekdays.count, id: \.self) { index in
                Text(tr(weekdays[index])).font(MSTheme.font(10)).foregroundStyle(MSTheme.muted)
                    .accessibilityIdentifier("calendar.weekday.\(index)")
            }
            ForEach(0..<leading, id: \.self) { _ in Color.clear.frame(height: 44) }
            ForEach(days, id: \.self) { day in dayButton(day) }
        }.frame(minWidth: dayMinimumWidth * 7 + 18).padding(10)
            .background(MSTheme.surface, in: RoundedRectangle(cornerRadius: 20))
    }
    /// Создаёт кнопку дня с отметками текущего выбора и запланированных встреч.
    /// - Parameter day: Дата ячейки календаря.
    private func dayButton(_ day: Date) -> some View {
        let selected = model.calendar.isDate(day, inSameDayAs: model.selectedDay)
        let hasEvent = model.meetings.contains { model.calendar.isDate(MeetingCalendar.timelineDate($0), inSameDayAs: day) }
        return Button { Task { await model.selectDay(day) } } label: {
            VStack(spacing: 4) {
                Text(calendarText(day, format: "d", zone: model.zone)).font(MSTheme.font(17, weight: .semibold))
                Circle().fill(hasEvent ? (selected ? MSTheme.surface : MSTheme.accent) : .clear).frame(width: 4, height: 4)
            }.frame(minWidth: dayMinimumWidth, maxWidth: .infinity, minHeight: 44)
                .background(selected ? MSTheme.accent : MSTheme.surface, in: RoundedRectangle(cornerRadius: 13))
                .foregroundStyle(selected ? MSTheme.surface : MSTheme.ink)
        }.buttonStyle(.plain).accessibilityLabel(calendarText(day, format: "d MMMM yyyy", zone: model.zone))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var agenda: some View {
        let events = model.dayMeetings
        return VStack(alignment: .leading, spacing: 0) {
            if events.isEmpty && !model.loading && model.feedErrors.isEmpty { emptyDay.padding(.bottom, 12) }
            CalendarDayTimeline(events: events, zone: model.zone, time: MeetingCalendar.timelineDate, eventCard: eventCard)
        }
    }
    private var emptyDay: some View {
        Text(tr(model.hasMore ? "На загруженных страницах встреч нет." : "Нет встреч в выбранном периоде."))
            .font(MSTheme.font(13)).foregroundStyle(MSTheme.muted)
    }
    /// Показывает карточку встречи и открывает сведения о ней по нажатию.
    /// - Parameter meeting: Встреча для отображения.
    private func eventCard(_ meeting: Conference) -> some View {
        Button { selected = meeting } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(MSTheme.accent).frame(width: 3)
                VStack(alignment: .leading, spacing: 6) {
                    Text(meeting.title).font(MSTheme.font(14, weight: .semibold)).multilineTextAlignment(.leading)
                    Text(calendarMeetingTime(meeting, zone: model.zone) + " · " + tr(conferenceStatus(meeting.status)))
                        .font(MSTheme.font(11)).foregroundStyle(MSTheme.muted).multilineTextAlignment(.leading)
                }.padding(.vertical, 12)
                Spacer(minLength: 0)
            }.padding(.trailing, 12).frame(maxWidth: .infinity, minHeight: 65)
                .background(MSTheme.accentSoft, in: RoundedRectangle(cornerRadius: 13))
                .contentShape(Rectangle()).accessibilityElement(children: .combine)
        }.buttonStyle(.plain).accessibilityIdentifier("calendar.event.\(meeting.id.uuidString.lowercased())")
    }
    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("На этой неделе")).font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
                .accessibilityIdentifier("calendar.weekSummaryHeading")
            Text(tr("Хороший ритм")).font(MSTheme.font(21, weight: .semibold))
            Text(tr("Все встречи команды в вашем часовом поясе.")).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
            let week = MeetingCalendar.interval(containing: model.selectedDay, mode: .week, in: model.zone)
            ForEach(model.meetings.filter { MeetingCalendar.includes(MeetingCalendar.timelineDate($0), interval: week) }.prefix(5)) { meeting in
                Button { selected = meeting } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meeting.title).font(MSTheme.font(12, weight: .semibold))
                        Text(calendarText(MeetingCalendar.timelineDate(meeting), format: "EE, HH:mm", zone: model.zone)).font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
                    }.frame(minHeight: 44).contentShape(Rectangle()).accessibilityElement(children: .combine)
                }.buttonStyle(.plain)
            }
        }.msCard(padding: 22)
    }
}

struct ScheduleMeetingForm: View {
    var model: CalendarModel?
    var workspace: ConferenceWorkspace?
    var initiallyPlanned = true
    var meeting: Conference?
    var didSave: () -> Void = {}
    @State private var title = ""
    @State private var startsAt = Date().addingTimeInterval(3600)
    @State private var duration = 30
    @State private var hasDuration = true
    @State private var customDuration = false
    @State private var waitingRoom = false
    @State private var planned = true
    @State private var choosingZone = false
    @State private var initialized = false
    @FocusState private var titleFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var zone: TimeZone { model?.zone ?? .current }
    private var busy: Bool { model?.busy == true || workspace?.busy == true }
    private var error: String? { planned ? model?.error : workspace?.error }
    private var name: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSubmit: Bool {
        if busy || (planned && model == nil) { return false }
        if meeting != nil { return true }
        let validName = (1...200).contains(name.unicodeScalars.count)
        return validName && (!planned || model?.creationUncertain != true)
    }

    var body: some View {
        WorkspaceFormSheet(
            title: meeting != nil ? "Перенести встречу" : (initiallyPlanned ? "Запланировать встречу" : "Новая встреча"),
            identifier: "schedule", closeLabel: "Отмена", busy: busy, close: { dismiss() }
        ) {
            if let meeting { Text(meeting.title).font(MSTheme.font(15, weight: .semibold)) }
            else {
                WorkspaceFormField(title: "Название встречи") {
                    TextField(tr("Например, обсуждение проекта"), text: $title)
                        .textFieldStyle(.plain).workspaceFormInput().focused($titleFocused)
                        .submitLabel(.done).onSubmit { titleFocused = false }
                        .accessibilityLabel(tr("Название встречи")).accessibilityIdentifier(initiallyPlanned ? "schedule.title" : "conferenceTitle")
                }
                if workspace != nil && model != nil {
                    formSwitch("Запланировать встречу", detail: "Выберите дату и время заранее", isOn: $planned)
                }
            }
            if planned {
                VStack(alignment: .leading, spacing: 14) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 12) { dateField; timeField }
                        VStack(alignment: .leading, spacing: 12) { dateField; timeField }
                    }
                    if meeting != nil {
                        Toggle(tr("Указать длительность"), isOn: $hasDuration).toggleStyle(.switch)
                        if hasDuration { durationStepper }
                    } else {
                        durationPicker
                    }
                    Button {
                        titleFocused = false
                        choosingZone = true
                    } label: {
                        Text(MeetingDateText.zoneLabel(zone)).font(MSTheme.font(11))
                            .frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(MSTheme.muted).accessibilityIdentifier("schedule.zone")
                    .accessibilityLabel(tr("Часовой пояс")).accessibilityValue(MeetingDateText.zoneLabel(zone))
                }
            }
            if meeting == nil {
                formSwitch("Зал ожидания", detail: "Участники с действующей ссылкой входят без ожидания", isOn: $waitingRoom)
                Text(tr("Пригласите коллег по ссылке после создания. Встречу запускает организатор."))
                    .font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
            }
            if let error { Text(tr(error)).font(MSTheme.font(12)).foregroundStyle(MSTheme.danger) }
            if busy { ProgressView().frame(maxWidth: .infinity) }
            Button(action: submit) {
                Text(tr(meeting != nil ? "Сохранить время" : (planned ? "Запланировать" : "Создать встречу")))
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).padding(.vertical, 7)
            }.buttonStyle(MSButtonStyle()).disabled(!canSubmit)
                .accessibilityIdentifier(initiallyPlanned ? "schedule.submit" : "conferenceCreateSubmit")
        }
        .onAppear(perform: initialize)
        .onChange(of: workspace?.call?.id) { _, call in
            if !planned && call != nil { dismiss() }
        }
        .sheet(isPresented: $choosingZone) {
            if let model {
                CalendarTimeZonePicker(selected: model.preferences.timeZoneIdentifier) { zone in
                    Task { await model.selectTimeZone(zone) }
                }
            }
        }
    }

    private var dateField: some View {
        WorkspaceFormField(title: "Дата") {
            DatePicker(selection: $startsAt, in: Date()..., displayedComponents: .date) { Text(tr("Дата")) }
                .labelsHidden().datePickerStyle(.compact).fixedSize().workspaceFormInput()
                .environment(\.timeZone, zone).accessibilityLabel(tr("Дата")).accessibilityIdentifier("schedule.date")
        }
    }

    private var timeField: some View {
        WorkspaceFormField(title: "Время") {
            DatePicker(selection: $startsAt, in: Date()..., displayedComponents: .hourAndMinute) { Text(tr("Время")) }
                .labelsHidden().datePickerStyle(.compact).fixedSize().workspaceFormInput()
                .environment(\.timeZone, zone).accessibilityLabel(tr("Время")).accessibilityIdentifier("schedule.time")
        }
    }

    private var durationPicker: some View {
        WorkspaceFormField(title: "Длительность") {
            Menu {
                ForEach([30, 45, 60, 90], id: \.self) { value in
                    Button {
                        duration = value; hasDuration = true; customDuration = false
                    } label: {
                        if hasDuration && !customDuration && duration == value { Label(durationLabel(value), systemImage: "checkmark") }
                        else { Text(durationLabel(value)) }
                    }
                }
                Button(tr("Другая длительность")) { hasDuration = true; customDuration = true }
                Button(tr("Без длительности")) { hasDuration = false; customDuration = false }
            } label: {
                HStack {
                    Text(hasDuration ? durationLabel(duration) : tr("Без длительности")).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Image(systemName: "chevron.down").accessibilityHidden(true)
                }.workspaceFormInput().foregroundStyle(MSTheme.ink).contentShape(Rectangle())
            }.menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain)
                .accessibilityIdentifier("schedule.durationOptions")
            if customDuration { durationStepper }
        }
    }

    private var durationStepper: some View {
        Stepper(value: $duration, in: 1...1440, step: 5) {
            Text(tr("Длительность, мин") + ": \(duration)").fixedSize(horizontal: false, vertical: true)
        }.accessibilityValue(String(duration)).accessibilityIdentifier("schedule.duration")
    }

    /// Форматирует длительность встречи для выбора в форме.
    /// - Parameter value: Число минут.
    private func durationLabel(_ value: Int) -> String {
        switch value {
        case 30: tr("30 минут")
        case 45: tr("45 минут")
        case 60: tr("1 час")
        case 90: tr("1,5 часа")
        default: "\(value) \(tr("мин"))"
        }
    }

    /// Создаёт подписанный переключатель параметра встречи с пояснением.
    /// - Parameters:
    ///   - title: Название параметра.
    ///   - detail: Поясняющий текст.
    ///   - isOn: Привязка к состоянию параметра.
    private func formSwitch(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 5) {
                Text(tr(title)).font(MSTheme.font(13, weight: .semibold))
                Text(tr(detail)).font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
            }.fixedSize(horizontal: false, vertical: true)
        }.toggleStyle(.switch).frame(minHeight: 44)
    }

    /// Заполняет поля формы исходными данными встречи или значениями для создания.
    private func initialize() {
        guard !initialized else { return }
        initialized = true
        planned = meeting != nil || (initiallyPlanned && model != nil)
        if let meeting {
            title = meeting.title
            startsAt = max(meeting.scheduledAt ?? startsAt, Date().addingTimeInterval(60))
            duration = meeting.plannedDurationMin ?? 30; hasDuration = meeting.plannedDurationMin != nil
        } else if let model {
            startsAt = max(model.calendar.date(bySettingHour: 10, minute: 0, second: 0, of: model.selectedDay) ?? startsAt,
                           Date().addingTimeInterval(3600))
        }
    }

    /// Передаёт в календарь запрос создания или переноса с параметрами формы.
    private func submit() {
        guard canSubmit else { return }
        titleFocused = false
        Task {
            let saved: Bool
            if let meeting, let model {
                saved = await model.reschedule(meeting, at: startsAt, duration: hasDuration ? duration : nil)
            } else if planned, let model {
                saved = await model.create(title: name, at: startsAt, duration: hasDuration ? duration : nil, waitingRoom: waitingRoom)
            } else if let workspace {
                saved = await workspace.create(title: name, waitingRoom: waitingRoom)
            } else { return }
            if saved && planned { dismiss(); didSave() }
        }
    }
}

private struct CalendarMeetingDetail: View {
    @Bindable var model: CalendarModel
    let meeting: Conference
    let onJoin: (Conference) -> Void
    @State private var editing = false
    @State private var rescheduled = false
    @State private var cancelling = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Text(meeting.title).font(.title2)
                Text(tr(conferenceStatus(meeting.status)))
                Text(calendarText(MeetingCalendar.timelineDate(meeting), format: "d MMMM yyyy, HH:mm ZZZZ", zone: model.zone))
                Text(model.zone.identifier).foregroundStyle(.secondary)
                if let error = model.error { Text(tr(error)).foregroundStyle(MSTheme.danger) }
                if !meeting.isClosed {
                    Button(tr("Войти")) { dismiss(); onJoin(meeting) }.accessibilityIdentifier("calendar.join")
                }
                if model.canManage(meeting) {
                    Button(tr("Перенести встречу")) { editing = true }.accessibilityIdentifier("calendar.reschedule")
                    Button(tr("Отменить встречу"), role: .destructive) { cancelling = true }.accessibilityIdentifier("calendar.cancel")
                }
            }.navigationTitle(tr("Встреча")).msInlineTitle().disabled(model.busy)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        IconButton("xmark", label: "Закрыть") { dismiss() }
                            .accessibilityIdentifier("calendar.meeting.close")
                    }
                }
                .workspaceFormPresentation(isPresented: $editing, onDismiss: {
                    if rescheduled { dismiss() }
                }) { ScheduleMeetingForm(model: model, meeting: meeting, didSave: { rescheduled = true }) }
                .confirmationDialog(tr("Отменить запланированную встречу?"), isPresented: $cancelling) {
                    Button(tr("Отменить встречу"), role: .destructive) { Task { await model.cancel(meeting); if model.error == nil { dismiss() } } }
                }
        }
    }
}

private struct CalendarTimeZonePicker: View {
    let selected: String
    let choose: (String) -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List(TimeZone.knownTimeZoneIdentifiers.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }, id: \.self) { identifier in
                Button { choose(identifier); dismiss() } label: {
                    HStack { Text(identifier); Spacer(); if identifier == selected { Image(systemName: "checkmark") } }
                }.accessibilityIdentifier("calendar.zone.\(identifier)")
            }.searchable(text: $query, prompt: tr("Поиск часового пояса"))
                .navigationTitle(tr("Часовой пояс")).msInlineTitle()
                .toolbar { ToolbarItem(placement: .cancellationAction) { IconButton("xmark", label: "Отмена") { dismiss() } } }
        }
    }
}

func calendarText(_ date: Date, format: String, zone: TimeZone) -> String {
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ru_RU")
    formatter.calendar = MeetingCalendar.calendar(in: zone); formatter.timeZone = zone; formatter.dateFormat = format
    return formatter.string(from: date)
}
private func calendarMeetingTime(_ meeting: Conference, zone: TimeZone) -> String {
    let start = MeetingCalendar.timelineDate(meeting)
    let time = calendarText(start, format: "HH:mm", zone: zone)
    guard let duration = meeting.plannedDurationMin, meeting.scheduledAt != nil, meeting.finishedAt == nil else { return time }
    return time + " — " + calendarText(start.addingTimeInterval(Double(duration) * 60), format: "HH:mm", zone: zone)
}
