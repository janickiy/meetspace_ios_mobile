import SwiftUI
import AVFoundation
#if os(iOS)
import UIKit
#endif
import MeetSpaceCore
import MeetSpaceDesignSystem
import MeetSpaceMedia
import MeetSpaceInstaller

struct LiveProfileView: View {
    @Bindable var app: AppModel
    @State private var removing: AccountRecord?
    @State private var licenses = false
    @State private var deleting: AccountRecord?
    var body: some View {
        Group {
            if let account = app.identity.messaging?.account, let settings = app.identity.settings {
                AccountHome(name: settings.profile.name, email: account.user.email, server: account.server.displayName,
                            demo: false, photo: settings.photo, logout: { removing = account }) { section, wide in
                    switch section {
                    case .profile: AccountSettingsContent(model: settings, section: .profile, wide: wide)
                    case .accounts: ScrollView { accounts.padding(20) }
                    case .audio: AccountSettingsContent(model: settings, section: .audio, wide: wide)
                    case .video: CameraDevicesView()
                    case .notifications: AccountSettingsContent(model: settings, section: .notifications, wide: wide)
                    case .appearance: SettingsDetailView(model: app, route: .appearance)
                    case .connection: AccountSettingsContent(model: settings, section: .server, wide: wide)
                    }
                } extras: {
                    VStack(alignment: .leading, spacing: 12) {
                        NavigationLink { AccountSettingsView(model: settings) } label: {
                            Label(tr("Дополнительные настройки"), systemImage: "gearshape").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }.buttonStyle(.plain).accessibilityIdentifier("openAccountSettings")
                        workspaceLink("Календарь", icon: "calendar", route: .calendar, id: "openCalendar")
                        workspaceLink("Записи встреч", icon: "play.rectangle", route: .recordings, id: "openRecordings")
                        workspaceLink("Личные папки", icon: "folder", route: .folders, id: "openFolders")
                        notificationSettings
                        Button(tr("Лицензии компонентов")) { licenses = true }.frame(minHeight: 44)
                        Button(tr("Удалить аккаунт на сервере"), role: .destructive) {
                            app.identity.error = nil; deleting = account
                        }.frame(minHeight: 44).accessibilityIdentifier("openDeleteAccount")
                    }
                }
                .task(id: account.id) { if !settings.loaded { await settings.load() } }
            }
        }.disabled(app.identity.busy)
            .sheet(item: $deleting) { account in DeleteAccountView(identity: app.identity, account: account) }
            .sheet(isPresented: $licenses) {
                NavigationStack {
                    ScrollView { Text(WebRTCLibrary.licenseText + "\n\n" + InstallerLibrary.licenseText).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding() }
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
    private var accounts: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("Аккаунты")).font(MSTheme.font(21, weight: .semibold))
            ForEach(app.identity.index.accounts) { account in
                HStack {
                    Button {
                        Task { await app.identity.switchAccount(account) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(account.user.name)
                                Text(account.server.displayName).font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityLabel(tr("Адрес сервера")).accessibilityValue(account.server.displayName)
                            }
                            Spacer()
                            if app.identity.messaging?.account.id == account.id { Image(systemName: "checkmark.circle.fill") }
                        }.frame(minHeight: 44).contentShape(Rectangle()).accessibilityElement(children: .combine)
                    }.buttonStyle(.plain)
                    IconButton("rectangle.portrait.and.arrow.right", label: "Выйти из аккаунта") { removing = account }
                }.msCard()
            }
            Button(tr("Добавить аккаунт")) {
                app.identity.error = nil; app.identity.information = nil
                app.identity.addingAccount = true; app.show(.connect)
            }.buttonStyle(MSButtonStyle(primary: false)).accessibilityIdentifier("addAccount")
            Text(tr("До 5 аккаунтов на каждом сервере.")).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
            if app.identity.busy { ProgressView() }
            if let error = app.identity.error { Text(tr(error)).foregroundStyle(MSTheme.danger) }
            if let information = app.identity.information { Text(tr(information)).foregroundStyle(MSTheme.muted) }
        }.frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func workspaceLink(_ title: String, icon: String, route: AppRoute, id: String) -> some View {
        Button { app.navigate(route) } label: {
            HStack { Label(tr(title), systemImage: icon); Spacer(); Image(systemName: "chevron.right") }
                .frame(minHeight: 44).contentShape(Rectangle())
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

private struct CameraDevicesView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var cameras: [String] = []
    @State private var permission = AVCaptureDevice.authorizationStatus(for: .video)
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(tr("Видео")).font(MSTheme.font(21, weight: .semibold))
                Text(tr("Камера")).font(MSTheme.font(16, weight: .semibold))
                if cameras.isEmpty { Text(tr("Камера недоступна")).foregroundStyle(MSTheme.muted) }
                ForEach(Array(cameras.enumerated()), id: \.offset) { _, name in Label(name, systemImage: "video") }
                if permission == .denied || permission == .restricted {
                    Text(tr("Доступ к камере отключён")).foregroundStyle(MSTheme.muted)
                    #if os(iOS)
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        Link(tr("Открыть настройки"), destination: url).frame(minHeight: 44)
                    }
                    #endif
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }.onAppear(perform: refresh).onChange(of: scenePhase) { _, value in if value == .active { refresh() } }
    }
    private func refresh() {
        permission = AVCaptureDevice.authorizationStatus(for: .video)
        cameras = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external],
                                                    mediaType: .video, position: .unspecified).devices.map(\.localizedName)
    }
}
