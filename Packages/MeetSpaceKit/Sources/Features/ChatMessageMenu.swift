import SwiftUI
import MeetSpaceDesignSystem
#if os(macOS)
import AppKit
#endif

private struct ChatMenuItem: Identifiable {
    let id: String
    let anchor: CGRect
    let own: Bool
    let author: String
    let summary: String
    let time: String
    let actions: AnyView
}

@MainActor @Observable private final class ChatMenuPresentation {
    var item: ChatMenuItem?
    #if os(iOS)
    var sharing: MessageShareRequest?
    #endif

    func share(_ text: String) {
        #if os(iOS)
        sharing = MessageShareRequest(payload: .text(text))
        #elseif os(macOS)
        if let view = NSApp.keyWindow?.contentView {
            NSSharingServicePicker(items: [text]).show(relativeTo: CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1),
                                                       of: view, preferredEdge: .minY)
        }
        #endif
    }
}

private struct ChatMenuEnvironmentKey: EnvironmentKey {
    static let defaultValue: ChatMenuPresentation? = nil
}

private extension EnvironmentValues {
    var chatMenu: ChatMenuPresentation? {
        get { self[ChatMenuEnvironmentKey.self] }
        set { self[ChatMenuEnvironmentKey.self] = newValue }
    }
}

/// Geometry changes while scrolling should only update the anchor, never invalidate the message row.
private final class ChatMenuAnchor {
    var bounds = CGRect.zero
}

struct MessageMenuTrigger<Actions: View>: ViewModifier {
    let enabled: Bool
    let own: Bool
    let author: String
    let time: String
    let summary: String
    let identifier: String
    let wide: Bool
    @ViewBuilder var actions: () -> Actions
    @Environment(\.chatMenu) private var presentation
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var reveal = false
    @State private var anchor = ChatMenuAnchor()

    func body(content: Content) -> some View {
        if enabled {
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { anchor.bounds = $0 }
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in open() })
                .simultaneousGesture(TapGesture().onEnded { reveal.toggle() })
                .onHover { reveal = $0 }
                .accessibilityAction(named: tr("Действия с сообщением")) { open() }
                .overlay(alignment: wide && own ? .topLeading : .topTrailing) {
                    if reveal || voiceOver {
                        Button(action: open) {
                            Image(systemName: "ellipsis").font(.system(size: 15)).frame(width: 32, height: 32)
                                .background(MSTheme.surface, in: Circle()).frame(width: 44, height: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain).foregroundStyle(MSTheme.muted).accessibilityLabel(tr("Действия с сообщением"))
                            .accessibilityIdentifier("message.actions.\(identifier)")
                    }
                }
                .onDisappear { if presentation?.item?.id == identifier { presentation?.item = nil } }
        } else { content }
    }

    private func open() {
        presentation?.item = ChatMenuItem(id: identifier, anchor: anchor.bounds, own: own, author: author, summary: summary,
                                          time: time, actions: AnyView(actions()))
    }
}

/// Screen-level overlay avoids a nested system presentation when a command opens the forward picker or share sheet.
private struct ChatMessageMenuHost: ViewModifier {
    @State private var presentation = ChatMenuPresentation()
    func body(content: Content) -> some View {
        content
            .blur(radius: presentation.item == nil ? 0 : 3)
            .allowsHitTesting(presentation.item == nil)
            .accessibilityHidden(presentation.item != nil)
            .overlay {
                if let item = presentation.item {
                    ChatMessageMenu(item: item, close: { presentation.item = nil }).id(item.id)
                }
            }
            .environment(\.chatMenu, presentation)
            #if os(iOS)
            .sheet(item: $presentation.sharing) { request in
                MessageActivitySheet(request: request) { presentation.sharing = nil }
                    .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            }
            #endif
    }
}

extension View {
    func chatMessageMenuHost() -> some View { modifier(ChatMessageMenuHost()) }
}

struct ChatMenuShareButton: View {
    let text: String
    @Environment(\.chatMenu) private var presentation
    var body: some View {
        Button(tr("Поделиться"), systemImage: "square.and.arrow.up") { presentation?.share(text) }
    }
}

private struct ChatMessageMenu: View {
    let item: ChatMenuItem
    let close: () -> Void
    @State private var contentHeight: CGFloat = 360
    @AccessibilityFocusState private var focused: Bool
    var body: some View {
        GeometryReader { proxy in
            let bounds = proxy.frame(in: .global)
            let width = min(320, max(1, bounds.width - 32))
            let height = min(contentHeight, max(1, bounds.height - 32))
            let anchorX = item.own ? item.anchor.maxX - width : item.anchor.minX
            let x = max(16, min(anchorX - bounds.minX, bounds.width - width - 16))
            let y = max(16, min(item.anchor.minY - bounds.minY - 68, bounds.height - height - 16))
            ZStack(alignment: .topLeading) {
                Color(red: 0.075, green: 0.125, blue: 0.224).opacity(0.48)
                    .ignoresSafeArea().onTapGesture(perform: close).accessibilityHidden(true)
                ScrollView {
                    VStack(spacing: 9) {
                        HStack {
                            Text(tr("Действия с сообщением")).font(MSTheme.font(12, weight: .semibold))
                                .accessibilityAddTraits(.isHeader).accessibilityFocused($focused)
                            Spacer()
                            Button(action: close) {
                                Image(systemName: "xmark").font(.system(size: 14)).frame(width: 32, height: 32)
                                    .background(.white.opacity(0.12), in: Circle()).frame(width: 44, height: 44)
                            }.buttonStyle(.plain).accessibilityLabel(tr("Закрыть действия с сообщением"))
                        }.foregroundStyle(.white).padding(.leading, 12)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.author).font(MSTheme.font(12, weight: .semibold)).foregroundStyle(MSTheme.accent)
                            Text(item.summary).font(MSTheme.font(13)).lineLimit(4)
                            Text(item.time).font(MSTheme.font(10)).foregroundStyle(MSTheme.muted)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(item.own ? MSTheme.accentSoft : MSTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                            .accessibilityElement(children: .combine)
                        VStack(spacing: 0) { item.actions }
                            .buttonStyle(ChatMenuCommandStyle(close: close))
                            .padding(5).background(MSTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(MSTheme.line))
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }.scrollIndicators(.hidden).scrollBounceBehavior(.basedOnSize)
                    .frame(width: width, height: height).offset(x: x, y: y)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityAddTraits(.isModal).accessibilityAction(.escape, close)
        .accessibilityIdentifier("message.actionMenu")
        .onAppear { focused = true }
    }
}

/// Commands can open other sheets. Remove this overlay before triggering the original action.
private struct ChatMenuCommandStyle: PrimitiveButtonStyle {
    let close: () -> Void
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role) {
            close()
            configuration.trigger()
        } label: {
            configuration.label.labelStyle(ChatMenuLabelStyle())
                .font(MSTheme.font(13)).foregroundStyle(configuration.role == .destructive ? MSTheme.danger : MSTheme.ink)
                .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .overlay(alignment: .bottom) { Rectangle().fill(MSTheme.line.opacity(0.7)).frame(height: 0.5) }
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

private struct ChatMenuLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.icon.font(.system(size: 17)).frame(width: 20)
            configuration.title
        }
    }
}
