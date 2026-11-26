import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem
import MeetSpaceMedia
import MeetSpaceInstaller

struct LiveProfileView: View {
    @Bindable var app: AppModel
    @State private var removing: AccountRecord?
    @State private var licenses = false
    var body: some View {
        Group {
            if let account = app.identity.messaging?.account, let settings = app.identity.settings {
                AccountHome(name: settings.profile.name, email: account.user.email, server: account.server.displayName,
                            demo: false, photo: settings.photo, logout: { removing = account }) { section, wide in
                    switch section {
                    case .profile: AccountSettingsContent(model: settings, section: .profile, wide: wide) { EmptyView() }
                    case .accounts: AccountSwitcherView(app: app, wide: wide)
                    case .audio: AccountSettingsContent(model: settings, section: .audio, wide: wide) { EmptyView() }
                    case .video: SettingsDetailView(model: app, route: .videoSettings, wide: wide).id(account.key)
                    case .notifications:
                        LiveAccountNotificationSettings(settings: settings, wide: wide)
                    case .appearance: SettingsDetailView(model: app, route: .appearance, wide: wide)
                    case .connection:
                        AccountConnectionPage(app: app, wide: wide, openLicenses: { licenses = true })
                    }
                }
                .task(id: account.id) { if !settings.loaded { await settings.load() } }
            }
        }.disabled(app.identity.busy)
            .sheet(isPresented: $licenses) {
                NavigationStack {
                    ScrollView { Text(WebRTCLibrary.licenseText + "\n\n" + InstallerLibrary.licenseText).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding() }
                        .navigationTitle(tr("Лицензии компонентов")).msInlineTitle()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                MSLiquidAction(.close, inToolbar: true) { licenses = false }
                                    .accessibilityLabel(tr("Готово"))
                            }
                        }
                }
            }
            .confirmationDialog(tr("Выйти из аккаунта на этом устройстве?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                Button(tr("Выйти"), role: .destructive) {
                    if let account = removing { Task { await app.identity.logout(account) } }; removing = nil
                }
            }
    }

}

struct DeviceNotificationSettings: View {
    let model: PushRegistrationModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Уведомления на этом устройстве")).font(MSTheme.font(15, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            Toggle(isOn: Binding(
                get: { model.enabled },
                set: { enabled in Task {
                    if enabled { await model.enable() }
                    else { await model.disable() }
                } })) {
                    Text(tr("Уведомления о встречах")).font(MSTheme.font(13, weight: .semibold))
                }.toggleStyle(AccountSwitchStyle())
                .disabled(model.busy).accessibilityIdentifier("pushNotificationsToggle")
            Text(tr(model.status)).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("pushNotificationsStatus")
            if let error = model.error {
                Text(tr(error)).font(MSTheme.font(12)).foregroundStyle(MSTheme.danger)
                Button(tr("Повторить проверку")) { Task { await model.retryCleanup() } }
                    .frame(minHeight: 44).disabled(model.busy)
            }
            Text(tr("Входящие звонки доступны, пока приложение открыто. Вызовы при закрытом приложении ещё не настроены на сервере."))
                .font(MSTheme.font(12)).foregroundStyle(MSTheme.muted).fixedSize(horizontal: false, vertical: true)
        }.msCard(padding: 14)
    }
}
