import SwiftUI
import MeetSpaceDesignSystem
#if os(iOS)
import ReplayKit
#endif

struct ScreenShareControls: View {
    @Bindable var session: ConferenceSession
    @State private var showingPicker = false
    private var needsStop: Bool { [.preparing, .awaitingSystem, .starting, .active, .paused, .stopping].contains(session.screenShareState) }
    var body: some View {
        VStack(spacing: 8) {
            if let error = session.screenShareError {
                Text(tr(error)).font(MSTheme.font(12)).foregroundStyle(Color(red: 1, green: 0.65, blue: 0.67))
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("screenShareError")
            }
            HStack(spacing: 12) {
                Label(tr(status), systemImage: "rectangle.on.rectangle")
                    .font(MSTheme.font(12)).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("screenShareStatus")
                Spacer(minLength: 0)
                if needsStop {
                    Button(tr("Остановить")) { Task { await session.stopScreenShare() } }
                        .disabled(session.screenShareState == .stopping)
                        .accessibilityIdentifier("screenShareStop").frame(minHeight: 44)
                } else {
                    Button(tr("Показать экран")) {
                        Task {
                            await session.prepareScreenShare()
                            if session.screenShareState == .awaitingSystem { showingPicker = true }
                        }
                    }.disabled(!session.canStartScreenShare)
                        .accessibilityIdentifier("screenShareStart").frame(minHeight: 44)
                }
            }.padding(.horizontal, 12).padding(.vertical, 4)
                .background(Color(red: 0.176, green: 0.271, blue: 0.439), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(red: 0.392, green: 0.498, blue: 0.71), lineWidth: 1))
        }.sheet(isPresented: $showingPicker, onDismiss: {
            if [.preparing, .awaitingSystem].contains(session.screenShareState) { Task { await session.stopScreenShare() } }
        }) {
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
            }.padding(24).presentationDetents([.medium])
        }.onChange(of: session.screenShareState) { _, state in
            if ![.preparing, .awaitingSystem].contains(state) { showingPicker = false }
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
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let view = RPSystemBroadcastPickerView(frame: .zero)
        view.preferredExtension = identifier
        view.showsMicrophoneButton = false
        view.accessibilityLabel = tr("Начать системную трансляцию")
        view.accessibilityIdentifier = "systemBroadcastPicker"
        return view
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        uiView.preferredExtension = identifier; uiView.showsMicrophoneButton = false
    }
}
#endif
