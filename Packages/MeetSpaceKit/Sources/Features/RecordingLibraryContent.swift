import SwiftUI
import MeetSpaceDesignSystem

struct RecordingsPageHeader: View {
    let title: String
    let onBack: () -> Void

    var body: some View {
        PageHeader(title: title) {
            WorkspaceHeaderButton("arrow.left", label: "Назад", action: onBack)
                .accessibilityIdentifier("recordings.back")
        }
    }
}

struct RecordingLibraryContent: View {
    let entries: [RecordingLibraryEntry]
    let demo: Bool
    var loading = false
    var loadFailed = false
    var moreAvailable = false
    let open: (RecordingLibraryEntry) -> Void
    let remove: (RecordingLibraryEntry) -> Void

    @Environment(\.workspaceWidth) private var width
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var live = false
    @State private var query = ""
    @State private var meeting: String?
    @State private var days = 0
    @State private var oldestFirst = false
    @State private var grid = false
    @State private var deleteTarget: RecordingLibraryEntry?

    private var wide: Bool { width > 700 && !typeSize.isAccessibilitySize }
    private var tabEntries: [RecordingLibraryEntry] { entries.filter { $0.isLive == live } }
    private var meetings: [RecordingLibraryEntry] {
        var ids = Set<String>()
        return tabEntries.filter { ids.insert($0.meetingID).inserted }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private var found: [RecordingLibraryEntry] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let today = Date()
        return tabEntries.filter { entry in
            guard meeting == nil || entry.meetingID == meeting else { return false }
            if days > 0 {
                let calendar = Calendar.current
                let end = calendar.startOfDay(for: entry.sampleDay ?? today)
                if let cutoff = calendar.date(byAdding: .day, value: -days, to: end), entry.date < cutoff { return false }
            }
            return search.isEmpty || [entry.title, entry.owner, tr(entry.kind.title)].compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(search) }
        }.sorted { a, b in
            if a.date == b.date { return a.id < b.id }
            return oldestFirst ? a.date < b.date : a.date > b.date
        }
    }

    var body: some View {
        let results = found
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("БИБЛИОТЕКА ВСТРЕЧ")).font(MSTheme.font(10, weight: .semibold, relativeTo: .caption))
                    .tracking(1.2).foregroundStyle(MSTheme.accent)
                Text(tr("Важное остаётся с вами")).font(MSTheme.font(wide ? 26 : 24, weight: .semibold, relativeTo: .title2))
                    .tracking(-0.8).accessibilityAddTraits(.isHeader)
                Text(tr("Видео, аудио и материалы ваших встреч.")).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
            }
            tabs
            if wide {
                HStack(alignment: .bottom, spacing: 16) { search; meetingPicker.frame(maxWidth: 350) }
            } else {
                search
                meetingPicker
            }
            HStack(spacing: 10) {
                if typeSize.isAccessibilitySize { VStack(spacing: 8) { periodPicker; sortPicker } }
                else {
                    periodPicker
                    sortPicker
                }
                if wide {
                    Spacer()
                    HStack(spacing: 2) {
                        layoutButton(grid: false)
                        layoutButton(grid: true)
                    }.padding(3).background(MSTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(MSTheme.line) }
                }
            }
            if !loading || !entries.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(tr("Найдено") + ": " + String(results.count)).accessibilityIdentifier("recordings.count")
                        Spacer(minLength: 0)
                        if demo { Text(tr("Демонстрационные записи")).multilineTextAlignment(.trailing) }
                        else if moreAvailable {
                            Text(tr("Среди загруженных")).multilineTextAlignment(.trailing).accessibilityIdentifier("recordings.filterHint")
                        }
                    }.font(MSTheme.font(10, relativeTo: .caption)).foregroundStyle(MSTheme.muted).padding(.horizontal, 2)
                    if results.isEmpty {
                        if !loadFailed { emptyResults }
                    } else if wide && grid {
                        let columns = Array(repeating: GridItem(.flexible(), spacing: 16), count: width <= 1000 ? 2 : 3)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                            cards(results)
                        }
                    } else {
                        VStack(spacing: 12) { cards(results) }
                    }
                }
            }
        }.foregroundStyle(MSTheme.ink)
        .onChange(of: meetings.map(\.meetingID)) { _, values in
            if let meeting, !values.contains(meeting) { self.meeting = nil }
        }
        .confirmationDialog(tr("Удалить запись?"), isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                            titleVisibility: .visible, presenting: deleteTarget) { entry in
            Button(tr("Удалить запись"), role: .destructive) { remove(entry) }
            Button(tr("Отмена"), role: .cancel) {}
        } message: { entry in
            Text(entry.title + "\n" + tr(demo ? "Демонстрационная запись будет удалена из локального списка."
                                         : "Запись и все её материалы будут удалены для всех участников."))
        }
    }

    private var tabs: some View {
        HStack(spacing: 24) {
            ForEach([false, true], id: \.self) { isLive in
                Button {
                    if live != isLive { live = isLive; meeting = nil }
                } label: {
                    HStack(spacing: 7) {
                        Text(tr(isLive ? "В эфире" : "Завершённые")).font(MSTheme.font(13, weight: .semibold))
                        if isLive { Circle().fill(MSTheme.success).frame(width: 6, height: 6).accessibilityHidden(true) }
                    }.fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2).padding(.vertical, 8)
                        .frame(minHeight: 46).contentShape(Rectangle())
                        .foregroundStyle(live == isLive ? MSTheme.accent : MSTheme.muted)
                        .overlay(alignment: .bottom) {
                            if live == isLive { Rectangle().fill(MSTheme.accent).frame(height: 2) }
                        }
                }.buttonStyle(.plain).accessibilityAddTraits(live == isLive ? .isSelected : [])
                    .accessibilityIdentifier(isLive ? "recordings.live" : "recordings.past")
            }
            Spacer(minLength: 0)
        }.background(alignment: .bottom) { Rectangle().fill(MSTheme.line).frame(height: 1) }
    }

    private var search: some View {
        SearchBox(text: $query, placeholder: "Найти запись встречи", identifier: "recordings.search")
    }

    private var meetingPicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(tr("Встреча")).font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
            select(title: meetings.first { $0.meetingID == meeting }?.title ?? tr("Все встречи"),
                   label: "Встреча", id: "recordings.meeting") {
                Picker(tr("Встреча"), selection: $meeting) {
                    Text(tr("Все встречи")).tag(Optional<String>.none)
                    ForEach(meetings) { Text($0.title).tag(Optional($0.meetingID)) }
                }
            }
        }
    }
    /// Формирует подпись фильтра по давности записей.
    /// - Parameter period: Количество дней или ноль для всего периода.
    private func periodTitle(_ period: Int) -> String { period == 0 ? tr("Всё время") : tr("За \(period) дней") }
    private var periodPicker: some View {
        select(title: periodTitle(days), label: "Период записей", id: "recordings.period") {
            Picker(tr("Период записей"), selection: $days) {
                ForEach([0, 7, 30, 90], id: \.self) { Text(periodTitle($0)).tag($0) }
            }
        }.frame(maxWidth: wide ? 170 : .infinity)
    }
    private var sortPicker: some View {
        select(title: tr(oldestFirst ? "Сначала старые" : "Сначала новые"), label: "Сортировка записей", id: "recordings.sort") {
            Picker(tr("Сортировка записей"), selection: $oldestFirst) {
                Text(tr("Сначала новые")).tag(false)
                Text(tr("Сначала старые")).tag(true)
            }
        }.frame(maxWidth: wide ? 180 : .infinity)
    }
    /// Создаёт меню фильтра библиотеки записей.
    /// - Parameters:
    ///   - title: Текущее значение фильтра.
    ///   - label: Название фильтра для VoiceOver.
    ///   - id: Идентификатор элемента для автоматизации.
    ///   - options: Содержимое меню выбора.
    private func select<Options: View>(title: String, label: String, id: String, @ViewBuilder options: () -> Options) -> some View {
        Menu {
            options()
        } label: {
            HStack(spacing: 6) {
                Text(title).font(MSTheme.font(12)).fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                WorkspaceIcon("chevron.down", size: 13)
            }.padding(.horizontal, 12).padding(.vertical, 6).frame(minHeight: 46)
                .background(MSTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(MSTheme.line) }
                .contentShape(Rectangle())
        }.buttonStyle(.plain).menuIndicator(.hidden).accessibilityLabel(tr(label)).accessibilityValue(title).accessibilityIdentifier(id)
    }

    /// Создаёт кнопку переключения вида библиотеки.
    /// - Parameter value: Показывать карточки сеткой при выборе этой кнопки.
    private func layoutButton(grid value: Bool) -> some View {
        Button { grid = value } label: {
            WorkspaceIcon(value ? "square.grid.2x2" : "list.bullet", size: 18).frame(width: 44, height: 44)
                .foregroundStyle(grid == value ? MSTheme.accent : MSTheme.muted)
                .background(grid == value ? MSTheme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityLabel(tr(value ? "Плитка" : "Список")).accessibilityAddTraits(grid == value ? .isSelected : [])
    }

    /// Показывает карточки найденных записей с действиями открытия и удаления.
    /// - Parameter results: Записи после применения фильтров.
    private func cards(_ results: [RecordingLibraryEntry]) -> some View {
        ForEach(results) { entry in
            RecordingListCard(entry: entry, wide: wide, grid: wide && grid, open: { open(entry) }, remove: { deleteTarget = entry })
                .disabled(loading)
        }
    }

    private var emptyResults: some View {
        VStack(spacing: 10) {
            WorkspaceIcon("play.circle", size: 36).foregroundStyle(MSTheme.accent)
            Text(tr("Записи не найдены")).font(MSTheme.font(18, weight: .semibold))
            if !query.isEmpty || meeting != nil || days != 0 {
                Text(tr("Попробуйте другую встречу или измените условия поиска.")).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
                Button(tr("Сбросить фильтры")) { query = ""; days = 0; meeting = nil }
                    .buttonStyle(MSTextButtonStyle()).accessibilityIdentifier("recordings.reset")
            } else {
                Text(tr(live ? "Здесь появятся записи встреч в эфире." : "Здесь появятся доступные вам записи встреч."))
                    .font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
            }
        }.multilineTextAlignment(.center).padding(.vertical, 20).frame(maxWidth: .infinity).msCard()
    }
}
