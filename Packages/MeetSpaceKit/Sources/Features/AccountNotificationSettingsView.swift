import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

struct DemoAccountNotificationForm: View {
    @Bindable var profile: DemoAccountProfile
    let wide: Bool
    @State private var saved = false

    var body: some View {
        AccountNotificationForm(preferences: $profile.notificationDraft, sound: $profile.notificationSound,
                                wide: wide, editable: true,
                                canSave: profile.notificationDraft != profile.savedNotifications,
                                saved: saved && profile.notificationDraft == profile.savedNotifications) {
            profile.savedNotifications = profile.notificationDraft
            saved = true
        }
        .onChange(of: profile.notificationDraft) { _, _ in saved = false }
    }
}

struct LiveAccountNotificationSettings: View {
    @Bindable var settings: SettingsModel
    let push: PushRegistrationModel
    var wide = false
    @AppStorage(ForegroundNotificationSound.defaultsKey) private var sound = true
    @State private var showDevices = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                AccountNotificationForm(preferences: $settings.preferences, sound: $sound, wide: wide,
                                        editable: !settings.busy && settings.savedPreferences != nil,
                                        canSave: settings.canSavePreferences,
                                        saved: settings.information == "Настройки уведомлений сохранены" && settings.preferences == settings.savedPreferences,
                                        error: settings.preferencesError) {
                    Task { await settings.saveNotifications() }
                }
                if settings.busy {
                    ProgressView().accessibilityIdentifier("settingsLoading")
                } else if settings.savedPreferences == nil && settings.preferencesError != nil {
                    Button(tr("Повторить")) { Task { await settings.load() } }.buttonStyle(MSTextButtonStyle())
                }
                deviceOptions
            }.padding(.horizontal, wide ? 48 : 20).padding(.vertical, wide ? 36 : 18)
                .frame(maxWidth: 860).frame(maxWidth: .infinity, alignment: .topLeading)
        }.background(MSTheme.background)
            .accessibilityIdentifier("accountSettingsScroll")
    }

    private var deviceOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            Button { showDevices.toggle() } label: {
                HStack {
                    Text(tr("Push и устройства")).font(MSTheme.font(13.4, weight: .semibold))
                    Spacer()
                    WorkspaceIcon(showDevices ? "chevron.up" : "chevron.down", size: 14)
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(MSTheme.ink)
                .accessibilityValue(tr(showDevices ? "Развёрнуто" : "Свёрнуто"))
                .accessibilityIdentifier("notificationDevicesDetails")
            if showDevices {
                Toggle(tr("Push на устройства аккаунта"), isOn: $settings.preferences.push)
                    .toggleStyle(AccountSwitchStyle()).font(MSTheme.font(13.4))
                    .disabled(settings.busy || settings.savedPreferences == nil)
                    .accessibilityIdentifier("notificationAccountPush")
                if let original = settings.savedPreferences, settings.preferences.push != original.push {
                    Button(tr("Сохранить настройки")) { Task { await settings.saveNotifications() } }
                        .buttonStyle(MSTextButtonStyle()).disabled(!settings.canSavePreferences)
                        .accessibilityIdentifier("saveNotificationDevicePreferences")
                }
                DeviceNotificationSettings(model: push)
                #if os(iOS)
                Text(tr("Для уведомлений в фоне звук настраивается в iOS."))
                    .font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
                #endif
                Text(tr("Устройства уведомлений")).font(MSTheme.font(15, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(tr("Зарегистрированные устройства доставки уведомлений. Это не список активных входов в аккаунт."))
                    .font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
                if let error = settings.devicesError {
                    Text(tr(error)).font(MSTheme.font(13)).foregroundStyle(MSTheme.danger)
                } else if settings.loaded && settings.devices.isEmpty {
                    Text(tr("Устройства не зарегистрированы")).font(MSTheme.font(13))
                }
                ForEach(settings.devices) { device in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(device.platform.uppercased(), systemImage: device.platform == "web" ? "desktopcomputer" : "iphone")
                            Spacer()
                            Text(tr(device.revokedAt != nil ? "Отозвано" : device.disabledAt != nil ? "Отключено" : "Активно"))
                                .foregroundStyle(device.isActive ? MSTheme.accent : MSTheme.muted)
                        }
                        Text(device.id.uuidString.lowercased()).font(MSTheme.font(11)).textSelection(.enabled)
                        Text(device.updatedAt, format: .dateTime.day().month().year().hour().minute())
                            .font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
                    }.msCard()
                }
                Button(tr("Обновить настройки")) { Task { await settings.load() } }
                    .buttonStyle(MSTextButtonStyle()).disabled(settings.busy)
            }
        }
    }
}

private struct AccountNotificationForm: View {
    @Binding var preferences: NotificationPreferences
    @Binding var sound: Bool
    let wide: Bool
    let editable: Bool
    let canSave: Bool
    let saved: Bool
    var error: String? = nil
    let save: () -> Void
    @State private var audio = AudioSettingsModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AccountDetailHeading(title: "Уведомления", subtitle: "Выберите события и каналы доставки.")
                .padding(.bottom, wide ? 32 : 30)
            heading("События")
            row("Приглашения и изменения встреч", identifier: "notificationInvitation",
                binding: $preferences.invitation).disabled(!editable)
            rule
            row("Напоминания о встречах", identifier: "notificationReminder",
                binding: $preferences.reminder).disabled(!editable)
            rule
            row("Готовность записи", identifier: "notificationRecording",
                binding: $preferences.recording).disabled(!editable)
            sectionDivider
            heading("Звук уведомлений")
            row("Звуковой сигнал", hint: "Новые сообщения, ответы и другие уведомления.",
                identifier: "notificationSound", binding: $sound)
            soundPreview
            sectionDivider
            heading("Каналы доставки")
            row("Email", hint: "Получать выбранные события по электронной почте.",
                identifier: "notificationEmail", binding: $preferences.email).disabled(!editable)
            if let error {
                Text(tr(error)).font(MSTheme.font(13)).foregroundStyle(MSTheme.danger).padding(.vertical, 6)
            }
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(spacing: 14))
            layout {
                Button(tr("Сохранить настройки"), action: save)
                    .buttonStyle(MSButtonStyle()).fixedSize(horizontal: !typeSize.isAccessibilitySize, vertical: true)
                    .disabled(!canSave).accessibilityIdentifier("saveNotificationPreferences")
                if saved {
                    HStack(spacing: 6) {
                        WorkspaceIcon("checkmark", size: 16).accessibilityHidden(true)
                        Text(tr("Настройки сохранены")).font(MSTheme.font(12))
                            .accessibilityLabel(tr("Настройки уведомлений сохранены"))
                            .accessibilityIdentifier("settingsSaved")
                    }.foregroundStyle(MSTheme.accent)
                }
            }.padding(.top, wide ? 24 : 16)
            hint("Личные приглашения, отправленные организатором, приходят отдельно.").padding(.top, 20)
        }.frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(MSTheme.ink)
            .onChange(of: sound) { _, enabled in if !enabled { audio.stop() } }
            .onChange(of: scenePhase) { _, phase in if phase != .active { audio.stop() } }
            .onDisappear { audio.disappear() }
    }

    private var soundPreview: some View {
        let playing = audio.check == .signals
        return VStack(alignment: .leading, spacing: 10) {
            Button { Task { await audio.test(.signals) } } label: {
                HStack(spacing: 8) {
                    WorkspaceIcon("speaker.wave.2", size: 18)
                    Text(tr(playing ? "Воспроизводится…" : "Проверить звук")).font(MSTheme.font(12.6, weight: .semibold))
                }.padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: 44)
                    .foregroundStyle(playing ? MSTheme.accent : MSTheme.ink)
                    .background(playing ? MSTheme.accentSoft : MSTheme.surface, in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(playing ? MSTheme.accent : MSTheme.line))
            }.buttonStyle(.plain).disabled(!sound || playing).opacity(sound ? 1 : 0.45)
                .accessibilityIdentifier("notificationTestSound")
            hint("В чатах с отключёнными уведомлениями сигнал не звучит.")
            if playing {
                hint("Проверка звука…").accessibilityIdentifier("notificationTestSoundStatus")
            }
            if sound, let message = audio.notice {
                Text(tr(message)).font(MSTheme.font(12)).foregroundStyle(MSTheme.danger)
            }
        }
    }

    private func heading(_ title: String) -> some View {
        Text(tr(title)).font(MSTheme.font(15, weight: .semibold)).accessibilityAddTraits(.isHeader)
            .padding(.bottom, wide ? 16 : 12)
    }

    private func row(_ title: String, hint detail: String? = nil, identifier: String, binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr(title)).font(MSTheme.font(13.4)).lineSpacing(3)
                if let detail { hint(detail) }
            }
        }.toggleStyle(AccountSwitchStyle()).padding(.vertical, detail == nil ? 7 : 14)
            .accessibilityLabel(tr(title)).accessibilityIdentifier(identifier)
    }

    private func hint(_ text: String) -> some View {
        Text(tr(text)).font(MSTheme.font(11.5)).lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true).foregroundStyle(MSTheme.muted)
    }

    private var rule: some View { Rectangle().fill(MSTheme.line).frame(height: 1).accessibilityHidden(true) }
    private var sectionDivider: some View { rule.padding(.top, wide ? 24 : 16).padding(.bottom, wide ? 24 : 20) }
}
