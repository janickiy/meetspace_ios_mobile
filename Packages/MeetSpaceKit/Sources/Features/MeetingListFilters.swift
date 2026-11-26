import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

enum MeetingDateText {
    /// Формирует название часового пояса и смещение от UTC.
    /// - Parameter zone: Пояс, используемый при показе встреч.
    static func zoneLabel(_ zone: TimeZone) -> String {
        let city = zone.localizedName(for: .generic, locale: Locale(identifier: "ru_RU"))
        let location = zone.identifier == "Europe/Moscow" ? tr("Москва") : city ?? zone.identifier
        let offset = zone.secondsFromGMT()
        let minutes = abs(offset / 60) % 60
        let suffix = minutes == 0 ? "" : String(format: ":%02d", minutes)
        return "\(location) · UTC\(offset >= 0 ? "+" : "−")\(abs(offset / 3600))\(suffix)"
    }
}

extension ConferenceTimelineView {
    var meetingsTabTitle: String {
        switch self {
        case .upcoming: "Предстоящие"
        case .active: "Активные"
        case .past: "Завершённые"
        }
    }
    var meetingsCaption: String {
        switch self {
        case .upcoming: "Предстоящие и без даты"
        case .active: "Встречи в эфире"
        case .past: "Завершённые и отменённые"
        }
    }
}

private extension ConferenceTimelineScope {
    var meetingsTitle: String {
        switch self {
        case .all: "Все мои встречи"
        case .owned: "Я организатор"
        case .participating: "Я участник"
        }
    }
}

struct MeetingListFilter: Equatable {
    var scope: ConferenceTimelineScope = .all
    var from: Date?
    var to: Date?

    var count: Int { (scope == .all ? 0 : 1) + (from == nil && to == nil ? 0 : 1) }
    var scopeTitle: String { scope.meetingsTitle }

    /// Проверяет, проходит ли встреча фильтры по дате и роли пользователя.
    /// - Parameters:
    ///   - date: Дата встречи, если она назначена.
    ///   - mine: Является ли пользователь организатором.
    ///   - calendar: Календарь для сравнения по дням.
    func matches(date: Date?, mine: Bool, calendar: Calendar) -> Bool {
        if scope == .owned && !mine || scope == .participating && mine { return false }
        if let from, date.map({ calendar.compare($0, to: from, toGranularity: .day) != .orderedAscending }) != true { return false }
        if let to, date.map({ calendar.compare($0, to: to, toGranularity: .day) != .orderedDescending }) != true { return false }
        return true
    }
}

struct MeetingFilterFields: View {
    @Binding var filter: MeetingListFilter
    let zone: TimeZone
    var inlineWidth: CGFloat?
    private var inline: Bool { inlineWidth != nil }
    var reset: (() -> Void)?

    var body: some View {
        let layout = inline ? AnyLayout(HStackLayout(alignment: .bottom, spacing: 14)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
        layout {
            field("Моё участие") {
                Menu {
                    ForEach(ConferenceTimelineScope.allCases, id: \.self) { scope in
                        Button { filter.scope = scope } label: {
                            if scope == filter.scope { Label(tr(scope.meetingsTitle), systemImage: "checkmark") }
                            else { Text(tr(scope.meetingsTitle)) }
                        }
                    }
                } label: { control(filter.scopeTitle, "chevron.down") }
                    .buttonStyle(.plain).accessibilityLabel(tr("Моё участие")).accessibilityValue(tr(filter.scopeTitle))
                    .accessibilityIdentifier("meetingFilters.scope")
            }
            .frame(width: inlineWidth.map { ($0 - 48 - 42) * 1.15 / 3.15 })
            dayField("С даты", selection: $filter.from, range: Date.distantPast...(filter.to ?? .distantFuture))
            dayField("По дату", selection: $filter.to, range: (filter.from ?? .distantPast)...Date.distantFuture)
            if let reset { IconButton("arrow.counterclockwise", label: "Сбросить фильтры", action: reset).frame(width: 48) }
        }
        .environment(\.timeZone, zone)
    }

    /// Размещает элемент фильтра под его заголовком.
    /// - Parameters:
    ///   - title: Название фильтра.
    ///   - content: Элемент выбора значения.
    @ViewBuilder private func field<Content: View>(_ title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        if inline {
            VStack(alignment: .leading, spacing: 7) {
                Text(tr(title)).font(MSTheme.font(11, weight: .semibold))
                content()
            }.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            WorkspaceFormField(title: title, content: content)
        }
    }

    /// Показывает выбор необязательной даты в фильтре встреч.
    /// - Parameters:
    ///   - title: Подпись границы периода.
    ///   - selection: Выбранный день или `nil` для открытой границы.
    ///   - range: Допустимые даты.
    private func dayField(_ title: String, selection: Binding<Date?>, range: ClosedRange<Date>) -> some View {
        field(title) {
            OptionalMeetingDay(selection: selection, range: range, zone: zone, title: title) {
                control(selection.wrappedValue.map { calendarText($0, format: "dd.MM.yyyy", zone: zone) } ?? tr("дд.мм.гггг"), "calendar")
            }
        }
    }

    /// Оформляет значение фильтра вместе со значком.
    /// - Parameters:
    ///   - title: Отображаемое значение.
    ///   - icon: Значок справа.
    @ViewBuilder private func control(_ title: String, _ icon: String) -> some View {
        let value = HStack(spacing: 6) {
            Text(verbatim: tr(title)).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 2)
            WorkspaceIcon(icon, size: 14)
        }
        if inline {
            value.font(MSTheme.font(12)).padding(.horizontal, 12).frame(minHeight: 50)
                .background(MSTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(MSTheme.line).allowsHitTesting(false) }
                .contentShape(Rectangle())
        } else {
            value.workspaceFormInput().contentShape(Rectangle())
        }
    }
}

private struct OptionalMeetingDay<Label: View>: View {
    @Binding var selection: Date?
    let range: ClosedRange<Date>
    let zone: TimeZone
    let title: String
    @ViewBuilder var label: () -> Label
    @State private var presented = false
    @State private var draft = Date()
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button {
            draft = min(max(selection ?? Date(), range.lowerBound), range.upperBound)
            presented = true
        } label: { label() }
            .buttonStyle(.plain).accessibilityLabel(tr(title)).accessibilityValue(selection.map { calendarText($0, format: "d MMMM yyyy", zone: zone) } ?? tr("Без даты"))
            .popover(isPresented: $presented) {
                ViewThatFits(in: .vertical) {
                    calendarForm.fixedSize(horizontal: false, vertical: true)
                    ScrollView { calendarForm }
                }.frame(idealWidth: 340, maxWidth: 420)
                    .tint(MSTheme.accent)
                    .presentationCompactAdaptation(horizontal: .popover, vertical: .sheet)
            }
    }

    private var calendarForm: some View {
        VStack(spacing: 12) {
            DatePicker(tr(title), selection: $draft, in: range, displayedComponents: .date)
                .datePickerStyle(.graphical).environment(\.timeZone, zone)
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
            layout {
                Button(tr("Сбросить")) {
                    selection = nil
                    presented = false
                }.buttonStyle(MSButtonStyle(primary: false))
                Button(tr("Готово")) {
                    selection = MeetingCalendar.calendar(in: zone).startOfDay(for: draft)
                    presented = false
                }.buttonStyle(MSButtonStyle())
            }
        }.padding(16)
    }
}
