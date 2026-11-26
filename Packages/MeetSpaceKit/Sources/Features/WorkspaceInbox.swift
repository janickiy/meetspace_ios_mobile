import SwiftUI
import MeetSpaceAPI
import MeetSpaceCore
import MeetSpaceDesignSystem

@MainActor @Observable final class WorkspaceInbox {
    struct Event: Identifiable {
        let id: UUID
        let kind: String
        let detail: String
        let time: String
        let recent: Bool
        var isRead: Bool
        let route: AppRoute?

        var label: (title: String, icon: String, category: String) {
            switch kind {
            case "conference.soon": ("Встреча скоро начнётся", "calendar", "Напоминание")
            case "conference.invited": ("Приглашение на встречу", "person.badge.plus", "Приглашение")
            case "conference.rescheduled": ("Время встречи изменилось", "calendar", "Встреча")
            case "conference.cancelled": ("Встреча отменена", "calendar", "Встреча")
            case "recording.ready": ("Запись встречи готова", "play.circle", "Запись")
            case "recording.failed": ("Не удалось создать запись", "exclamationmark.circle", "Запись")
            case "admission.decided": ("Запрос на вход рассмотрен", "person.crop.circle", "Встреча")
            case "mention": ("Вас упомянули в группе", "bubble.left.and.bubble.right", "Сообщение")
            default:
                if case .conversation = route { ("Новое сообщение", "bubble.left.and.bubble.right", "Сообщение") }
                else { ("Уведомление", "bell", "Уведомление") }
            }
        }
    }

    private(set) var events: [Event] = []
    private(set) var unread = 0
    private(set) var busy = false
    private(set) var error: String?
    var more: Bool { cursor != nil }
    private var repository: WorkspaceNotificationRepository?
    private var cursor: String?
    private var seenCursors: Set<String> = []
    private var demoLoaded = false

    /// Подготавливает список уведомлений аккаунта или демонстрационную ленту.
    /// - Parameters:
    ///   - client: Авторизованный клиент рабочего пространства.
    ///   - demo: Использовать демонстрационные уведомления.
    func refresh(using client: AuthenticatedClient?, demo: Bool) async {
        if demo {
            guard !demoLoaded else { return }
            demoLoaded = true
            events = [
                Event(id: UUID(), kind: "conference.soon", detail: "Дизайн-синхронизация · начало в 10:00", time: "10 минут назад", recent: true, isRead: false, route: .meetingDetails(1)),
                Event(id: UUID(), kind: "conference.invited", detail: "Анна Кузнецова пригласила вас на дизайн-синхронизацию.", time: "25 минут назад", recent: true, isRead: false, route: .meetingDetails(1)),
                Event(id: UUID(), kind: "recording.ready", detail: "Продукт. Следующая глава — видео и материалы уже доступны.", time: "1 час назад", recent: true, isRead: false, route: .recording(0)),
                Event(id: UUID(), kind: "mention", detail: "Мария Полякова · Команда продукта", time: "Ранее", recent: false, isRead: true, route: .thread(1))
            ]
            unread = events.filter { !$0.isRead }.count
        } else if let client {
            repository = WorkspaceNotificationRepository(client: client)
            await load(more: false)
        }
    }

    /// Загружает первую или следующую страницу уведомлений.
    /// - Parameter append: Добавить уведомления к существующему списку.
    func load(more append: Bool) async {
        guard let repository, !busy, !append || cursor != nil else { return }
        busy = true
        defer { busy = false }
        do {
            try await fetchPage(repository, after: append ? cursor : nil)
            error = nil
        } catch { if !Task.isCancelled { self.error = userMessage(error) } }
    }

    /// Догружает страницы до появления непрочитанного уведомления или конца списка.
    func loadUntilUnread() async {
        while more, unread > 0, !busy, error == nil, !Task.isCancelled, events.allSatisfy(\.isRead) {
            await load(more: true)
        }
    }

    /// Запрашивает одну страницу событий и обновляет курсор и счётчик непрочитанных.
    /// - Parameters:
    ///   - repository: Сервис уведомлений аккаунта.
    ///   - current: Курсор предыдущей страницы или `nil` для первой.
    private func fetchPage(_ repository: WorkspaceNotificationRepository, after current: String?) async throws {
        let page = try await repository.list(cursor: current)
        try Task.checkCancellation()
        if current == nil { seenCursors.removeAll() }
        if let next = page.nextCursor, next.isEmpty || !seenCursors.insert(next).inserted { throw APIError.invalidResponse }
        let incoming = page.items.map { item in
            let route: AppRoute? = item.payload.conversationId.map(AppRoute.conversation)
                ?? (item.payload.recordingId != nil ? .recordings : item.type.hasPrefix("conference.") ? .calendar : nil)
            return Event(id: item.id, kind: item.type, detail: "", time: item.createdAt.formatted(.relative(presentation: .named)),
                         recent: Calendar.current.isDateInToday(item.createdAt), isRead: item.readAt != nil, route: route)
        }
        let existing = current == nil ? [] : Set(events.map(\.id))
        events = (current == nil ? [] : events) + incoming.filter { !existing.contains($0.id) }
        cursor = page.nextCursor
        unread = page.unreadCount
    }

    /// Отмечает одно уведомление прочитанным и сообщает об успехе.
    /// - Parameter event: Уведомление, выбранное пользователем.
    func read(_ event: Event) async -> Bool {
        guard !busy else { return false }
        guard !event.isRead else { return true }
        busy = true
        defer { busy = false }
        do {
            try await markRead(event.id)
            error = nil
            return true
        } catch { if !Task.isCancelled { self.error = userMessage(error) }; return false }
    }

    /// Отмечает все доступные уведомления прочитанными.
    func readAll() async {
        guard !busy, unread > 0 else { return }
        busy = true
        defer { busy = false }
        do {
            // The server exposes an idempotent single-item endpoint. Read pages in
            // creation order and commit each acknowledgement before fetching the next.
            if let repository { try await fetchPage(repository, after: nil) }
            repeat {
                for event in events where !event.isRead {
                    try Task.checkCancellation()
                    try await markRead(event.id)
                }
                guard unread > 0, let repository, let cursor else { break }
                try await fetchPage(repository, after: cursor)
            } while true
            error = nil
        } catch { if !Task.isCancelled { self.error = userMessage(error) } }
    }

    /// Обновляет отметку о прочтении события на сервере и в локальной ленте.
    /// - Parameter id: Идентификатор уведомления.
    private func markRead(_ id: UUID) async throws {
        if let repository { try await repository.markRead(id) }
        else if !demoLoaded { throw ClientError.invalidInput }
        if let index = events.firstIndex(where: { $0.id == id }), !events[index].isRead {
            events[index].isRead = true
            unread = max(0, unread - 1)
        }
    }
}

struct InboxBellAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    /// Выбирает доступную привязку к положению кнопки уведомлений.
    /// - Parameters:
    ///   - value: Накопленная привязка к кнопке.
    ///   - nextValue: Привязка, поступившая от дочернего представления.
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

struct WorkspaceInboxOverlay: View {
    let inbox: WorkspaceInbox
    let app: AppModel
    let anchor: Anchor<CGRect>?
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 600
            let width = min(400, max(0, geometry.size.width - 24))
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let bell = anchor.flatMap { value -> CGRect? in
                let rect = geometry[value]
                return !rect.isEmpty && bounds.intersects(rect) ? rect : nil
            }
            let top = max(0, min((bell?.maxY ?? 60) + 8, geometry.size.height - 240))
            let leading = max(12, min(geometry.size.width - width - 12, (bell?.maxX ?? geometry.size.width - 12) - width))
            let height = min(geometry.size.height - top - 12, compact || typeSize.isAccessibilitySize ? .infinity : 640)

            ZStack(alignment: .topLeading) {
                Color(red: 0.08, green: 0.13, blue: 0.22)
                    .opacity(scheme == .dark ? 0.22 : compact ? 0.16 : 0.10)
                    .ignoresSafeArea().onTapGesture { app.showingWorkspaceNotifications = false }.accessibilityHidden(true)
                WorkspaceInboxView(inbox: inbox, app: app, compact: compact)
                    .frame(width: width).frame(maxHeight: max(0, height))
                    .background(MSTheme.surface, in: RoundedRectangle(cornerRadius: compact ? 18 : 20))
                    .clipShape(RoundedRectangle(cornerRadius: compact ? 18 : 20))
                    .overlay { RoundedRectangle(cornerRadius: compact ? 18 : 20).strokeBorder(MSTheme.line) }
                    .shadow(color: Color.black.opacity(0.12), radius: 20, y: 8)
                    .offset(x: leading, y: top)
            }
        }.accessibilityAction(.escape) { app.showingWorkspaceNotifications = false }
            .accessibilityAddTraits(.isModal)
    }
}

struct WorkspaceInboxView: View {
    let inbox: WorkspaceInbox
    let app: AppModel
    let compact: Bool
    @State private var onlyUnread = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @AccessibilityFocusState private var closeFocused: Bool
    private var visible: [WorkspaceInbox.Event] { inbox.events.filter { !onlyUnread || !$0.isRead } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(tr("Уведомления")).font(MSTheme.font(compact ? 18 : 19, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Text(unreadTitle).font(MSTheme.font(11, weight: .semibold)).padding(.horizontal, 7).frame(minHeight: 23)
                    .foregroundStyle(MSTheme.accent).background(MSTheme.accentSoft, in: Capsule())
                Spacer(minLength: 0)
                IconButton("xmark", label: "Закрыть уведомления") { app.showingWorkspaceNotifications = false }
                    .accessibilityFocused($closeFocused)
            }.padding(.leading, compact ? 16 : 20).padding(.trailing, 10).frame(minHeight: compact ? 65 : 70)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) {
                    fixedFilters
                    Spacer(minLength: 0)
                    readAll.fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 2) {
                    ViewThatFits(in: .horizontal) {
                        fixedFilters
                        VStack(alignment: .leading, spacing: 3) { filter(false); filter(true) }
                    }
                    readAll
                }
            }.padding(.horizontal, compact ? 12 : 16).padding(.bottom, compact ? 11 : 13)
            Rectangle().fill(MSTheme.line).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if let error = inbox.error {
                        Text(tr(error)).font(MSTheme.font(12)).foregroundStyle(MSTheme.danger)
                        Button(tr("Обновить")) { Task { await inbox.load(more: false) } }.frame(minHeight: 44)
                    }
                    if inbox.busy { ProgressView().frame(maxWidth: .infinity).padding(5) }
                    if visible.isEmpty && !inbox.busy && inbox.error == nil && (!onlyUnread || inbox.unread == 0) {
                        emptyState
                    } else {
                        ForEach([true, false], id: \.self) { recent in
                            let group = visible.filter { $0.recent == recent }
                            if !group.isEmpty {
                                Text(tr(recent ? "Недавно" : "Ранее")).font(MSTheme.font(10, weight: .semibold)).foregroundStyle(MSTheme.muted)
                                    .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 7)
                                ForEach(group) { event in eventButton(event) }
                            }
                        }
                    }
                    if inbox.more {
                        Button(tr("Показать ещё")) { Task { await inbox.load(more: true) } }.frame(minHeight: 44).disabled(inbox.busy)
                    }
                }.padding(.horizontal, compact ? 6 : 8).padding(.vertical, 6)
            }.accessibilityLabel(tr("Список уведомлений"))
            Rectangle().fill(MSTheme.line).frame(height: 1)
            Button { navigate(.notificationSettings) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                    Text(tr("Настроить уведомления")).font(MSTheme.font(11, weight: .semibold))
                    Image(systemName: "chevron.right").font(.caption)
                }.frame(maxWidth: .infinity, minHeight: 44).foregroundStyle(MSTheme.muted).contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.vertical, 6).accessibilityIdentifier("workspaceInbox.settings")
        }.foregroundStyle(MSTheme.ink)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("workspaceInbox")
            .task { closeFocused = true; await inbox.refresh(using: app.identity.messaging?.client, demo: app.isDemo) }
    }

    private var unreadTitle: String {
        let n = inbox.unread
        guard n != 0 else { return tr("Всё прочитано") }
        return "\(n) \(tr(n % 10 == 1 && n % 100 != 11 ? "новое" : "новых"))"
    }

    private var fixedFilters: some View {
        HStack(spacing: 3) { filter(false); filter(true) }
            .fixedSize(horizontal: true, vertical: false)
            .padding(3).background(MSTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Создаёт переключатель всех или только непрочитанных уведомлений.
    /// - Parameter unread: Показывать только непрочитанные события.
    private func filter(_ unread: Bool) -> some View {
        Button {
            onlyUnread = unread
            if unread { Task { await inbox.loadUntilUnread() } }
        } label: {
            Text(tr(unread ? "Непрочитанные" : "Все"))
                .font(MSTheme.font(12, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, compact ? 9 : 11).frame(minWidth: 53, minHeight: 44)
                .foregroundStyle(unread == onlyUnread ? MSTheme.accent : MSTheme.muted)
                .background(unread == onlyUnread ? MSTheme.surface : .clear, in: RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(onlyUnread == unread ? .isSelected : [])
            .accessibilityIdentifier(unread ? "workspaceInbox.unread" : "workspaceInbox.all")
    }

    private var readAll: some View {
        Button { Task { await inbox.readAll() } } label: {
            Label(tr("Прочитать все"), systemImage: "checkmark").font(MSTheme.font(11, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true).frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(inbox.unread > 0 ? MSTheme.accent : MSTheme.muted)
            .disabled(inbox.unread == 0 || inbox.busy).accessibilityLabel(tr("Прочитать все уведомления"))
            .accessibilityIdentifier("workspaceInbox.readAll")
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark").font(.system(size: 34)).frame(width: 65, height: 65)
                .foregroundStyle(MSTheme.accent).background(MSTheme.accentSoft, in: RoundedRectangle(cornerRadius: 21))
            Text(tr(onlyUnread ? "Всё прочитано" : "Уведомлений пока нет")).font(MSTheme.font(16, weight: .semibold))
            if onlyUnread { Text(tr("Новых уведомлений пока нет. Все события доступны во вкладке «Все».")).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted) }
        }.multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: 235).padding(.horizontal, 16)
    }

    /// Показывает строку уведомления с переходом к связанному объекту.
    /// - Parameter event: Событие ленты.
    private func eventButton(_ event: WorkspaceInbox.Event) -> some View {
        Button {
            Task {
                guard await inbox.read(event), let route = event.route, app.showingWorkspaceNotifications else { return }
                navigate(route)
            }
        } label: {
            HStack(alignment: .top, spacing: compact ? 9 : 11) {
                Image(systemName: event.label.icon).font(.system(size: 19))
                    .foregroundStyle(event.isRead ? MSTheme.muted : MSTheme.accent)
                    .frame(width: compact ? 34 : 36, height: compact ? 34 : 36)
                    .background(event.isRead ? MSTheme.surfaceSecondary : MSTheme.surface, in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 5) {
                    Text(tr(event.label.title)).font(MSTheme.font(12, weight: .semibold))
                    if !event.detail.isEmpty { Text(tr(event.detail)).lineLimit(typeSize.isAccessibilitySize ? nil : 2).font(MSTheme.font(11)).foregroundStyle(MSTheme.muted) }
                    Text("\(event.time) · \(tr(event.label.category))").font(MSTheme.font(10)).foregroundStyle(MSTheme.muted)
                }
                Spacer(minLength: 0)
                if !event.isRead { Circle().fill(MSTheme.accent).frame(width: 6, height: 6).padding(.top, 6) }
                if event.route != nil { Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(MSTheme.muted).frame(minHeight: 40) }
            }.padding(.horizontal, compact ? 10 : 12).padding(.vertical, compact ? 12 : 13)
                .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading).contentShape(Rectangle())
                .background(event.isRead ? .clear : MSTheme.accentSoft.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain).disabled(inbox.busy).accessibilityValue(tr(event.isRead ? "Прочитано" : "Не прочитано"))
    }

    /// Закрывает ленту уведомлений и открывает связанный экран.
    /// - Parameter route: Маршрут, указанный в уведомлении.
    private func navigate(_ route: AppRoute) {
        app.showingWorkspaceNotifications = false
        app.navigate(route)
    }
}
