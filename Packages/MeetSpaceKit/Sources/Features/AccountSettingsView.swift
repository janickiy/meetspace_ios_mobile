import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

private enum AccountSettingsSection: String, CaseIterable, Identifiable {
    case profile = "Профиль", notifications = "Уведомления аккаунта", devices = "Устройства уведомлений", server = "Возможности сервера"
    var id: Self { self }
    var icon: String {
        switch self {
        case .profile: "person.crop.circle"
        case .notifications: "bell"
        case .devices: "iphone.and.arrow.forward"
        case .server: "server.rack"
        }
    }
}

/// Phone sections open individually; tablets keep the section menu beside the editor.
struct AccountSettingsView: View {
    @Bindable var model: SettingsModel
    @State private var selection = AccountSettingsSection.profile
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 700 && !typeSize.isAccessibilitySize {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            Avatar(String(model.profile.name.prefix(2)).uppercased(), size: 40)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.profile.name).font(MSTheme.font(13, weight: .semibold))
                                Text(model.profile.email).font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
                                    .accessibilityLabel(tr("Электронная почта")).accessibilityValue(model.profile.email)
                            }
                        }.padding(.bottom, 20)
                        ForEach(AccountSettingsSection.allCases) { section in
                            Button { selection = section } label: {
                                Label(tr(section.rawValue), systemImage: section.icon).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .background(selection == section ? MSTheme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).foregroundStyle(selection == section ? MSTheme.accent : MSTheme.ink)
                                .accessibilityAddTraits(selection == section ? .isSelected : [])
                                .accessibilityIdentifier("settingsSection.\(section)")
                        }
                    }.padding(16).frame(width: 230).msCard()
                    AccountSettingsContent(model: model, section: selection)
                }.padding(24)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(AccountSettingsSection.allCases) { section in
                            NavigationLink {
                                AccountSettingsContent(model: model, section: section)
                                    .navigationTitle(tr(section.rawValue)).msInlineTitle()
                            } label: {
                                HStack { Label(tr(section.rawValue), systemImage: section.icon); Spacer(); Image(systemName: "chevron.right").accessibilityHidden(true) }
                                    .frame(minHeight: 44).msCard().contentShape(Rectangle())
                                    .accessibilityElement(children: .combine)
                            }.buttonStyle(.plain).accessibilityIdentifier("settingsSection.\(section)")
                        }
                    }.padding(24)
                }
            }
        }.background(MSTheme.background).navigationTitle(tr("Настройки аккаунта")).msInlineTitle()
            .task { await model.load() }
    }
}

private struct AccountSettingsContent: View {
    @Bindable var model: SettingsModel
    let section: AccountSettingsSection
    @FocusState private var profileNameFocused: Bool
    @State private var nativeProfileNameFocused = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if section != .profile { Text(tr(section.rawValue)).font(MSTheme.font(24, weight: .semibold)) }
                switch section {
                case .profile: profile
                case .notifications: preferences
                case .devices: devices
                case .server: server
                }
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
            }.padding(24).frame(maxWidth: 720).frame(maxWidth: .infinity, alignment: .topLeading)
        }.background(MSTheme.background)
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("accountSettingsScroll")
            .onChange(of: section) { _, _ in profileNameFocused = false; nativeProfileNameFocused = false }
    }
    private var profile: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("Ваш профиль")).font(MSTheme.font(24, weight: .semibold))
                    Text(tr("Как вас видят участники встречи.")).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
                }
                Spacer(minLength: 0)
                Avatar(String(model.profile.name.prefix(2)).uppercased(), size: 64)
            }.padding(.bottom, 12)
            Text(tr("Имя для встреч")).font(MSTheme.font(12, weight: .semibold))
            #if os(iOS)
            AccessibleTextField(text: $model.displayName, placeholder: tr("Имя"), label: tr("Имя для встреч"),
                                identifier: "profileDisplayName", focused: $nativeProfileNameFocused, returnKey: .done)
                .frame(minHeight: 44).msCard().disabled(model.busy)
            #else
            TextField(tr("Имя"), text: $model.displayName).textFieldStyle(.plain).msCard()
                .focused($profileNameFocused).submitLabel(.done)
                .onSubmit { profileNameFocused = false }
                .disabled(model.busy).accessibilityIdentifier("profileDisplayName")
            #endif
            Text(tr("От 1 до 100 символов")).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
            Text(tr("Электронная почта")).font(MSTheme.font(12, weight: .semibold))
            Text(model.profile.email).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).msCard()
                .accessibilityLabel(tr("Электронная почта")).accessibilityValue(model.profile.email)
            Text(tr("Адрес используется для входа. Изменение email недоступно.")).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
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
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("Эти настройки сохраняются на сервере и действуют на всех устройствах аккаунта."))
                .font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
            VStack(spacing: 16) {
                Toggle(tr("Приглашения и изменения встреч"), isOn: $model.preferences.invitation).accessibilityIdentifier("notificationInvitation")
                Toggle(tr("Напоминания о встречах"), isOn: $model.preferences.reminder).accessibilityIdentifier("notificationReminder")
                Toggle(tr("Готовность записей"), isOn: $model.preferences.recording).accessibilityIdentifier("notificationRecording")
                Divider()
                Toggle(tr("По электронной почте"), isOn: $model.preferences.email).accessibilityIdentifier("notificationEmail")
                Toggle(tr("Push на устройства аккаунта"), isOn: $model.preferences.push).accessibilityIdentifier("notificationAccountPush")
            }.msCard().disabled(model.busy || model.savedPreferences == nil)
            Text(tr("Доставка зависит от настройки провайдера на сервере. Разрешение уведомлений этого iPhone или iPad включается отдельно в профиле."))
                .font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
            if let error = model.preferencesError { errorMessage(error) }
            Button(tr("Сохранить уведомления")) { Task { await model.saveNotifications() } }
                .buttonStyle(MSButtonStyle()).disabled(!model.canSavePreferences).accessibilityIdentifier("saveNotificationPreferences")
        }
    }
    private var devices: some View {
        VStack(alignment: .leading, spacing: 16) {
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
            Text(tr("Чтобы отключить уведомления этого устройства, используйте переключатель в профиле."))
                .font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
        }
    }
    private var server: some View {
        VStack(alignment: .leading, spacing: 16) {
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
            Text(tr("Недоступна в iOS: реализация не утверждена. Подключитесь к уже установленному серверу."))
                .font(MSTheme.font(13)).foregroundStyle(MSTheme.muted).accessibilityIdentifier("sshUnavailable")
            Button(tr("Установить сервер")) {}.buttonStyle(MSButtonStyle(primary: false)).disabled(!IOSFeatureAvailability.sshInstallationEnabled)
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
