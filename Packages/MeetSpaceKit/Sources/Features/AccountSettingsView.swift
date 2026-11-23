import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

enum AccountSettingsSection {
    case profile, audio, notifications, server
}

struct AccountSettingsContent<Controls: View>: View {
    @Bindable var model: SettingsModel
    let section: AccountSettingsSection
    var wide = false
    @ViewBuilder var controls: () -> Controls
    @FocusState private var profileNameFocused: Bool
    @State private var nativeProfileNameFocused = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch section {
                case .profile: profile
                case .audio: AccountAudioSettingsView(wide: wide)
                case .notifications: preferences
                case .server: server
                }
                if section != .audio {
                    if model.busy { ProgressView().accessibilityIdentifier("settingsLoading") }
                    if let information = model.information {
                        Text(tr(information)).font(MSTheme.font(13)).foregroundStyle(MSTheme.muted).accessibilityIdentifier("settingsSaved")
                    }
                    Button(tr("Обновить настройки")) {
                        profileNameFocused = false
                        nativeProfileNameFocused = false
                        Task { await model.load() }
                    }
                        .buttonStyle(MSButtonStyle(primary: false)).disabled(model.busy)
                }
                controls()
                if section == .notifications { devices }
            }.padding(.horizontal, wide ? 48 : 20).padding(.vertical, wide ? 36 : 18)
                .frame(maxWidth: 860).frame(maxWidth: .infinity, alignment: .topLeading)
        }.background(MSTheme.background)
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("accountSettingsScroll")
            .onChange(of: section) { _, _ in profileNameFocused = false; nativeProfileNameFocused = false }
    }
    private var profile: some View {
        VStack(alignment: .leading, spacing: 26) {
            ProfileEditorHeading()
            ProfilePhotoCard(name: model.profile.name, photo: model.photo, hasPhoto: model.profile.avatarVersion != nil) {
                await model.savePhoto($0)
            }.disabled(model.busy).task(id: model.profile.avatarVersion) { await model.loadPhoto() }
            ProfileField(label: "Имя для встреч", hint: "От 1 до 100 символов.") {
                #if os(iOS)
                AccessibleTextField(text: $model.displayName, placeholder: tr("Имя"), label: tr("Имя для встреч"),
                                    identifier: "profileDisplayName", focused: $nativeProfileNameFocused, returnKey: .done)
                    .frame(minHeight: 26).profileInput().disabled(model.busy || model.profile.authSource == "ldap")
                #else
                TextField(tr("Имя"), text: $model.displayName).textFieldStyle(.plain).profileInput()
                    .focused($profileNameFocused).submitLabel(.done).onSubmit { profileNameFocused = false }
                    .disabled(model.busy || model.profile.authSource == "ldap").accessibilityIdentifier("profileDisplayName")
                #endif
            }
            if model.profile.bio != nil {
                ProfileField(label: "О себе") {
                    TextField(tr("Расскажите о себе"), text: $model.bio, axis: .vertical)
                        .textFieldStyle(.plain).lineLimit(3...12).profileInput(multiline: true)
                        .accessibilityLabel(tr("О себе")).accessibilityIdentifier("profileBio").disabled(model.busy)
                }
                if (try? ProfileValidation.bio(model.bio)) == nil {
                    errorMessage("Допустимо до 1000 символов, включая переносы строк.")
                }
            }
            ProfileField(label: "Email", hint: "Адрес используется для входа. Изменение email недоступно.") {
                Text(verbatim: model.profile.email).textSelection(.enabled).profileInput(readOnly: true)
                    .accessibilityLabel(tr("Электронная почта")).accessibilityValue(model.profile.email)
            }
            if let error = model.profileError { errorMessage(error) }
            Button(tr("Сохранить профиль")) {
                profileNameFocused = false
                nativeProfileNameFocused = false
                Task { await model.saveProfile() }
            }
                .buttonStyle(MSButtonStyle()).disabled(!model.canSaveProfile).accessibilityIdentifier("saveProfile")
            Divider()
            LabeledContent(tr("Регистрация")) {
                Text(model.profile.createdAt, format: .dateTime.day().month().year())
            }.font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
        }
    }
    private var preferences: some View {
        VStack(alignment: .leading, spacing: 24) {
            AccountDetailHeading(title: "Уведомления", subtitle: "Выберите события и каналы доставки.")
            VStack(alignment: .leading, spacing: 0) {
                preferenceHeading("События")
                Toggle(tr("Приглашения и изменения встреч"), isOn: $model.preferences.invitation)
                    .accessibilityIdentifier("notificationInvitation").padding(.vertical, 7)
                Divider()
                Toggle(tr("Напоминания о встречах"), isOn: $model.preferences.reminder)
                    .accessibilityIdentifier("notificationReminder").padding(.vertical, 7)
                Divider()
                Toggle(tr("Готовность записей"), isOn: $model.preferences.recording)
                    .accessibilityIdentifier("notificationRecording").padding(.vertical, 7)
            }.disabled(model.busy || model.savedPreferences == nil)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                preferenceHeading("Каналы доставки")
                Toggle(isOn: $model.preferences.email) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("Email"))
                        Text(tr("Получать выбранные события по электронной почте."))
                            .font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
                    }
                }.accessibilityIdentifier("notificationEmail").padding(.vertical, 7)
                Divider()
                Toggle(tr("Push на устройства аккаунта"), isOn: $model.preferences.push)
                    .accessibilityIdentifier("notificationAccountPush").padding(.vertical, 7)
            }.disabled(model.busy || model.savedPreferences == nil)
            if let error = model.preferencesError { errorMessage(error) }
            Button(tr("Сохранить настройки")) { Task { await model.saveNotifications() } }
                .buttonStyle(MSButtonStyle()).disabled(!model.canSavePreferences).accessibilityIdentifier("saveNotificationPreferences")
            Text(tr("Доставка зависит от настройки провайдера на сервере."))
                .font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
        }.toggleStyle(AccountSwitchStyle())
    }
    private func preferenceHeading(_ title: String) -> some View {
        Text(tr(title)).font(MSTheme.font(15, weight: .semibold)).padding(.bottom, 10)
            .accessibilityAddTraits(.isHeader)
    }
    private var devices: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("Устройства уведомлений")).font(MSTheme.font(15, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text(tr("Зарегистрированные устройства доставки уведомлений. Это не список активных входов в аккаунт."))
                .font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
            if let error = model.devicesError { errorMessage(error) }
            else if model.loaded && model.devices.isEmpty { Text(tr("Устройства не зарегистрированы")) }
            ForEach(model.devices) { device in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(device.platform.uppercased(), systemImage: device.platform == "web" ? "desktopcomputer" : "iphone")
                        Spacer()
                        Text(tr(device.revokedAt != nil ? "Отозвано" : device.disabledAt != nil ? "Отключено" : "Активно"))
                            .foregroundStyle(device.isActive ? MSTheme.accent : MSTheme.muted)
                    }
                    Text(device.id.uuidString.lowercased()).font(MSTheme.font(11)).textSelection(.enabled)
                    Text(device.updatedAt, format: .dateTime.day().month().year().hour().minute()).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
                }.msCard()
            }
        }
    }
    private var server: some View {
        VStack(alignment: .leading, spacing: 16) {
            AccountDetailHeading(title: "Подключение", subtitle: "Адрес сервера вашего MeetSpace.")
            Text(model.account.server.displayName).font(MSTheme.font(16, weight: .semibold))
            if let error = model.capabilitiesError { errorMessage(error) }
            if let value = model.capabilities {
                LabeledContent(tr("Версия сервера"), value: value.buildVersion)
                LabeledContent(tr("Режимы записи"), value: value.recordingModes.isEmpty ? tr("Недоступны") : value.recordingModes.joined(separator: ", "))
            }
            if let integrations = model.integrations {
                capabilityRow("Почтовый провайдер", value: integrations.email)
                capabilityRow("Push-провайдер", value: integrations.push)
                capabilityRow("Внешний календарь", value: integrations.calendar)
            }
            Text(tr("Возможности сообщает выбранный сервер. Они не подтверждают работоспособность внешней доставки или установку провайдера."))
                .font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
            Divider()
            Label(tr("Установка сервера по SSH"), systemImage: "terminal").font(MSTheme.font(16, weight: .semibold))
            Text(tr("Откройте мастер «Развернуть свой сервер» на первом экране."))
                .font(MSTheme.font(13)).foregroundStyle(MSTheme.muted).accessibilityIdentifier("installerAvailable")
        }
    }
    private func capabilityRow(_ title: String, value: String) -> some View {
        // Provider identifiers are bounded categories, never endpoint URLs or credentials.
        let label = switch value {
        case "noop": "Не настроен"
        case "mock": "Тестовый режим"
        case "http": "Внешний шлюз"
        case "smtp": "SMTP"
        default: "Неизвестный режим"
        }
        return LabeledContent(tr(title), value: tr(label))
    }
    private func errorMessage(_ value: String) -> some View { Text(tr(value)).font(MSTheme.font(13)).foregroundStyle(MSTheme.danger) }
}

struct AccountDetailHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr(title)).font(MSTheme.font(21, weight: .semibold, relativeTo: .title2))
                .accessibilityAddTraits(.isHeader)
            Text(tr(subtitle)).font(MSTheme.font(13)).foregroundStyle(MSTheme.muted)
        }.fixedSize(horizontal: false, vertical: true)
    }
}
