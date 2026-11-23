import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

struct MeetingsActions {
    let create: () -> Void
    let schedule: () -> Void
    let join: () -> Void
    let calendar: () -> Void
    let recordings: () -> Void
    let folders: () -> Void
    let notifications: () -> Void
}

struct MeetingsDashboard<Value: Identifiable>: View {
    let items: [MeetingListItem<Value>]
    let zone: TimeZone
    let state: LoadState
    var error: String?
    let retry: () -> Void
    var loadMore: (() async -> Void)?
    var loadingMore = false
    let actions: MeetingsActions
    let open: (Value) -> Void
    let details: (Value) -> Void
    let identifier: (Value) -> String
    @State private var query = ""
    @State private var tab: ConferenceTimelineView = .upcoming
    @State private var filter = MeetingListFilter()
    @State private var draft = MeetingListFilter()
    @State private var editingFilters = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.colorScheme) private var scheme

    private var results: [MeetingListItem<Value>] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let calendar = MeetingCalendar.calendar(in: zone)
        return items.filter {
            $0.status == tab && (text.isEmpty || $0.title.localizedCaseInsensitiveContains(text))
                && filter.matches(date: $0.date, mine: $0.mine, calendar: calendar)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Встречи") {
                WorkspaceHeaderButton("calendar", label: "Открыть календарь", action: actions.calendar)
                    .accessibilityIdentifier("meetingsCalendar")
                WorkspaceHeaderButton("play.circle", label: "Записи встреч", action: actions.recordings)
                WorkspaceBell(action: actions.notifications)
            }
            GeometryReader { proxy in
                let wide = WorkspaceLayout.usesColumns(width: proxy.size.width, sizeClass: sizeClass, typeSize: typeSize)
                let large = wide && proxy.size.width >= 1080
                let inset: CGFloat = wide && proxy.size.width >= 780 ? 54 : (proxy.size.width < 360 ? 12 : 16)
                let width = min(1200, max(0, proxy.size.width - 2 * inset))
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        quickActions(wide: wide, large: large, width: width)
                        if wide { Rectangle().fill(MSTheme.line).frame(height: 1).padding(.top, 24) }
                        shortcuts(wide: wide).padding(.top, 8)
                        sectionHeading(wide: wide).padding(.top, 24)
                        VStack(alignment: .leading, spacing: 0) { controls(wide: wide && width >= 650, large: large, width: width) }.padding(.top, 14)
                        if let error { Text(tr(error)).foregroundStyle(MSTheme.danger).padding(.top, 12) }
                        let filtered = results
                        Text(tr(tab.meetingsCaption) + " · \(filtered.count)").font(MSTheme.font(wide ? 11 : 10))
                            .foregroundStyle(MSTheme.muted).frame(minHeight: wide ? 17 : 15)
                            .padding(.top, wide ? 21 : 16).padding(.bottom, 10)
                        StateContent(state: state, retry: retry) {
                            if filtered.isEmpty {
                                if loadMore == nil { emptyResults }
                                else { Text(tr("В загруженной части списка таких встреч пока нет."))
                                    .font(MSTheme.font(13)).foregroundStyle(MSTheme.muted).padding(.vertical, 16) }
                            }
                            LazyVStack(spacing: 10) {
                                ForEach(filtered) { item in
                                    MeetingListCard(item: item, zone: zone, wide: wide, identifier: identifier(item.value),
                                        open: { open(item.value) }, details: { details(item.value) })
                                }
                            }
                            if let loadMore {
                                Button(tr("Загрузить ещё встречи")) { Task { await loadMore() } }
                                    .buttonStyle(MSButtonStyle(primary: false)).disabled(loadingMore).padding(.top, 12)
                            }
                        }
                    }.frame(maxWidth: 1200).padding(.horizontal, inset)
                        .padding(.top, wide ? 28 : 20).padding(.bottom, wide ? 36 : 30).frame(maxWidth: .infinity)
                }
            }
        }.background(MSTheme.background).foregroundStyle(MSTheme.ink).toolbar(.hidden)
            .sheet(isPresented: $editingFilters) {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            MeetingFilterFields(filter: $draft, zone: zone, reset: {})
                            Text(tr("Дата включается в период. Встречи без даты доступны без фильтра по периоду."))
                                .font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
                            Button(tr("Применить")) { filter = draft; editingFilters = false }.buttonStyle(MSButtonStyle())
                            Button(tr("Сбросить")) { reset(); editingFilters = false }.buttonStyle(MSButtonStyle(primary: false))
                        }.padding(20)
                    }.navigationTitle(tr("Фильтры встреч")).msInlineTitle()
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tr("Отмена")) { editingFilters = false } } }
                }.presentationDetents([.medium, .large])
            }
    }

    private func quickActions(wide: Bool, large: Bool, width: CGFloat) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: wide ? 14 : 10))
        return VStack(spacing: 10) {
            layout {
                quickButton("Новая встреча", "Начать разговор сейчас", icon: "video", primary: true, wide: wide, action: actions.create)
                    .accessibilityIdentifier("createConference")
                quickButton(large ? "Запланировать встречу" : "Запланировать", "Выбрать дату и время", icon: "calendar",
                    primary: false, wide: wide, action: actions.schedule).accessibilityIdentifier("scheduleMeeting")
                if wide { joinButton(wide: true).frame(width: (width - 28) * 0.9 / 2.9) }
            }
            if !wide { joinButton(wide: false) }
        }
    }

    private func quickButton(_ title: String, _ subtitle: String, icon: String, primary: Bool, wide: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            let layout = wide ? AnyLayout(HStackLayout(spacing: 14)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            layout {
                HStack {
                    WorkspaceIcon(icon, size: 25).foregroundStyle(primary ? (scheme == .dark ? MSTheme.surface : .white) : MSTheme.brandAccent)
                    if !wide {
                        Spacer()
                        WorkspaceIcon("arrow.up.right", size: 16).opacity(0.5)
                    }
                }.fixedSize(horizontal: wide, vertical: true).accessibilityHidden(true)
                if !wide { Spacer(minLength: 0) }
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr(title)).font(MSTheme.font(wide ? 13 : 14, weight: .semibold)).tracking(-0.25)
                    if wide { Text(tr(subtitle)).font(MSTheme.font(10)).foregroundStyle(primary ? (scheme == .dark ? MSTheme.surface : Color.white).opacity(0.85) : MSTheme.muted) }
                }.multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }.padding(wide ? 18 : 16).frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: wide ? 110 : 98, alignment: wide ? .leading : .top)
                .foregroundStyle(primary && scheme != .dark ? .white : (primary ? MSTheme.surface : MSTheme.ink))
                .background(primary ? MSTheme.brandAccent : MSTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                .overlay { if !primary { RoundedRectangle(cornerRadius: 16).strokeBorder(MSTheme.line) } }
        }.buttonStyle(.plain)
    }

    private func joinButton(wide: Bool) -> some View {
        Button(action: actions.join) {
            HStack(spacing: wide ? 14 : 8) {
                WorkspaceIcon("link", size: wide ? 25 : 16)
                Text(tr("Подключиться по ссылке")).font(MSTheme.font(wide ? 13 : 12))
                if !wide { WorkspaceIcon("arrow.right", size: 14) }
            }.padding(.horizontal, wide ? 18 : 0).frame(maxWidth: .infinity, alignment: wide ? .leading : .center)
                .frame(minHeight: wide ? 110 : 32).foregroundStyle(MSTheme.accent).contentShape(Rectangle())
                .overlay { if wide { RoundedRectangle(cornerRadius: 16).strokeBorder(MSTheme.line) } }
        }.buttonStyle(.plain).accessibilityIdentifier("joinInvitation")
    }

    private func shortcuts(wide: Bool) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: wide ? 10 : 8))
        return layout {
            shortcut("Записи и материалы", "play.circle", wide: wide, action: actions.recordings).accessibilityIdentifier("meetingsRecordings")
            shortcut("Мои папки", "folder", wide: wide, action: actions.folders).accessibilityIdentifier("meetingsFolders")
        }.frame(maxWidth: wide ? 650 : .infinity, alignment: .leading)
    }

    private func shortcut(_ label: String, _ icon: String, wide: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                WorkspaceIcon(icon, size: 19).foregroundStyle(MSTheme.brandAccent)
                Text(tr(label)).font(MSTheme.font(wide ? 12 : 11)).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                WorkspaceIcon("chevron.right", size: 14).foregroundStyle(MSTheme.accent)
            }.padding(.horizontal, wide ? 12 : 9).padding(.vertical, 9).frame(maxWidth: .infinity).frame(minHeight: wide ? 48 : 53)
                .background(MSTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(MSTheme.line) }
        }.buttonStyle(.plain)
    }

    private func sectionHeading(wide: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack { heading(wide: wide); Spacer(minLength: 14); zoneText(wide: wide) }
            VStack(alignment: .leading) { heading(wide: wide); zoneText(wide: wide) }
        }.frame(minHeight: wide ? 33 : 26)
    }

    private func heading(wide: Bool) -> some View {
        Text(tr("Мои встречи")).font(MSTheme.font(wide ? 22 : 17, weight: .semibold, relativeTo: .title2))
            .tracking(-0.35).fixedSize().accessibilityAddTraits(.isHeader)
    }

    private func zoneText(wide: Bool) -> some View {
        Text(MeetingDateText.zoneLabel(zone)).font(MSTheme.font(wide ? 11 : 10)).foregroundStyle(MSTheme.muted)
    }

    @ViewBuilder private func controls(wide: Bool, large: Bool, width: CGFloat) -> some View {
        if wide {
            HStack(spacing: 25) {
                tabs(large: large).frame(maxWidth: large ? 430 : .infinity)
                if large { Spacer(minLength: 0) }
                searchField.frame(width: large ? 320 : 260).offset(y: 2)
            }
            MeetingFilterFields(filter: $filter, zone: zone, inlineWidth: width - 32, reset: reset).padding(16)
                .frame(minHeight: 106).overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(MSTheme.line) }.padding(.top, 20)
        } else {
            HStack(spacing: 8) {
                searchField
                Button(action: editFilters) {
                    WorkspaceIcon("slider.horizontal.3", size: 20)
                        .frame(width: 46, height: 46).overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(MSTheme.line) }
                        .overlay(alignment: .topTrailing) {
                            if filter.count > 0 { Text("\(filter.count)").font(MSTheme.font(9)).foregroundStyle(.white)
                                .padding(4).background(MSTheme.accent, in: Circle()).offset(x: 3, y: -4) }
                        }
                }.buttonStyle(.plain).accessibilityLabel(tr("Фильтры встреч"))
            }
            tabs(large: false).padding(.top, 12)
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 7)) : AnyLayout(HStackLayout(spacing: 7))
            layout {
                chip(filter.scopeTitle, icon: "person.2", menu: true)
                chip(filter.from == nil && filter.to == nil ? "Период" : "Период выбран", icon: "calendar", menu: false)
                if filter.count > 0 {
                    Spacer()
                    IconButton("xmark", label: "Сбросить фильтры", action: reset)
                }
            }.padding(.top, 12)
        }
    }

    private let searchIdentifier = "searchField." + "Поиск встреч"

    private var searchField: some View {
        HStack(spacing: 10) {
            WorkspaceIcon("magnifyingglass", size: 20).foregroundStyle(MSTheme.muted)
            #if os(iOS)
            AccessibleTextField(text: $query, placeholder: tr("Найти встречу"), label: tr("Найти встречу"), identifier: searchIdentifier)
                .frame(minHeight: 44)
            #else
            TextField(tr("Найти встречу"), text: $query).textFieldStyle(.plain).font(MSTheme.font(13))
                .accessibilityIdentifier(searchIdentifier)
            #endif
            if !query.isEmpty { IconButton("xmark", label: "Очистить поиск") { query = "" } }
        }.padding(.horizontal, 12).frame(minHeight: 46)
            .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(MSTheme.line).allowsHitTesting(false) }
    }

    private func tabs(large: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(ConferenceTimelineView.allCases, id: \.self) { value in
                Button { tab = value } label: {
                    Text(tr(value.meetingsTabTitle)).font(MSTheme.font(large ? 14 : 12, weight: tab == value ? .semibold : .regular))
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity).frame(minHeight: 47).foregroundStyle(tab == value ? MSTheme.accent : MSTheme.muted)
                        .overlay(alignment: .bottom) { Rectangle().fill(tab == value ? MSTheme.accent : MSTheme.line).frame(height: tab == value ? 2 : 1) }
                }.buttonStyle(.plain).accessibilityAddTraits(tab == value ? .isSelected : [])
            }
        }
    }

    private func chip(_ title: String, icon: String, menu: Bool) -> some View {
        let selected = !menu && (filter.from != nil || filter.to != nil)
        return Button(action: editFilters) {
            HStack(spacing: 6) {
                WorkspaceIcon(icon, size: 13); Text(tr(title))
                if menu { WorkspaceIcon("chevron.down", size: 13) }
            }.font(MSTheme.font(10)).padding(.horizontal, 9).frame(minHeight: 34)
                .foregroundStyle(selected ? MSTheme.accent : MSTheme.muted)
                .background(selected ? MSTheme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? MSTheme.accent : MSTheme.line) }
        }.buttonStyle(.plain)
    }

    private var emptyResults: some View {
        let searching = !query.isEmpty || filter.count > 0
        let title: String = switch tab {
        case .upcoming: "Самое время для первой встречи"
        case .active: "Сейчас нет активных встреч"
        case .past: "Здесь будет история встреч"
        }
        return VStack(spacing: 12) {
            WorkspaceIcon("calendar", size: 25).foregroundStyle(MSTheme.brandAccent).frame(width: 56, height: 56)
                .background(MSTheme.accentSoft, in: RoundedRectangle(cornerRadius: 18))
            Text(tr(searching ? "Встречи не найдены" : title)).font(MSTheme.font(17, weight: .semibold))
            Text(tr(searching ? "Попробуйте другое название или измените фильтры." : "Создайте встречу и пригласите коллег по ссылке."))
                .font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
            Button(tr(searching ? "Сбросить фильтры" : "Создать встречу"), action: searching ? reset : actions.create)
                .buttonStyle(MSButtonStyle(primary: false)).frame(maxWidth: 240)
        }.multilineTextAlignment(.center).padding(.vertical, 28).frame(maxWidth: .infinity)
    }

    private func editFilters() { draft = filter; editingFilters = true }
    private func reset() { query = ""; filter = MeetingListFilter() }
}
