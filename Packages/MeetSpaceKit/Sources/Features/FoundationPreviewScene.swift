#if os(macOS)
import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

/// Host-only rendering aid. Does not represent UIKit, safe areas, or simulator validation.
public struct FoundationPreviewScene: View {
    private let screen: String
    private let model: AppModel
    /// Подготавливает демонстрационную сцену для предварительного просмотра на macOS.
    /// - Parameters:
    ///   - screen: Имя демонстрационного экрана.
    ///   - state: Состояние загрузки, которое нужно отобразить.
    public init(screen: String, state: LoadState = .content) {
        self.screen = screen
        self.model = AppModel()
        self.model.enterDemo()
        self.model.tab = screen == "messages" || screen == "thread" ? .messages : screen == "profile" ? .profile : .meetings
        self.model.contentState = state
    }
    public var body: some View {
        GeometryReader { geometry in
            if ["meetings", "messages", "thread", "profile"].contains(screen) {
                let wide = geometry.size.width >= 780
                let showsTabBar = screen != "thread" || wide
                VStack(spacing: 0) {
                    Group {
                        switch screen {
                        case "meetings": MeetingsView(model: model)
                        case "messages": MessagesView(model: model)
                        case "thread": ThreadView(model: model, personIndex: 0)
                        default: ProfileView(model: model)
                        }
                    }.frame(maxHeight: .infinity)
                    if showsTabBar { WorkspaceTabBar(model: model, wide: wide) }
                }
                .chatMessageMenuHost()
                .environment(\.workspaceWidth, geometry.size.width)
                .environment(\.workspaceUnreadNotifications, 3)
                // Reserve the prototype's system insets in this borderless macOS host only.
                .padding(.top, wide ? 28 : 32).padding(.bottom, wide ? 16 : (showsTabBar ? 22 : 0))
                .background(MSTheme.surface)
            } else { OnboardingView(model: model) }
        }.font(MSTheme.font()).foregroundStyle(MSTheme.ink).tint(MSTheme.accent).buttonStyle(MSTextButtonStyle()).background(MSTheme.background)
    }
}
#endif
