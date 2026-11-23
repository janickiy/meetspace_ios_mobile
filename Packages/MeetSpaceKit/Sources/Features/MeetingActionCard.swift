import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

enum MeetingMembership {
    case joined, left, waiting, rejected, kicked, unknown, none

    init(_ participant: ConferenceParticipant?) {
        guard let participant else { self = .none; return }
        if [participant.status, participant.admissionState].contains("kicked") { self = .kicked }
        else if [participant.status, participant.admissionState].contains("rejected") { self = .rejected }
        else if participant.isWaiting { self = .waiting }
        else if participant.canParticipate { self = .joined }
        else if participant.status == "left" && participant.isAdmitted { self = .left }
        else { self = .unknown }
    }

    var label: String? {
        switch self {
        case .joined: "Вы во встрече"
        case .left: "Членство сохранено; сейчас не во встрече"
        case .waiting: "Ожидает допуска"
        case .rejected: "Допуск отклонён"
        case .kicked: "Исключён из встречи"
        case .unknown: "Состояние не поддерживается приложением"
        case .none: nil
        }
    }
}

struct MeetingActionCard<Value: Identifiable>: View {
    let item: MeetingListItem<Value>
    let scheduled: Date?
    let started: Date?
    var finished: Date?
    let zone: TimeZone
    let waitingRoom: Bool
    let membership: MeetingMembership
    var loadingMembership = false
    var busy = false
    var membershipFailed = false
    var error: String?
    var retry: (() -> Void)?
    let invitation: URL?
    let call: () -> Void
    let toggleMembership: () -> Void
    var folder: (() -> Void)?
    var materials: (() -> Void)?
    let finish: () -> Void
    let close: () -> Void
    @State private var confirmingFinish = false

    private var active: Bool { item.status == .active }
    private var open: Bool { item.status != .past }
    private var membershipReady: Bool { !loadingMembership && !membershipFailed }
    private var canCall: Bool { active && [.none, .joined, .left].contains(membership) }
    private var canShare: Bool { item.mine || membership == .joined || membership == .left }
    private var leave: Bool { membership == .joined || membership == .waiting }
    private var finishTitle: String { active ? "Завершить для всех" : "Отменить встречу" }

    var body: some View {
        WorkspaceFormSheet(title: "О встрече", identifier: "meetingActions", busy: busy, centered: true, close: close) {
            Divider().padding(.horizontal, -21)
            VStack(alignment: .leading, spacing: 6) {
                Text(tr(active ? "Активна" : item.statusTitle)).font(MSTheme.font(11, weight: .semibold))
                    .foregroundStyle(active ? MSTheme.accent : MSTheme.muted)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(active ? MSTheme.accentSoft : MSTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 7))
                Text(verbatim: item.title).font(MSTheme.font(22, weight: .semibold, relativeTo: .title2))
                    .accessibilityAddTraits(.isHeader)
                Text(tr(item.mine ? "Вы — организатор" : "Встреча вашего пространства"))
                    .font(MSTheme.font(13, weight: .semibold)).foregroundStyle(MSTheme.muted)
            }
            VStack(alignment: .leading, spacing: 6) {
                if let scheduled { dateLine("Запланирована", date: scheduled) }
                if let started { dateLine("Началась", date: started) }
                if let finished { dateLine("Завершилась", date: finished) }
                if let duration = item.duration { Text(tr("Плановая длительность") + ": \(duration) " + tr("мин")) }
                if open { Text(tr(waitingRoom ? "Зал ожидания включён." : "Зал ожидания отключён.")) }
            }.font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(MSTheme.background, in: RoundedRectangle(cornerRadius: 12))
            if open && membershipReady, let label = membership.label { Text(tr(label)).font(MSTheme.font(13)) }
            if loadingMembership { ProgressView() }
            if let error {
                Text(tr(error)).foregroundStyle(MSTheme.danger)
                if let retry { Button(tr("Повторить"), action: retry) }
            }
            VStack(spacing: 8) {
                if open && membershipReady {
                    if canCall {
                        command("Подключиться к звонку", "video", "call", primary: true, action: call)
                    }
                    if membership == .none || active && membership == .left {
                        command(active ? "Войти во встречу" : "Зарегистрироваться на встречу",
                                active ? "arrow.right.to.line" : "calendar", "join",
                                primary: !canCall, action: toggleMembership)
                    }
                    if item.mine && !active { command("Начать встречу", "play", "start", primary: true, action: call) }
                    if canShare, let invitation {
                        ShareLink(item: invitation) { actionLabel("Пригласить по ссылке", "link") }
                            .buttonStyle(.plain).accessibilityIdentifier("meetingActions.invite")
                    }
                    if leave { command("Выйти из встречи", "rectangle.portrait.and.arrow.right", "leave", action: toggleMembership) }
                }
                if let folder { command("Добавить в папку", "folder.badge.plus", "folder", action: folder) }
                if item.status == .past || active && membershipReady && canShare, let materials {
                    command("Записи и материалы", "play.circle", "materials", action: materials)
                }
                if open && item.mine && membershipReady {
                    command(finishTitle, active ? "phone.down" : "calendar.badge.minus", "finish", destructive: true) {
                        confirmingFinish = true
                    }
                }
            }
        }.alert(tr(active ? "Завершить встречу для всех участников?" : "Отменить встречу?"),
                             isPresented: $confirmingFinish) {
            Button(tr(finishTitle), role: .destructive, action: finish)
            Button(tr("Оставить встречу"), role: .cancel) {}
        }
    }

    private func dateLine(_ label: String, date: Date) -> some View {
        Text(tr(label) + ": " + calendarText(date, format: "d MMM yyyy, HH:mm xxx", zone: zone))
    }

    private func command(_ title: String, _ icon: String, _ id: String, primary: Bool = false,
                         destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { actionLabel(title, icon, primary: primary, destructive: destructive) }
            .buttonStyle(.plain).accessibilityIdentifier("meetingActions." + id)
    }

    private func actionLabel(_ title: String, _ icon: String, primary: Bool = false, destructive: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).accessibilityHidden(true)
            Text(tr(title)).fixedSize(horizontal: false, vertical: true)
        }.font(MSTheme.font(14, weight: .semibold))
            .foregroundStyle(primary ? Color.white : destructive ? MSTheme.danger : MSTheme.ink)
            .padding(.horizontal, 10).padding(.vertical, 5).frame(maxWidth: .infinity, minHeight: 44)
            .background(primary ? MSTheme.accent : MSTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay { if !primary && !destructive { RoundedRectangle(cornerRadius: 12).strokeBorder(MSTheme.line) } }
            .contentShape(Rectangle())
    }
}
