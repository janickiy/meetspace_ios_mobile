import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

extension RecordingMode {
    fileprivate var dialogTitle: String { self == .composite ? "Общая запись" : title }
    fileprivate var dialogHint: String {
        switch self {
        case .composite: "Видео участников, звук и демонстрация экрана"
        case .audioOnly: "Разговор без видеодорожки"
        case .individualTracks: "Дорожки участников и общий микс"
        case .screenFocus: "Демонстрация экрана со звуком"
        }
    }
    fileprivate var dialogIcon: String {
        switch self {
        case .composite: "video"
        case .audioOnly: "waveform"
        case .individualTracks: "person.2"
        case .screenFocus: "display"
        }
    }
}

enum ConferenceRecordingDialogState {
    case loading
    case unavailable(String)
    case failure(String)
    case options([RecordingMode], status: String)
    case active(id: UUID, title: String, detail: String, canStop: Bool)

    var statusTitle: String {
        switch self {
        case .options(_, let status), .active(_, let status, _, _): status
        default: "Запись"
        }
    }

    /// Готовит состояние диалога записи и пояснение для текущего этапа обработки.
    /// - Parameters:
    ///   - id: Идентификатор записи.
    ///   - status: Серверный код состояния.
    ///   - title: Название состояния для пользователя.
    ///   - mode: Формат записи, если известен.
    ///   - canStop: Доступна ли остановка записи.
    static func active(id: UUID, status: String, title: String, mode: RecordingMode?, canStop: Bool) -> Self {
        let detail: String
        switch status {
        case "starting": detail = tr("Подготавливаем запись. Это займёт несколько секунд.")
        case "stopping": detail = tr("Завершаем запись встречи.")
        case "finalizing", "processing", "uploading": detail = tr("Готовим файлы. После обработки они появятся в записях встречи.")
        default: detail = mode.map { tr("Записывается") + ": " + tr($0.dialogTitle) } ?? tr(title)
        }
        return .active(id: id, title: title, detail: detail, canStop: canStop)
    }
}

/// The same dialog is used with local demo state and authorized server actions.
struct ConferenceRecordingDialog: View {
    let meetingTitle: String
    let state: ConferenceRecordingDialogState
    @Binding var mode: RecordingMode
    var busy = false
    var demo = false
    var openRecording: (() -> Void)?
    let close: () -> Void
    let start: (RecordingMode) -> Void
    let stop: (UUID) -> Void
    var retry: (() -> Void)?
    @State private var pendingStop: UUID?
    @Environment(\.dynamicTypeSize) private var typeSize
    @AccessibilityFocusState private var headingFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            let cardWidth = min(440, max(0, geometry.size.width - 28))
            let stacked = cardWidth < 335 || typeSize > .large
            let shape = RoundedRectangle(cornerRadius: 24)
            ZStack {
                Color(red: 0.06, green: 0.10, blue: 0.24).opacity(0.46)
                    .ignoresSafeArea().onTapGesture(perform: close).accessibilityHidden(true)
                ViewThatFits(in: .vertical) {
                    contents(stacked: stacked, width: cardWidth).fixedSize(horizontal: false, vertical: true)
                    ScrollView { contents(stacked: stacked, width: cardWidth) }
                        .scrollBounceBehavior(.basedOnSize)
                }.frame(width: cardWidth)
                    .background(MSTheme.surface, in: shape).clipShape(shape)
                    .overlay(shape.strokeBorder(MSTheme.line))
                    .shadow(color: .black.opacity(0.16), radius: 24, y: 10)
                    .padding(.vertical, 10)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.foregroundStyle(MSTheme.ink)
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape, close)
            .onAppear { headingFocused = true }
    }

    /// Показывает состояние записи встречи, выбор формата и доступные действия.
    /// - Parameters:
    ///   - stacked: Разместить ли варианты форматов в один столбец.
    ///   - width: Доступная ширина диалога в пунктах.
    private func contents(stacked: Bool, width: CGFloat) -> some View {
        let compact = width < 406
        return VStack(alignment: .leading, spacing: compact ? 14 : 18) {
            HStack(spacing: 8) {
                Text(tr("Запись встречи")).font(MSTheme.font(21, weight: .semibold, relativeTo: .title2))
                    .accessibilityAddTraits(.isHeader).accessibilityFocused($headingFocused)
                Spacer(minLength: 0)
                Button(action: close) {
                    WorkspaceIcon("xmark", size: 19).frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(tr("Закрыть"))
                    .accessibilityIdentifier("conferenceRecordingClose")
            }
            HStack(spacing: 12) {
                WorkspaceIcon("video", size: 20)
                    .foregroundStyle(MSTheme.accent).frame(width: 46, height: 46)
                    .background(MSTheme.accentSoft, in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr(state.statusTitle)).font(MSTheme.font(15, weight: .semibold))
                        .accessibilityIdentifier("conferenceRecordingStatus")
                    Text(verbatim: meetingTitle).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
                }
            }
            switch state {
            case .loading:
                ProgressView(tr("Загрузка…")).font(MSTheme.font(13))
            case .unavailable(let message):
                Text(tr(message)).font(MSTheme.font(13)).foregroundStyle(MSTheme.muted)
            case .failure(let message):
                Text(tr(message)).font(MSTheme.font(13)).foregroundStyle(MSTheme.danger)
                if let retry { Button(tr("Повторить"), action: retry).buttonStyle(MSButtonStyle(primary: false)).disabled(busy) }
            case .options(let modes, _):
                if let openRecording {
                    Button(action: openRecording) { Label(tr("Открыть запись"), systemImage: "play.circle") }
                        .buttonStyle(MSButtonStyle(primary: false)).accessibilityIdentifier("conferenceRecordingOpen")
                }
                if let selection = modes.contains(mode) ? mode : modes.first {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(tr("Формат записи")).font(MSTheme.font(13, weight: .semibold))
                        formatGrid(modes, selection: selection, stacked: stacked, compact: compact)
                    }
                    actionButton("Начать запись", icon: "circle", id: "startServerRecording") { start(selection) }
                        .disabled(busy)
                }
            case .active(let id, _, let detail, let canStop):
                if canStop && pendingStop == id {
                    Text(tr("Остановить запись?")).font(MSTheme.font(16, weight: .semibold))
                    Text(tr("Текущая запись завершится. Встреча продолжится, а файлы будут доступны после обработки."))
                        .font(MSTheme.font(13)).foregroundStyle(MSTheme.muted)
                    actionButton("Остановить запись", icon: "stop", id: "conferenceRecordingConfirmStop", destructive: true) {
                        pendingStop = nil
                        stop(id)
                    }.disabled(busy)
                    Button(tr("Продолжить запись")) { pendingStop = nil }
                        .buttonStyle(MSButtonStyle(primary: false)).accessibilityIdentifier("conferenceRecordingCancelStop")
                } else {
                    HStack(spacing: 9) {
                        WorkspaceIcon(canStop ? "record.circle" : "info.circle", size: 18)
                        Text(verbatim: detail).font(MSTheme.font(13))
                    }.foregroundStyle(MSTheme.accent).padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(MSTheme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
                    if canStop {
                        actionButton("Остановить запись", icon: "stop", id: "conferenceRecordingStop", destructive: true) {
                            pendingStop = id
                        }.disabled(busy)
                    }
                }
            }
            Text(tr(demo ? "Записи хранятся 7 дней. Остановить запись может её инициатор или организатор встречи."
                         : "Срок хранения определяет сервер. Остановить запись может её инициатор или организатор встречи."))
                .font(MSTheme.font(13)).foregroundStyle(MSTheme.muted).lineSpacing(3)
            if demo {
                Text(tr("Демонстрация интерфейса · камера и микрофон не записываются."))
                    .font(MSTheme.font(12)).foregroundStyle(MSTheme.muted).lineSpacing(2)
            }
        }.fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, compact ? 18 : 24).padding(.top, compact ? 12 : 16).padding(.bottom, compact ? 20 : 24)
    }

    /// Размещает поддерживаемые форматы записи в сетке и выделяет выбранный.
    /// - Parameters:
    ///   - modes: Доступные форматы в порядке отображения.
    ///   - selection: Текущий формат.
    ///   - stacked: Разместить ли форматы в один столбец.
    ///   - compact: Использовать ли компактные размеры и отступы.
    private func formatGrid(_ modes: [RecordingMode], selection: RecordingMode, stacked: Bool, compact: Bool) -> some View {
        let count = stacked ? 1 : 2
        return Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(Array(stride(from: 0, to: modes.count, by: count)), id: \.self) { start in
                GridRow {
                    ForEach(modes[start..<min(start + count, modes.count)]) { format in
                        formatButton(format, selected: format == selection, compact: compact && !stacked)
                    }
                    if count == 2 && start + 1 == modes.count {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]).accessibilityHidden(true)
                    }
                }
            }
        }
    }

    /// Предлагает выбрать формат записи и показывает текущее выделение.
    /// - Parameters:
    ///   - format: Формат, который выбирает кнопка.
    ///   - selected: Выбран ли этот формат.
    ///   - compact: Использовать ли компактные размеры и отступы.
    private func formatButton(_ format: RecordingMode, selected: Bool, compact: Bool) -> some View {
        Button { mode = format } label: {
            HStack(spacing: compact ? 5 : 9) {
                ZStack {
                    Circle().strokeBorder(selected ? MSTheme.brandAccent : MSTheme.muted)
                    if selected { Circle().fill(MSTheme.brandAccent).padding(4) }
                }.frame(width: compact ? 14 : 17, height: compact ? 14 : 17).accessibilityHidden(true)
                WorkspaceIcon(format.dialogIcon, size: compact ? 15 : 19).foregroundStyle(MSTheme.brandAccent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr(format.dialogTitle)).font(MSTheme.font(13, weight: .semibold))
                    Text(tr(format.dialogHint)).font(MSTheme.font(11)).foregroundStyle(MSTheme.muted).lineSpacing(2)
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }.multilineTextAlignment(.leading).padding(.horizontal, compact ? 7 : 10).padding(.vertical, 12)
                .frame(maxWidth: .infinity, minHeight: 66, maxHeight: .infinity, alignment: .leading)
                .background(selected ? MSTheme.accentSoft : MSTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? MSTheme.brandAccent : MSTheme.line))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(tr(format.dialogTitle)).accessibilityHint(tr(format.dialogHint))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("conferenceRecordingMode.\(format.rawValue)")
    }

    /// Создаёт кнопку действия с записью и применяет стиль для опасной операции.
    /// - Parameters:
    ///   - title: Подпись кнопки.
    ///   - icon: Имя значка действия.
    ///   - id: Идентификатор элемента для тестов интерфейса и средств доступности.
    ///   - destructive: Требуется ли предупреждающее оформление.
    ///   - action: Обработчик нажатия кнопки.
    private func actionButton(_ title: String, icon: String, id: String, destructive: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                WorkspaceIcon(icon, size: 19)
                Text(tr(title)).font(MSTheme.font(14, weight: .semibold))
            }.frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(destructive ? MSTheme.danger : MSTheme.surface)
                .background(destructive ? MSTheme.surface : MSTheme.brandAccent, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(destructive ? MSTheme.danger : .clear))
        }.buttonStyle(.plain).accessibilityIdentifier(id)
    }
}

struct ConferenceRecordingSheet: View {
    let session: ConferenceSession
    let model: RecordingsModel
    let close: () -> Void
    @State private var conference: Conference?
    @State private var error: String?
    @State private var mode: RecordingMode = .composite

    private var records: [MeetingRecording]? { model.conferenceItems[session.conferenceID] }
    private var state: ConferenceRecordingDialogState {
        guard session.phase == .connected else { return .unavailable("Запись недоступна для текущего состояния встречи.") }
        if let error = error ?? model.error { return .failure(error) }
        guard let conference, let records else { return .loading }
        if let active = records.first(where: \.active) {
            return .active(id: active.id, status: active.status, title: active.statusTitle, mode: RecordingMode(rawValue: active.mode),
                           canStop: RecordingPermissions.canStop(active, conference: conference, participant: session.participant,
                                                                 accountID: model.account.user.id))
        }
        guard RecordingPermissions.canStart(conference: conference, participant: session.participant, accountID: model.account.user.id)
        else { return .unavailable("Запись недоступна для текущего состояния встречи.") }
        guard !model.modes.isEmpty else { return .unavailable("Сервер не поддерживает запуск записи.") }
        let latest = records.max { $0.createdAt < $1.createdAt }
        return .options(model.modes, status: latest?.statusTitle ?? "Запись")
    }

    var body: some View {
        ConferenceRecordingDialog(meetingTitle: session.title, state: state, mode: $mode, busy: model.controlling, close: close) { choice in
            Task {
                guard session.phase == .connected, let conference else { return }
                await model.start(conference: conference, participant: session.participant, mode: choice)
            }
        } stop: { id in
            Task {
                guard session.phase == .connected, let conference, let recording = records?.first(where: { $0.id == id }) else { return }
                await model.stop(recording, conference: conference, participant: session.participant)
            }
        } retry: {
            Task { await load(); await model.loadConference(session.conferenceID) }
        }
        .task(id: session.phase) { await load() }
    }

    /// Загружает сведения о подключённой встрече для диалога управления записью.
    private func load() async {
        conference = nil
        error = nil
        guard session.phase == .connected else { return }
        do {
            let result = try await session.repository.read(session.conferenceID)
            guard !Task.isCancelled, session.phase == .connected else { return }
            conference = result
        } catch { if !Task.isCancelled { self.error = userMessage(error) } }
    }
}
