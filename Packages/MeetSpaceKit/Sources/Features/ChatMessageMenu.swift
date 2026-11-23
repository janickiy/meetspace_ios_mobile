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
    let attachments: [String]
    let reaction: String?
    let react: ((String) -> Void)?
    let time: String
    let actions: AnyView
}

@MainActor @Observable final class ChatMenuPresentation {
    fileprivate var item: ChatMenuItem?
    var isPresented: Bool { item != nil }
    #if os(iOS)
    var sharing: MessageShareRequest?
    @ObservationIgnored private var afterDismiss: (() -> Void)?
    #endif

    func choose(_ action: @escaping () -> Void) {
        guard item != nil else { return }
        #if os(iOS)
        afterDismiss = action
        item = nil
        #else
        item = nil
        action()
        #endif
    }

    #if os(iOS)
    func finishDismissal() {
        let action = afterDismiss
        afterDismiss = nil
        action?()
    }
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

extension EnvironmentValues {
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
    let attachments: [String]
    let reaction: String?
    let react: ((String) -> Void)?
    let identifier: String
    @ViewBuilder var actions: () -> Actions
    @Environment(\.chatMenu) private var presentation
    @State private var anchor = ChatMenuAnchor()

    func body(content: Content) -> some View {
        if enabled {
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { anchor.bounds = $0 }
                .background {
                    // An independent hit target lets file buttons and links in front handle their own taps.
                    Button(action: open) {
                        Color.clear.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(([author, time, summary] + attachments).filter { !$0.isEmpty }.joined(separator: ", "))
                    .accessibilityHint(tr("Действия с сообщением"))
                    .accessibilityIdentifier("message.actions.\(identifier)")
                }
                .accessibilityAction(named: tr("Действия с сообщением")) { open() }
                #if os(macOS)
                .onDisappear { if presentation?.item?.id == identifier { presentation?.item = nil } }
                #endif
        } else { content }
    }

    private func open() {
        presentation?.item = ChatMenuItem(id: identifier, anchor: anchor.bounds, own: own, author: author, summary: summary,
                                          attachments: attachments, reaction: reaction, react: react,
                                          time: time, actions: AnyView(actions()))
    }
}

/// On iPad the UIKit-backed tab/navigation hierarchy can win hit testing under a SwiftUI overlay.
/// Present the panel in its own native controller, and open any next sheet only after it dismisses.
private struct ChatMessageMenuHost: ViewModifier {
    @State private var presentation = ChatMenuPresentation()
    func body(content: Content) -> some View {
        content
            .blur(radius: presentation.item == nil ? 0 : 3)
            #if os(iOS)
            .fullScreenCover(item: $presentation.item, onDismiss: presentation.finishDismissal) { item in
                ChatMessageMenu(item: item, close: { presentation.item = nil })
                    .presentationBackground(.clear)
                    .interactiveDismissDisabled()
                    .environment(\.chatMenu, presentation)
            }
            .sheet(item: $presentation.sharing) { request in
                MessageActivitySheet(request: request) { presentation.sharing = nil }
                    .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            }
            #else
            .allowsHitTesting(presentation.item == nil)
            .accessibilityHidden(presentation.item != nil)
            .overlay {
                if let item = presentation.item {
                    ChatMessageMenu(item: item, close: { presentation.item = nil }).id(item.id)
                }
            }
            #endif
            .environment(\.chatMenu, presentation)
    }
}

extension View {
    func chatMessageMenuHost() -> some View { modifier(ChatMessageMenuHost()) }
}

struct ChatMenuShareButton: View {
    let text: String
    @Environment(\.chatMenu) private var presentation
    var body: some View {
        let menu = presentation
        ChatMessageCommand("Поделиться", systemImage: "square.and.arrow.up") { menu?.share(text) }
    }
}

private struct ChatMessageMenu: View {
    let item: ChatMenuItem
    let close: () -> Void
    @Environment(\.chatMenu) private var presentation
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
                Group {
                    if contentHeight > bounds.height - 32 {
                        ScrollView { panel }.scrollIndicators(.hidden)
                    } else { panel }
                }
                .frame(width: width, height: height, alignment: .top)
                .padding(.leading, x).padding(.top, y)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityAction(.escape, close)
        .onAppear { focused = true }
    }

    private var panel: some View {
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
            if let react = item.react {
                HStack(spacing: 2) {
                    ForEach(ChatQuickReaction.allCases, id: \.self) { choice in
                        Button { presentation?.choose { react(choice.rawValue) } } label: {
                            Text(choice.rawValue).font(.system(size: 25))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(item.reaction == choice.rawValue ? MSTheme.accentSoft : .clear, in: Capsule())
                        }.buttonStyle(.plain).accessibilityLabel(choice.title)
                            .accessibilityAddTraits(item.reaction == choice.rawValue ? .isSelected : [])
                    }
                }.padding(6).background(MSTheme.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(MSTheme.line))
            }
            let shape = UnevenRoundedRectangle(topLeadingRadius: 17, bottomLeadingRadius: item.own ? 17 : 5,
                                               bottomTrailingRadius: item.own ? 5 : 17, topTrailingRadius: 17)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.author).font(MSTheme.font(11, weight: .semibold)).foregroundStyle(MSTheme.accent)
                if !item.summary.isEmpty { Text(item.summary).font(MSTheme.font(12)).lineSpacing(3).lineLimit(4) }
                if let first = item.attachments.first {
                    HStack(spacing: 6) {
                        WorkspaceIcon("paperclip", size: 15).foregroundStyle(MSTheme.accent)
                        Text(item.attachments.count == 1 ? first : "\(first) · \(tr("ещё")) \(item.attachments.count - 1)")
                            .font(MSTheme.font(11)).foregroundStyle(MSTheme.muted).lineLimit(2)
                    }
                }
                Text(item.time).font(MSTheme.font(10)).foregroundStyle(MSTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }.padding(.horizontal, 15).padding(.top, 13).padding(.bottom, 10).frame(maxWidth: .infinity, alignment: .leading)
                .background(item.own ? MSTheme.accentSoft : MSTheme.surface, in: shape)
                .overlay(shape.strokeBorder(item.own ? MSTheme.accentSoft : MSTheme.line))
                .accessibilityElement(children: .combine)
            VStack(spacing: 0) { item.actions }
                .padding(5).background(MSTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(MSTheme.line))
        }
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("message.actionMenu")
    }
}

private enum ChatQuickReaction: String, CaseIterable {
    case like = "👍", love = "❤️", laugh = "😂", surprise = "😮", sad = "😢", thanks = "🙏"

    var title: String {
        switch self {
        case .like: tr("Нравится")
        case .love: tr("Любовь")
        case .laugh: tr("Смешно")
        case .surprise: tr("Удивление")
        case .sad: tr("Грусть")
        case .thanks: tr("Спасибо")
        }
    }
}

/// Store the actual command, rather than a transient Button configuration from the dismissed cover.
struct ChatMessageCommand: View {
    let title: String
    let symbol: String
    let role: ButtonRole?
    let action: () -> Void
    @Environment(\.chatMenu) private var presentation
    init(_ title: String, systemImage: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title; symbol = systemImage; self.role = role; self.action = action
    }
    var body: some View {
        Button(role: role) { presentation?.choose(action) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 17)).frame(width: 20).accessibilityHidden(true)
                Text(tr(title)).font(MSTheme.font(13))
            }
            .foregroundStyle(role == .destructive ? MSTheme.danger : MSTheme.ink)
            .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(MSTheme.line.opacity(0.7)).frame(height: 0.5) }
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
