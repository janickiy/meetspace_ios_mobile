import SwiftUI
import MeetSpaceDesignSystem
#if os(iOS)
import ReplayKit
#endif

struct ScreenShareControls: View {
    enum Style { case banner, personal }

    @Bindable var session: ConferenceSession
    var compact = true
    var style = Style.banner
    @State private var showingPicker = false
    private var needsStop: Bool { [.preparing, .awaitingSystem, .starting, .active, .paused, .stopping].contains(session.screenShareState) }
    var body: some View {
        Group {
            if style == .personal {
                PersonalCallControl(actionLabel, icon: "display", id: actionID, compact: compact,
                                    active: needsStop, displayLabel: "Экран", action: performAction)
                    .disabled(actionDisabled)
                    .accessibilityValue(Text(tr(status)))
            } else {
                VStack(spacing: 8) {
                    if let error = session.screenShareError {
                        Text(tr(error)).font(MSTheme.font(12)).foregroundStyle(PersonalCallColors.warning)
                            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("screenShareError")
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            statusLabel.fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: 0)
                            actionButton.fixedSize(horizontal: true, vertical: false)
                        }
                        VStack(spacing: 4) {
                            statusLabel
                            actionButton
                        }.frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(Color(red: 0.176, green: 0.271, blue: 0.439), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(red: 0.392, green: 0.498, blue: 0.71)))
                }
            }
        }.sheet(isPresented: $showingPicker, onDismiss: {
            if [.preparing, .awaitingSystem].contains(session.screenShareState) { Task { await session.stopScreenShare() } }
        }) {
            ScrollView {
                VStack(spacing: 24) {
                    Text(tr("Демонстрация экрана")).font(.headline)
                    Text(tr("Будет виден весь экран, включая другие приложения. Системный звук не передаётся."))
                        .multilineTextAlignment(.center)
                    #if os(iOS)
                    if let identifier = session.screenPickerExtensionBundleID {
                        SystemBroadcastPicker(identifier: identifier).frame(width: 64, height: 64)
                    }
                    #endif
                    Text(tr("Нажмите системную кнопку и подтвердите начало трансляции."))
                        .font(.callout).multilineTextAlignment(.center)
                    Button(tr("Отмена")) { Task { await session.stopScreenShare(); showingPicker = false } }
                        .frame(minHeight: 44).accessibilityIdentifier("screenShareCancel")
                }.padding(24).frame(maxWidth: .infinity)
            }.presentationDetents([.medium, .large])
        }.onChange(of: session.screenShareState) { _, state in
            if ![.preparing, .awaitingSystem].contains(state) { showingPicker = false }
        }
    }

    private var actionID: String { needsStop ? "screenShareStop" : "screenShareStart" }
    private var actionLabel: String { needsStop ? "Остановить" : "Показать экран" }
    private var actionDisabled: Bool { needsStop ? session.screenShareState == .stopping : !session.canStartScreenShare }
    private var actionButton: some View {
        Button(tr(actionLabel), action: performAction)
            .font(MSTheme.font(12, weight: .semibold))
            .frame(minHeight: 44).disabled(actionDisabled).accessibilityIdentifier(actionID)
    }
    private var statusLabel: some View {
        Label(tr(status), systemImage: "rectangle.on.rectangle")
            .font(MSTheme.font(12)).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("screenShareStatus")
    }

    /// Запускает подготовку демонстрации экрана или останавливает текущую трансляцию.
    private func performAction() {
        let stop = needsStop
        Task {
            if stop {
                await session.stopScreenShare()
            } else {
                await session.prepareScreenShare()
                if session.screenShareState == .awaitingSystem { showingPicker = true }
            }
        }
    }

    private var status: String {
        switch session.screenShareState {
        case .preparing: "Готовим демонстрацию…"
        case .awaitingSystem: "Ожидаем подтверждения трансляции"
        case .starting: "Подключаем демонстрацию…"
        case .active: "Вы демонстрируете экран"
        case .paused: "Демонстрация приостановлена"
        case .stopping: "Останавливаем демонстрацию…"
        case .idle, .failed: session.screenBlocked || session.cameraBlocked ? "Демонстрация запрещена организатором" : "Демонстрация экрана"
        }
    }
}

#if os(iOS)
private struct SystemBroadcastPicker: UIViewRepresentable {
    let identifier: String
    /// Создаёт системную кнопку ReplayKit для запуска расширения трансляции.
    /// - Parameter context: Контекст представления SwiftUI.
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let view = RPSystemBroadcastPickerView(frame: .zero)
        view.preferredExtension = identifier
        view.showsMicrophoneButton = false
        view.accessibilityLabel = tr("Начать системную трансляцию")
        view.accessibilityIdentifier = "systemBroadcastPicker"
        return view
    }
    /// Синхронизирует выбранное расширение и скрывает системную кнопку микрофона.
    /// - Parameters:
    ///   - uiView: Кнопка запуска трансляции ReplayKit.
    ///   - context: Контекст обновления SwiftUI.
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        uiView.preferredExtension = identifier; uiView.showsMicrophoneButton = false
    }
}
#endif
