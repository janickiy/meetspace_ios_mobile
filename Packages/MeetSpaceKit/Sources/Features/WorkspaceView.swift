import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

struct WorkspaceView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            if model.isDemo { HStack(spacing: 8) {
                Image(systemName: "eye").accessibilityHidden(true)
                Text(tr("Демо · данные из макетов")).font(MSTheme.font(11, weight: .semibold))
                    .accessibilityIdentifier("demoBanner")
                Spacer(minLength: 0)
                Button(tr("Выйти")) { model.leaveDemo() }.frame(minHeight: 44).accessibilityIdentifier("exitDemo")
            }.padding(.horizontal, 20).background(MSTheme.accentSoft).foregroundStyle(MSTheme.accent)
                // Persistent navigation must leave room for fully scaled, scrollable content.
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            }
            TabView(selection: $model.tab) {
                stack(tab: .meetings, path: $model.meetingsPath) {
                    if model.isDemo { MeetingsView(model: model) }
                    else if let meetings = model.identity.conferences { LiveMeetingsView(model: meetings) }
                }
                stack(tab: .messages, path: $model.messagesPath) {
                    if let messaging = model.identity.messaging, !model.isDemo { LiveMessagesView(app: model, model: messaging) }
                    else { MessagesView(model: model) }
                }
                stack(tab: .profile, path: $model.profilePath) {
                    if model.isDemo { ProfileView(model: model) }
                    else { LiveProfileView(app: model) }
                }
            }
            HStack(spacing: 0) {
                tabButton(.meetings, title: "Встречи", icon: "video")
                tabButton(.messages, title: "Чаты", icon: "bubble.left.and.bubble.right")
                tabButton(.profile, title: "Профиль", icon: "person.crop.circle")
            }.padding(.top, 5).background(MSTheme.surface)
                .overlay(alignment: .top) { Rectangle().fill(MSTheme.line).frame(height: 1) }
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }.background(MSTheme.background)
    }

    private func stack<Content: View>(tab: AppTab, path: Binding<[AppRoute]>, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack(path: path) {
            content().navigationDestination(for: AppRoute.self) { route in DestinationView(model: model, route: route) }
        }.tag(tab).msHideSystemTabBar()
    }

    private func tabButton(_ tab: AppTab, title: String, icon: String) -> some View {
        Button { model.tab = tab } label: {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 21))
                Text(tr(title)).font(MSTheme.font(10, weight: .semibold, relativeTo: .caption))
            }.frame(maxWidth: .infinity, minHeight: 54).padding(.bottom, 3)
                .foregroundStyle(model.tab == tab ? MSTheme.accent : MSTheme.muted).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("tab.\(tab.rawValue)")
            .accessibilityAddTraits(model.tab == tab ? .isSelected : [])
    }
}

private extension View {
    @ViewBuilder func msHideSystemTabBar() -> some View {
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

struct PageHeader<Actions: View>: View {
    let title: String
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        HStack(spacing: 2) {
            Text(tr(title)).font(MSTheme.font(25, weight: .semibold, relativeTo: .title)).tracking(-0.7)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4); actions()
        }.padding(.horizontal, 24).padding(.vertical, 12).background(MSTheme.surface)
    }
}

struct SearchBox: View {
    @Binding var text: String
    let placeholder: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(MSTheme.muted)
            TextField(tr(placeholder), text: $text).textFieldStyle(.plain).accessibilityLabel(tr(placeholder))
            if !text.isEmpty { Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel(tr("Очистить поиск")) }
        }.padding(12).frame(minHeight: 44).background(MSTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(MSTheme.line))
    }
}

struct FeatureNotice: View {
    let message: String
    init(_ message: String = "Это просмотр интерфейса. Операция с сервером пока недоступна.") { self.message = message }
    var body: some View {
        Label(tr(message), systemImage: "info.circle").font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
            .fixedSize(horizontal: false, vertical: true).padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(MSTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
    }
}
