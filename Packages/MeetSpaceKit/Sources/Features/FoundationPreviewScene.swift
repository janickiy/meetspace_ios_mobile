#if os(macOS)
import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

/// Host-only rendering aid. Does not represent UIKit, safe areas, or simulator validation.
public struct FoundationPreviewScene: View {
    private let screen: String
    private let model: AppModel
    public init(screen: String, state: LoadState = .content) {
        self.screen = screen
        self.model = AppModel()
        self.model.contentState = state
    }
    public var body: some View {
        Group {
            switch screen {
            case "meetings": MeetingsView(model: model)
            case "messages": MessagesView(model: model)
            case "profile": ProfileView(model: model)
            default: OnboardingView(model: model)
            }
        }.font(MSTheme.font()).foregroundStyle(MSTheme.ink).tint(MSTheme.accent).buttonStyle(MSTextButtonStyle()).background(MSTheme.background)
    }
}
#endif
