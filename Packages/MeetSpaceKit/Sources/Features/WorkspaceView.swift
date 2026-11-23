import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem
#if os(iOS)
import UIKit
#endif

struct WorkspaceView: View {
    @Bindable var model: AppModel
    @State private var inbox = WorkspaceInbox()
    @State private var inlineThreadVisible = false
    @State private var hasHinge = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        GeometryReader { geometry in
            let wide = WorkspaceLayout.usesColumns(width: geometry.size.width, sizeClass: sizeClass, typeSize: typeSize)
            VStack(spacing: 0) {
                tabs
                if !showingCall && (wide || !showingThread) {
                    WorkspaceTabBar(model: model, wide: wide)
                }
            }
            .chatMessageMenuHost()
            .accessibilityHidden(model.showingWorkspaceNotifications)
            .overlayPreferenceValue(InboxBellAnchor.self) { anchor in
                if model.showingWorkspaceNotifications {
                    WorkspaceInboxOverlay(inbox: inbox, app: model, anchor: anchor)
                }
            }
            .environment(\.workspaceWidth, geometry.size.width)
            .environment(\.workspaceUnreadNotifications, inbox.unread)
            .onPreferenceChange(InlineChatVisible.self) { inlineThreadVisible = $0 }
        }
        .background(MSTheme.background)
        .observeWorkspaceHinge($hasHinge)
        .task(id: model.identity.settings?.account.id) { await model.identity.settings?.loadPhoto() }
        .task { await inbox.refresh(using: model.identity.messaging?.client, demo: model.isDemo) }
    }

    private var activeRoute: AppRoute? {
        switch model.tab {
        case .meetings: model.meetingsPath.last
        case .messages: model.messagesPath.last
        case .profile: model.profilePath.last
        }
    }

    private var showingCall: Bool { activeRoute == .call || activeRoute == .personalCall }

    private var showingThread: Bool {
        if model.tab == .messages && model.messagesPath.isEmpty && inlineThreadVisible { return true }
        switch activeRoute {
        case .thread, .conversation: return true
        default: return false
        }
    }

    private var tabs: some View {
        TabView(selection: $model.tab) {
            stack(tab: .meetings, path: $model.meetingsPath) {
                if model.isDemo { MeetingsView(model: model) }
                else if let meetings = model.identity.conferences {
                    LiveMeetingsView(model: meetings, calendar: model.identity.calendar, recordings: model.identity.recordings,
                        folders: model.identity.folders, openRecording: { model.navigate(.liveRecording($0)) },
                        openCalendar: { model.navigate(.calendar) },
                        openRecordings: { model.navigate(.recordings) }, openFolders: { model.navigate(.folders) },
                        openNotifications: { model.presentWorkspaceNotifications() })
                }
            }
            stack(tab: .messages, path: $model.messagesPath) {
                if let messaging = model.identity.messaging, !model.isDemo { LiveMessagesView(app: model, model: messaging, hasHinge: hasHinge) }
                else { MessagesView(model: model, hasHinge: hasHinge) }
            }
            stack(tab: .profile, path: $model.profilePath) {
                if model.isDemo { ProfileView(model: model) }
                else { LiveProfileView(app: model) }
            }
        }
    }

    private func stack<Content: View>(tab: AppTab, path: Binding<[AppRoute]>, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack(path: path) {
            content().msHideRootBar().navigationDestination(for: AppRoute.self) { route in DestinationView(model: model, route: route) }
        }.tag(tab).msHideSystemTabBar()
    }
}

private extension View {
    @ViewBuilder func observeWorkspaceHinge(_ hasHinge: Binding<Bool>) -> some View {
        #if os(iOS) && compiler(>=6.4.1)
        if #available(iOS 27.1, *) {
            onHingeChange { _, context in hasHinge.wrappedValue = context.hinge != nil }
        } else { self }
        #else
        self
        #endif
    }
}

enum WorkspaceLayout {
    static func usesColumns(width: CGFloat, sizeClass: UserInterfaceSizeClass?, typeSize: DynamicTypeSize) -> Bool {
        !typeSize.isAccessibilitySize && (width >= 780 || (sizeClass == .regular && width >= 620))
    }

    static func chatSidebarWidth(_ width: CGFloat) -> CGFloat { min(340, width * 0.38) }
    static func chatGutter(_ width: CGFloat) -> CGFloat { width >= 780 ? 24 : 10 }
}

struct InlineChatVisible: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

struct WorkspaceTabBar: View {
    let model: AppModel
    let wide: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 0) {
            tabButton(.meetings, title: "Встречи", icon: "video", wide: wide)
            tabButton(.messages, title: "Чаты", icon: "bubble.left.and.bubble.right", wide: wide)
            tabButton(.profile, title: "Профиль", icon: "person.crop.circle", wide: wide)
        }
        .padding(.horizontal, 12).padding(.top, wide ? 10 : 7)
        .frame(maxWidth: .infinity)
        .background(MSTheme.surface, ignoresSafeAreaEdges: .bottom)
        .overlay(alignment: .top) { Rectangle().fill(MSTheme.line).frame(height: 1) }
    }

    private func tabButton(_ tab: AppTab, title: String, icon: String, wide: Bool) -> some View {
        let selected = model.tab == tab
        let layout = typeSize.isAccessibilitySize ? AnyLayout(HStackLayout(spacing: 4)) : AnyLayout(VStackLayout(spacing: 5))
        return Button { model.tab = tab } label: {
            layout {
                if tab == .profile {
                    let name = model.isDemo ? model.demoProfile.name : model.identity.settings?.profile.name ?? model.identity.messaging?.account.user.name ?? ""
                    ProfileAvatar(name: name, size: 29, photo: model.isDemo ? model.demoProfile.photo : model.identity.settings?.photo)
                        .overlay { if selected { Circle().strokeBorder(MSTheme.accent, lineWidth: 2) } }
                        .overlay(alignment: .bottomTrailing) {
                            if model.isDemo || model.identity.messaging?.realtimeState == .connected {
                                tabDot(MSTheme.success)
                            }
                        }
                } else {
                    WorkspaceIcon(icon, size: 27)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 9).fill(MSTheme.accentSoft).padding(-5)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            if tab == .messages && (model.isDemo || (model.identity.messaging?.unreadCount ?? 0) > 0) {
                                tabDot(MSTheme.brandAccent).offset(x: 3, y: -1)
                            }
                        }
                }
                Text(tr(title)).font(MSTheme.font(11, weight: selected ? .semibold : .regular, relativeTo: .caption))
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, minHeight: 54).contentShape(Rectangle())
                .foregroundStyle(selected ? MSTheme.accent : MSTheme.muted)
        }.buttonStyle(.plain).frame(maxWidth: wide ? 200 : 170)
            .accessibilityIdentifier("tab.\(tab.rawValue)").accessibilityLabel(tr(title))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func tabDot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 9, height: 9)
            .overlay { Circle().strokeBorder(MSTheme.surface, lineWidth: 1.5) }.accessibilityHidden(true)
    }
}

extension View {
    @ViewBuilder func msHideRootBar() -> some View {
        #if os(iOS)
        self.toolbar(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }

    @ViewBuilder fileprivate func msHideSystemTabBar() -> some View {
        #if os(iOS)
        self.toolbar(.hidden, for: .tabBar)
        #else
        self
        #endif
    }
}

struct StateContent<Content: View>: View {
    let state: LoadState
    let retry: () -> Void
    @ViewBuilder let content: () -> Content
    var body: some View {
        switch state {
        case .content: content()
        case .loading:
            VStack(spacing: 16) { ProgressView(); Text(tr("Загружаем пространство…")) }
                .frame(maxWidth: .infinity, minHeight: 250).accessibilityIdentifier("state.loading")
        case .empty: status("tray", "Здесь пока пусто", "Новые встречи и сообщения появятся здесь.", retry: false)
        case .offline: status("wifi.slash", "Нет подключения", "Проверьте сеть и повторите попытку.", retry: true)
        case .failed: status("exclamationmark.circle", "Не удалось загрузить", "Попробуйте ещё раз.", retry: true)
        }
    }
    private func status(_ icon: String, _ title: String, _ detail: String, retry showRetry: Bool) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 34)).foregroundStyle(MSTheme.accent).accessibilityHidden(true)
            Text(tr(title)).font(MSTheme.font(20, weight: .semibold, relativeTo: .title2))
            Text(tr(detail)).foregroundStyle(MSTheme.muted).multilineTextAlignment(.center)
            if showRetry { Button(tr("Повторить"), action: retry).buttonStyle(MSButtonStyle(primary: false)).frame(maxWidth: 220) }
        }.padding(24).frame(maxWidth: .infinity, minHeight: 280)
            .accessibilityIdentifier("state.\(state == .failed ? "error" : state == .offline ? "offline" : "empty")")
    }
}

private enum WorkspaceWidthKey: EnvironmentKey { static let defaultValue: CGFloat = 390 }
private enum WorkspaceUnreadKey: EnvironmentKey { static let defaultValue = 0 }

extension EnvironmentValues {
    var workspaceWidth: CGFloat {
        get { self[WorkspaceWidthKey.self] }
        set { self[WorkspaceWidthKey.self] = newValue }
    }
    var workspaceUnreadNotifications: Int {
        get { self[WorkspaceUnreadKey.self] }
        set { self[WorkspaceUnreadKey.self] = newValue }
    }
}

struct PageHeader<Actions: View>: View {
    let title: String
    @ViewBuilder var actions: () -> Actions
    @Environment(\.workspaceWidth) private var width

    var body: some View {
        HStack(spacing: width >= 780 ? 8 : 1) {
            if width >= 780 { BrandMark().frame(width: 32, height: 32).padding(.trailing, 6) }
            Text(tr(title)).font(MSTheme.font(width >= 780 ? 25 : 23, weight: .semibold, relativeTo: .title))
                .tracking(-0.5).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            actions()
        }
        .padding(.horizontal, width >= 700 ? 28 : width < 360 ? 16 : 20)
        .padding(.vertical, 8).frame(minHeight: 75)
        .background(MSTheme.surface, ignoresSafeAreaEdges: .top)
        .overlay(alignment: .bottom) { Rectangle().fill(MSTheme.line).frame(height: 1) }
    }
}

struct WorkspaceHeaderButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @Environment(\.workspaceWidth) private var width

    init(_ symbol: String, label: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.action = action
    }

    var body: some View {
        let size: CGFloat = width >= 780 ? 46 : 44
        Button(action: action) {
            WorkspaceIcon(symbol, size: width >= 780 ? 27 : 24)
                .frame(width: size, height: size).contentShape(Rectangle())
        }.foregroundStyle(MSTheme.ink).buttonStyle(.plain).accessibilityLabel(tr(label))
    }
}

struct WorkspaceBell: View {
    let action: () -> Void
    @Environment(\.workspaceUnreadNotifications) private var unread

    var body: some View {
        WorkspaceHeaderButton("bell", label: "Уведомления", action: action)
            .overlay(alignment: .topTrailing) {
                if unread > 0 {
                    Text(unread > 99 ? "99+" : String(unread)).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white).padding(.horizontal, 4).frame(minWidth: 19, minHeight: 19)
                        .background(MSTheme.brandAccent, in: Capsule())
                        .overlay { Capsule().strokeBorder(MSTheme.background, lineWidth: 2) }.padding(.top, 3)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .anchorPreference(key: InboxBellAnchor.self, value: .bounds) { $0 }
            .accessibilityValue(String(unread)).accessibilityIdentifier("workspace.notifications")
    }
}

struct SearchBox: View {
    @Binding var text: String
    @Environment(\.dynamicTypeSize) private var typeSize
    let placeholder: String
    var identifier: String? = nil
    var onSubmit: () -> Void = {}
    private var fieldID: String { identifier ?? "searchField.\(placeholder)" }
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(MSTheme.muted).accessibilityHidden(true)
            #if os(iOS)
            AccessibleTextField(text: $text, placeholder: tr(typeSize.isAccessibilitySize ? "Поиск" : placeholder),
                                label: tr(placeholder), identifier: fieldID, onSubmit: onSubmit)
                .frame(minHeight: 44)
            #else
            TextField(tr(typeSize.isAccessibilitySize ? "Поиск" : placeholder), text: $text)
                .textFieldStyle(.plain).frame(minHeight: 44)
                .accessibilityLabel(tr(placeholder)).accessibilityIdentifier(fieldID).onSubmit(onSubmit)
            #endif
            if !text.isEmpty { Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel(tr("Очистить поиск")) }
        }.padding(.horizontal, 12).frame(minHeight: 44).background(MSTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(MSTheme.line))
    }
}

#if os(iOS)
/// The native text field itself must be 44pt high. A frame around SwiftUI's plain
/// TextField leaves its UIKit accessibility element at the font's intrinsic height.
struct AccessibleTextField: UIViewRepresentable {
    @Binding var text: String
    @Environment(\.isEnabled) private var isEnabled
    let placeholder: String
    let label: String
    var identifier = ""
    var focused: Binding<Bool>? = nil
    var returnKey: UIReturnKeyType = .search
    var onSubmit: () -> Void = {}

    func makeUIView(context: Context) -> MinimumHeightTextField {
        let field = MinimumHeightTextField()
        field.delegate = context.coordinator
        field.adjustsFontForContentSizeCategory = true
        field.addTarget(context.coordinator, action: #selector(Coordinator.edited(_:)), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateUIView(_ field: MinimumHeightTextField, context: Context) {
        context.coordinator.owner = self
        if field.text != text { field.text = text }
        field.accessibilityLabel = label; field.accessibilityIdentifier = identifier; field.isEnabled = isEnabled
        field.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont(name: "Inter-Regular", size: 14) ?? .systemFont(ofSize: 14), compatibleWith: field.traitCollection)
        field.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [.foregroundColor: UIColor(MSTheme.muted)])
        field.textColor = UIColor(MSTheme.ink); field.returnKeyType = returnKey
        if let focused, !focused.wrappedValue, field.isFirstResponder { field.resignFirstResponder() }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MinimumHeightTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? max(44, uiView.intrinsicContentSize.width), height: uiView.intrinsicContentSize.height)
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    @MainActor final class Coordinator: NSObject, UITextFieldDelegate {
        var owner: AccessibleTextField
        init(_ owner: AccessibleTextField) { self.owner = owner }
        @objc func edited(_ field: UITextField) { owner.text = field.text ?? "" }
        func textFieldDidBeginEditing(_ textField: UITextField) {
            if let focused = owner.focused, !focused.wrappedValue { focused.wrappedValue = true }
        }
        func textFieldDidEndEditing(_ textField: UITextField) {
            if let focused = owner.focused, focused.wrappedValue { focused.wrappedValue = false }
        }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            owner.onSubmit(); textField.resignFirstResponder(); return true
        }
    }
}

final class MinimumHeightTextField: UITextField {
    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width, height: max(44, (font?.lineHeight ?? size.height) + 12))
    }
}
#endif

struct FeatureNotice: View {
    let message: String
    init(_ message: String = "Это просмотр интерфейса. Операция с сервером пока недоступна.") { self.message = message }
    var body: some View {
        Label(tr(message), systemImage: "info.circle").font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
            .fixedSize(horizontal: false, vertical: true).padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(MSTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
    }
}
