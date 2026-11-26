import SwiftUI

private struct ConferencePresentation: ViewModifier {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var presented: ConferenceSession?
    @State private var presentationTask: Task<Void, Never>?
    /// Следит за активной сессией модели и открывает или закрывает экран конференции.
    /// - Parameter content: Экран, из которого открывают конференцию.
    func body(content: Content) -> some View {
        presentation(content)
            .onChange(of: model.activeConference?.id, initial: true) { _, id in
                presentationTask?.cancel()
                guard let id else { presented = nil; return }
                // Allow the create/invite form to dismiss before presenting the room.
                presentationTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled, model.activeConference?.id == id else { return }
                    presented = model.activeConference
                }
            }
    }
    /// Представляет комнату конференции в окне, подходящем для текущей платформы.
    /// - Parameter content: Представление под окном конференции.
    @ViewBuilder private func presentation(_ content: Content) -> some View {
        #if os(iOS)
        content.fullScreenCover(item: $presented) { session in
            LiveConferenceView(app: model, session: session, recordings: model.identity.recordings, workspaceTheme: colorScheme) { await model.dismissConference() }
        }
        #else
        content.sheet(item: $presented) { session in
            LiveConferenceView(app: model, session: session, recordings: model.identity.recordings, workspaceTheme: colorScheme) { await model.dismissConference() }
                .frame(minWidth: 700, minHeight: 650)
        }
        #endif
    }
}
extension View {
    /// Подключает показ активной конференции к представлению.
    /// - Parameter model: Модель приложения с текущей конференцией.
    func conferencePresentation(model: AppModel) -> some View { modifier(ConferencePresentation(model: model)) }
}
