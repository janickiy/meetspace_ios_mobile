import SwiftUI
import MeetSpaceDesignSystem

/// The account mock has a 44 × 26 track; the entire labelled row is a touch target.
struct AccountSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                configuration.isOn.toggle()
            }
        } label: {
            HStack(spacing: 18) {
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Capsule()
                    .fill(configuration.isOn ? MSTheme.accent : MSTheme.line)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(.white).frame(width: 20, height: 20)
                            .shadow(color: .black.opacity(0.14), radius: 1.5, y: 1)
                            .padding(.horizontal, 3)
                    }
                    .frame(width: 44, height: 26)
                    .opacity(enabled ? 1 : 0.45)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }
}
