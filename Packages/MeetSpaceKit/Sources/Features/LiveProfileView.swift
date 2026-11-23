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
                    case .profile: AccountSettingsContent(model: settings, section: .profile, wide: wide) { EmptyView() }
                    case .accounts: ScrollView { accounts(currentAccount: account, wide: wide) }.background(MSTheme.background)
                    case .audio: AccountSettingsContent(model: settings, section: .audio, wide: wide) { EmptyView() }
                    case .video: CameraDevicesView(wide: wide)
                    case .notifications:
                        AccountSettingsContent(model: settings, section: .notifications, wide: wide) {
                            DeviceNotificationSettings(model: app.identity.notifications)
                        }
                    case .appearance: SettingsDetailView(model: app, route: .appearance, wide: wide)
                    case .connection:
                        AccountSettingsContent(model: settings, section: .server, wide: wide) {
                            AccountShortcutRow(title: "Лицензии компонентов", symbol: "doc.text", identifier: "openComponentLicenses") {
                                licenses = true
                            }.msCard(padding: 0)
                        }
                    }
                }
                .task(id: account.id) { if !settings.loaded { await settings.load() } }
            }
        }.disabled(app.identity.busy)
            .sheet(item: $deleting) { account in DeleteAccountView(identity: app.identity, account: account) }
            .sheet(isPresented: $licenses) {
                NavigationStack {
                    ScrollView { Text(WebRTCLibrary.licenseText + "\n\n" + InstallerLibrary.licenseText).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding() }
                        .navigationTitle(tr("Лицензии компонентов")).msInlineTitle()
                        .toolbar { ToolbarItem(placement: .confirmationAction) { IconButton("xmark", label: "Готово") { licenses = false } } }
                }
            }
            .confirmationDialog(tr("Выйти из аккаунта на этом устройстве?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                Button(tr("Выйти"), role: .destructive) {
                    if let account = removing { Task { await app.identity.logout(account) } }; removing = nil
                }
            }
    }
    private func accounts(currentAccount: AccountRecord, wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            AccountDetailHeading(title: "Аккаунты", subtitle: "Выберите аккаунт для встреч и общения.")
                .padding(.bottom, 16)
            ForEach(app.identity.index.accounts) { account in
                let current = app.identity.messaging?.account.id == account.id
                let shape = RoundedRectangle(cornerRadius: wide ? 18 : 15)
                HStack(spacing: 4) {
                    Button {
                        Task { await app.identity.switchAccount(account) }
                    } label: {
                        HStack(spacing: 10) {
                            ProfileAvatar(name: account.user.name, size: 42, cornerRadius: 14,
                                          photo: current ? app.identity.settings?.photo : nil)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(account.user.name).font(MSTheme.font(14, weight: .semibold))
                                Text(account.user.email).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
                                Label(account.server.displayName, systemImage: "server.rack")
                                    .font(MSTheme.font(11)).foregroundStyle(MSTheme.muted).padding(.top, 4)
                            }.fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Image(systemName: current ? "checkmark.circle" : "arrow.right")
                                .font(.system(size: 16)).foregroundStyle(current ? MSTheme.accent : MSTheme.muted)
                                .accessibilityHidden(true)
                        }.padding(.vertical, 14).padding(.leading, 12)
                            .frame(minHeight: 44).contentShape(Rectangle()).accessibilityElement(children: .combine)
                    }.buttonStyle(.plain).accessibilityAddTraits(current ? .isSelected : [])
                    IconButton("rectangle.portrait.and.arrow.right", label: "Выйти из аккаунта") { removing = account }
                }.padding(.trailing, 6)
                    .background(current ? MSTheme.accentSoft : MSTheme.surface, in: shape)
                    .overlay(shape.strokeBorder(current ? MSTheme.accent : MSTheme.line).allowsHitTesting(false))
            }
            Button {
                app.identity.error = nil; app.identity.information = nil
                app.identity.addingAccount = true; app.show(.connect)
            } label: {
                Label(tr("Добавить аккаунт"), systemImage: "plus").frame(maxWidth: wide ? nil : .infinity, minHeight: 26)
            }.buttonStyle(MSButtonStyle()).accessibilityIdentifier("addAccount")
                .padding(.top, 4)
            Text(tr("До 5 аккаунтов на каждом сервере.")).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
            AccountShortcutRow(title: "Удалить аккаунт на сервере", symbol: "trash", identifier: "openDeleteAccount", destructive: true) {
                app.identity.error = nil
                deleting = currentAccount
            }.msCard(padding: 0)
            if app.identity.busy { ProgressView() }
            if let error = app.identity.error { Text(tr(error)).foregroundStyle(MSTheme.danger) }
            if let information = app.identity.information { Text(tr(information)).foregroundStyle(MSTheme.muted) }
        }.padding(.horizontal, wide ? 48 : 20).padding(.vertical, wide ? 36 : 18)
            .frame(maxWidth: 860).frame(maxWidth: .infinity, alignment: .topLeading)
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

private struct CameraDevicesView: View {
    let wide: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var cameras: [String] = []
    @State private var permission = AVCaptureDevice.authorizationStatus(for: .video)
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                AccountDetailHeading(title: "Видео", subtitle: "Доступ к камере для встреч.")
                VStack(spacing: 12) {
                    Image(systemName: "video.slash").font(.system(size: 28)).accessibilityHidden(true)
                    Text(tr(cameras.isEmpty ? "Камера недоступна" : "Камера выключена"))
                        .font(MSTheme.font(13)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }.foregroundStyle(.white).padding(16).frame(maxWidth: .infinity, minHeight: 144)
                    .aspectRatio(typeSize.isAccessibilitySize ? nil : 16 / 9, contentMode: .fit)
                    .background(Color(red: 0.14, green: 0.13, blue: 0.15), in: RoundedRectangle(cornerRadius: 16))
                if !cameras.isEmpty {
                    ProfileField(label: "Камера") {
                        Text(cameras.formatted(.list(type: .and))).profileInput(readOnly: true)
                    }
                }
                if permission == .denied || permission == .restricted {
                    Text(tr("Доступ к камере отключён")).font(MSTheme.font(13)).foregroundStyle(MSTheme.muted)
                    #if os(iOS)
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        Link(tr("Открыть настройки"), destination: url).frame(minHeight: 44)
                    }
                    #endif
                }
            }.padding(.horizontal, wide ? 48 : 20).padding(.vertical, wide ? 36 : 18)
                .frame(maxWidth: 860).frame(maxWidth: .infinity, alignment: .topLeading)
        }.background(MSTheme.background).onAppear(perform: refresh)
            .onChange(of: scenePhase) { _, value in if value == .active { refresh() } }
    }
    private func refresh() {
        permission = AVCaptureDevice.authorizationStatus(for: .video)
        cameras = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external],
                                                    mediaType: .video, position: .unspecified).devices.map(\.localizedName)
    }
}
