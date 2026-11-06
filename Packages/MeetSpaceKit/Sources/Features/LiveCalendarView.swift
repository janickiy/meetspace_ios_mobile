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
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(tr("Календарь")).font(MSTheme.font(28, weight: .semibold, relativeTo: .title)).accessibilityAddTraits(.isHeader)
                            Text(tr("Время для важных разговоров.")).font(MSTheme.font(13)).foregroundStyle(MSTheme.muted)
                        }
                        Spacer()
                        IconButton("arrow.clockwise", label: "Обновить") { Task { await model.load() } }
                        IconButton("plus", label: "Запланировать встречу") { creating = true }.accessibilityIdentifier("calendar.schedule")
                    }
                    Picker(tr("Вид календаря"), selection: Binding(get: { model.preferences.displayMode }, set: { mode in Task { await model.selectMode(mode) } })) {
                        Text(tr("Неделя")).tag(CalendarDisplayMode.week)
                        Text(tr("Месяц")).tag(CalendarDisplayMode.month)
                        Text(tr("Список")).tag(CalendarDisplayMode.list)
                    }.pickerStyle(.segmented).accessibilityIdentifier("calendar.mode")
                    HStack {
                        Picker(tr("Встречи"), selection: Binding(get: { model.scope }, set: { value in Task { await model.selectScope(value) } })) {
                            Text(tr("Все встречи")).tag(ConferenceTimelineScope.all)
                            Text(tr("Я организатор")).tag(ConferenceTimelineScope.owned)
                            Text(tr("Я участник")).tag(ConferenceTimelineScope.participating)
                        }.pickerStyle(.menu)
                        Spacer()
                        Button { choosingZone = true } label: { Label(model.zone.identifier, systemImage: "clock") }
                            .font(MSTheme.font(12)).accessibilityIdentifier("calendar.timeZone")
                    }
                    if let error = model.error { Text(tr(error)).foregroundStyle(MSTheme.danger) }
                    if model.creationUncertain {
                        Button(tr("Список проверен — разрешить новое создание")) { model.acknowledgeCreationCheck() }
                            .disabled(model.loading).accessibilityIdentifier("calendar.acknowledgeCreation")
                    }
                    periodControls
                    if geometry.size.width >= 840 && !typeSize.isAccessibilitySize {
                        HStack(alignment: .top, spacing: 24) {
                            calendarBody.frame(maxWidth: .infinity)
                            sidePanel.frame(width: 250)
                        }
                    } else { calendarBody }
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
                }.padding(20).frame(maxWidth: 1120).frame(maxWidth: .infinity)
            }.refreshable { await model.load() }
        }.background(MSTheme.background).foregroundStyle(MSTheme.ink)
            .accessibilityIdentifier("screen.liveCalendar")
            .task { await model.initialize() }
            .sheet(isPresented: $creating) { ScheduleMeetingForm(model: model) }
            .sheet(item: $selected) { meeting in CalendarMeetingDetail(model: model, meeting: meeting, onJoin: onJoin) }
            .sheet(isPresented: $choosingZone) {
                CalendarTimeZonePicker(selected: model.preferences.timeZoneIdentifier) { identifier in Task { await model.selectTimeZone(identifier) } }
            }
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
    }
    private var navigationButtons: some View {
        HStack(spacing: 0) {
            Button(tr("Сегодня")) { Task { await model.selectDay(Date()) } }.buttonStyle(MSTextButtonStyle())
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) { ForEach(MeetingCalendar.days(in: model.interval, zone: model.zone), id: \.self) { day in dayButton(day) } }
                .padding(10)
        }.background(MSTheme.surface, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(MSTheme.line))
    }
    private var monthGrid: some View {
        let days = MeetingCalendar.days(in: model.interval, zone: model.zone)
        let leading = (model.calendar.component(.weekday, from: model.interval.start) + 5) % 7
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 28), spacing: 3), count: 7), spacing: 5) {
            ForEach(["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"], id: \.self) { Text(tr($0)).font(MSTheme.font(10)).foregroundStyle(MSTheme.muted) }
            ForEach(0..<leading, id: \.self) { _ in Color.clear.frame(height: 44) }
            ForEach(days, id: \.self) { day in dayButton(day, compact: true) }
        }.padding(10).background(MSTheme.surface, in: RoundedRectangle(cornerRadius: 20))
    }
    private func dayButton(_ day: Date, compact: Bool = false) -> some View {
        let selected = model.calendar.isDate(day, inSameDayAs: model.selectedDay)
        let hasEvent = model.meetings.contains { model.calendar.isDate(MeetingCalendar.timelineDate($0), inSameDayAs: day) }
        return Button { Task { await model.selectDay(day) } } label: {
            VStack(spacing: compact ? 4 : 8) {
                if !compact { Text(calendarText(day, format: "EE", zone: model.zone)).font(MSTheme.font(10)) }
                Text(calendarText(day, format: "d", zone: model.zone)).font(MSTheme.font(17, weight: .semibold))
                Circle().fill(hasEvent ? (selected ? MSTheme.surface : MSTheme.accent) : .clear).frame(width: 4, height: 4)
            }.frame(minWidth: compact ? 28 : 38, maxWidth: compact ? .infinity : nil, minHeight: compact ? 44 : 70)
                .padding(.horizontal, compact ? 0 : 4)
                .background(selected ? MSTheme.accent : MSTheme.surface, in: RoundedRectangle(cornerRadius: 13))
                .foregroundStyle(selected ? MSTheme.surface : MSTheme.ink)
        }.buttonStyle(.plain).accessibilityLabel(calendarText(day, format: "d MMMM yyyy", zone: model.zone))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var agenda: some View {
        let events = model.dayMeetings
        let hours = events.map { model.calendar.component(.hour, from: MeetingCalendar.timelineDate($0)) }
        let first = min(9, hours.min() ?? 9), last = max(18, hours.max() ?? 18)
        return VStack(alignment: .leading, spacing: 0) {
            if events.isEmpty && !model.loading && model.feedErrors.isEmpty { emptyDay.padding(.bottom, 12) }
            ForEach(first...last, id: \.self) { hour in
                HStack(alignment: .top, spacing: 10) {
                    Text(String(format: "%02d:00", hour)).font(MSTheme.font(10)).foregroundStyle(MSTheme.muted).frame(width: 43, alignment: .leading).padding(.top, 4)
                    VStack(spacing: 6) {
                        Rectangle().fill(MSTheme.line).frame(height: 1)
                        ForEach(events.filter { model.calendar.component(.hour, from: MeetingCalendar.timelineDate($0)) == hour }) { event in eventCard(event) }
                    }.frame(maxWidth: .infinity, minHeight: 78, alignment: .top)
                }
            }
        }
    }
    private var emptyDay: some View {
        Text(tr(model.hasMore ? "На загруженных страницах встреч нет." : "Нет встреч в выбранном периоде."))
            .font(MSTheme.font(13)).foregroundStyle(MSTheme.muted)
    }
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
        }.buttonStyle(.plain).accessibilityIdentifier("calendar.event.\(meeting.id.uuidString.lowercased())")
    }
    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("На этой неделе")).font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
            Text(tr("Хороший ритм")).font(MSTheme.font(21, weight: .semibold))
            Text(tr("Все встречи команды в вашем часовом поясе.")).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
            let week = MeetingCalendar.interval(containing: model.selectedDay, mode: .week, in: model.zone)
            ForEach(model.meetings.filter { MeetingCalendar.includes(MeetingCalendar.timelineDate($0), interval: week) }.prefix(5)) { meeting in
                Button { selected = meeting } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meeting.title).font(MSTheme.font(12, weight: .semibold))
                        Text(calendarText(MeetingCalendar.timelineDate(meeting), format: "EE, HH:mm", zone: model.zone)).font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
                    }.frame(minHeight: 44)
                }.buttonStyle(.plain)
            }
        }.msCard(padding: 22)
    }
}

struct ScheduleMeetingForm: View {
    @Bindable var model: CalendarModel
    var meeting: Conference? = nil
    var didSave: () -> Void = {}
    @State private var title = ""
    @State private var startsAt = Date().addingTimeInterval(3600)
    @State private var duration = 30
    @State private var hasDuration = true
    @State private var waitingRoom = false
    @State private var choosingZone = false
    @State private var initialized = false
    @FocusState private var titleFocused: Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                if meeting == nil {
                    TextField(tr("Название встречи"), text: $title)
                        .focused($titleFocused).submitLabel(.done)
                        .onSubmit { titleFocused = false }
                        .accessibilityIdentifier("schedule.title")
                }
                else { Text(meeting?.title ?? "").font(.headline) }
                DatePicker(tr("Дата и время"), selection: $startsAt, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    .environment(\.timeZone, model.zone).accessibilityIdentifier("schedule.date")
                Button { choosingZone = true } label: { Label(model.zone.identifier, systemImage: "clock") }
                Text(calendarText(startsAt, format: "d MMMM yyyy, HH:mm ZZZZ", zone: model.zone)).font(.footnote).foregroundStyle(.secondary)
                Toggle(tr("Указать длительность"), isOn: $hasDuration)
                if hasDuration {
                    Stepper(value: $duration, in: 1...1440, step: 5) { Text(tr("Длительность, мин") + ": \(duration)") }
                        .accessibilityIdentifier("schedule.duration")
                }
                if meeting == nil { Toggle(tr("Комната ожидания"), isOn: $waitingRoom) }
                if let error = model.error { Text(tr(error)).foregroundStyle(MSTheme.danger) }
                Button(tr(meeting == nil ? "Запланировать встречу" : "Сохранить время")) {
                    titleFocused = false
                    Task {
                        let saved: Bool
                        if let meeting { saved = await model.reschedule(meeting, at: startsAt, duration: hasDuration ? duration : nil) }
                        else { saved = await model.create(title: title, at: startsAt, duration: hasDuration ? duration : nil, waitingRoom: waitingRoom) }
                        if saved { dismiss(); didSave() }
                    }
                }.disabled(model.busy || (meeting == nil && (title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.creationUncertain)))
                    .accessibilityIdentifier("schedule.submit")
            }.scrollDismissesKeyboard(.interactively)
                .navigationTitle(tr(meeting == nil ? "Запланировать" : "Перенести встречу")).msInlineTitle()
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tr("Отмена")) { dismiss() }.disabled(model.busy) } }
                .disabled(model.busy).interactiveDismissDisabled(model.busy)
                .onAppear {
                    guard !initialized else { return }; initialized = true
                    if let meeting {
                        title = meeting.title; startsAt = max(meeting.scheduledAt ?? startsAt, Date().addingTimeInterval(60))
                        duration = meeting.plannedDurationMin ?? 30; hasDuration = meeting.plannedDurationMin != nil
                    } else {
                        startsAt = max(model.calendar.date(bySettingHour: 10, minute: 0, second: 0, of: model.selectedDay) ?? startsAt, Date().addingTimeInterval(3600))
                    }
                }
                .sheet(isPresented: $choosingZone) {
                    CalendarTimeZonePicker(selected: model.preferences.timeZoneIdentifier) { zone in Task { await model.selectTimeZone(zone) } }
                }
        }
    }
}

private struct CalendarMeetingDetail: View {
    @Bindable var model: CalendarModel
    let meeting: Conference
    let onJoin: (Conference) -> Void
    @State private var editing = false
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
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tr("Закрыть")) { dismiss() } } }
                .sheet(isPresented: $editing) { ScheduleMeetingForm(model: model, meeting: meeting, didSave: { dismiss() }) }
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
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tr("Отмена")) { dismiss() } } }
        }
    }
}

private func calendarText(_ date: Date, format: String, zone: TimeZone) -> String {
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
