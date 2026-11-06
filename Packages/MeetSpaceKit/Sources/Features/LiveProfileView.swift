import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem
import MeetSpaceMedia

struct LiveProfileView: View {
    @Bindable var app: AppModel
    @State private var removing: AccountRecord?
    @State private var licenses = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(tr("Профиль")).font(MSTheme.font(28, weight: .semibold))
                if let account = app.identity.messaging?.account {
                    HStack(spacing: 16) {
                        Avatar(String((app.identity.settings?.profile.name ?? account.user.name).prefix(2)).uppercased(), size: 56)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(app.identity.settings?.profile.name ?? account.user.name).font(MSTheme.font(18, weight: .semibold))
                            Text(account.user.email).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
                            Text(account.server.displayName).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
                        }
                    }.msCard()
                }
                if let settings = app.identity.settings {
                    NavigationLink { AccountSettingsView(model: settings) } label: {
                        Label(tr("Настройки аккаунта"), systemImage: "person.crop.circle")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.buttonStyle(.plain).msCard().accessibilityIdentifier("openAccountSettings")
                }
                VStack(spacing: 0) {
                    workspaceLink("Календарь", icon: "calendar", route: .calendar, id: "openCalendar")
                    workspaceLink("Записи встреч", icon: "play.rectangle", route: .recordings, id: "openRecordings")
                    workspaceLink("Личные папки", icon: "folder", route: .folders, id: "openFolders")
                }.msCard()
                Text(tr("Аккаунты")).font(MSTheme.font(18, weight: .semibold))
                ForEach(app.identity.index.accounts) { account in
                    HStack {
                        Button {
                            Task { await app.identity.switchAccount(account) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(account.user.name)
                                    Text(account.server.displayName).font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
                                }
                                Spacer()
                                if app.identity.messaging?.account.id == account.id { Image(systemName: "checkmark.circle.fill") }
                            }.frame(minHeight: 44)
                        }.buttonStyle(.plain)
                        IconButton("rectangle.portrait.and.arrow.right", label: "Выйти из аккаунта") { removing = account }
                    }.msCard()
                }
                Button(tr("Добавить аккаунт")) {
                    app.identity.error = nil; app.identity.information = nil
                    app.identity.addingAccount = true; app.show(.connect)
                }.buttonStyle(MSButtonStyle(primary: false)).accessibilityIdentifier("addAccount")
                Text(tr("До 5 аккаунтов на каждом сервере.")).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
                notificationSettings
                Picker(tr("Оформление"), selection: Binding(get: { app.configuration.appearance }, set: { app.setAppearance($0) })) {
                    Text(tr("Как в системе")).tag(Appearance.system)
                    Text(tr("Светлая")).tag(Appearance.light)
                    Text(tr("Тёмная")).tag(Appearance.dark)
                }.pickerStyle(.segmented)
                if app.identity.busy { ProgressView() }
                if let error = app.identity.error { Text(tr(error)).foregroundStyle(MSTheme.danger) }
                if let information = app.identity.information { Text(tr(information)).foregroundStyle(MSTheme.muted) }
                Button(tr("Лицензии компонентов")) { licenses = true }
            }.padding(24).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }.background(MSTheme.background).disabled(app.identity.busy)
            .sheet(isPresented: $licenses) {
                NavigationStack {
                    ScrollView { Text(WebRTCLibrary.licenseText).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding() }
                        .navigationTitle(tr("Лицензии компонентов"))
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(tr("Готово")) { licenses = false } } }
                }
            }
            .confirmationDialog(tr("Выйти из аккаунта на этом устройстве?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                Button(tr("Выйти"), role: .destructive) {
                    if let account = removing { Task { await app.identity.logout(account) } }; removing = nil
                }
            }
    }
    private func workspaceLink(_ title: String, icon: String, route: AppRoute, id: String) -> some View {
        Button { app.navigate(route) } label: {
            HStack { Label(tr(title), systemImage: icon); Spacer(); Image(systemName: "chevron.right") }
                .frame(minHeight: 44)
        }.buttonStyle(.plain).accessibilityIdentifier(id)
    }
    private var notificationSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Уведомления на этом устройстве")).font(MSTheme.font(18, weight: .semibold))
            Toggle(tr("Уведомления о встречах"), isOn: Binding(
                get: { app.identity.notifications.enabled },
                set: { enabled in Task {
                    if enabled { await app.identity.notifications.enable() }
                    else { await app.identity.notifications.disable() }
                } }))
                .disabled(app.identity.notifications.busy).accessibilityIdentifier("pushNotificationsToggle")
            Text(tr(app.identity.notifications.status)).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
                .accessibilityIdentifier("pushNotificationsStatus")
            if let error = app.identity.notifications.error {
                Text(tr(error)).font(MSTheme.font(12)).foregroundStyle(MSTheme.danger)
                Button(tr("Повторить проверку")) { Task { await app.identity.notifications.retryCleanup() } }
                    .frame(minHeight: 44).disabled(app.identity.notifications.busy)
            }
            Text(tr("Входящие звонки доступны, пока приложение открыто. Вызовы при закрытом приложении ещё не настроены на сервере."))
                .font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
        }.msCard()
    }
}
