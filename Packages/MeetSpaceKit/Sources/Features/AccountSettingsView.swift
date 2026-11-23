import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

enum AccountSettingsSection: String, CaseIterable, Identifiable {
    case profile = "Профиль", audio = "Аудио", notifications = "Уведомления аккаунта", devices = "Устройства уведомлений", server = "Возможности сервера"
    var id: Self { self }
    var icon: String {
        switch self {
        case .profile: "person.crop.circle"
        case .audio: "mic"
        case .notifications: "bell"
        case .devices: "iphone.and.arrow.forward"
        case .server: "server.rack"
        }
    }
    var hint: String {
        switch self {
        case .profile: ProfileSection.profile.label.hint
        case .audio: ProfileSection.audio.label.hint
        case .notifications: ProfileSection.notifications.label.hint
        case .devices: "Доставка на этот iPhone и другие устройства"
        case .server: "Версия и доступные функции"
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
                HStack(alignment: .top, spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 12) {
                                ProfileAvatar(name: model.profile.name, size: 42, cornerRadius: 14, photo: model.photo)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(model.profile.name).font(MSTheme.font(13, weight: .semibold))
                                    Text(model.profile.email).font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
                                        .accessibilityLabel(tr("Электронная почта")).accessibilityValue(model.profile.email)
                                }.fixedSize(horizontal: false, vertical: true)
                            }.padding(.bottom, 20)
                            ForEach(AccountSettingsSection.allCases) { section in
                                Button { selection = section } label: {
                                    sectionRow(section, wide: true, selected: selection == section)
                                }.buttonStyle(.plain).accessibilityLabel(tr(section.rawValue))
                                    .accessibilityAddTraits(selection == section ? .isSelected : [])
                                    .accessibilityIdentifier("settingsSection.\(section)")
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 22)
                    }.frame(width: geometry.size.width >= 1100 ? 270 : 240).background(MSTheme.surface)
                    Divider()
                    AccountSettingsContent(model: model, section: selection, wide: true)
                }.padding(.horizontal, 24)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(AccountSettingsSection.allCases) { section in
                            NavigationLink {
                                AccountSettingsContent(model: model, section: section)
                                    .navigationTitle(tr(section == .audio ? "Настройки аккаунта" : section.rawValue)).msInlineTitle()
                            } label: {
                                sectionRow(section, wide: false, selected: false)
                            }.buttonStyle(.plain).accessibilityLabel(tr(section.rawValue))
                                .accessibilityIdentifier("settingsSection.\(section)")
                        }
                    }.padding(.horizontal, 20).padding(.vertical, 24)
                }.background(MSTheme.surface)
            }
        }.background(MSTheme.background).navigationTitle(tr("Настройки аккаунта")).msInlineTitle()
            .task { await model.load() }
    }

    private func sectionRow(_ section: AccountSettingsSection, wide: Bool, selected: Bool) -> some View {
        HStack(spacing: 13) {
            Image(systemName: section.icon).font(.system(size: wide ? 18 : 20))
                .foregroundStyle(selected || !wide ? MSTheme.accent : MSTheme.muted)
                .frame(width: wide ? 25 : 40, height: wide ? 28 : 40)
                .background(wide ? .clear : MSTheme.accentSoft, in: RoundedRectangle(cornerRadius: 13))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(tr(section.rawValue)).font(MSTheme.font(wide ? 13 : 15, weight: .semibold))
                if !wide { Text(tr(section.hint)).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted) }
            }.fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 1)
            if !wide {
                Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(MSTheme.muted)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(selected ? MSTheme.accent : MSTheme.ink)
        .padding(.vertical, wide ? 8 : 12).padding(.horizontal, wide ? 10 : 0)
        .frame(minHeight: wide ? 48 : 64)
        .background(selected ? MSTheme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .bottom) { if !wide { Rectangle().fill(MSTheme.line).frame(height: 1) } }
        .contentShape(Rectangle())
    }
}

struct AccountSettingsContent: View {
    @Bindable var model: SettingsModel
    let section: AccountSettingsSection
    var wide = false
    @FocusState private var profileNameFocused: Bool
    @State private var nativeProfileNameFocused = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if section == .devices || section == .server {
                    Text(tr(section.rawValue)).font(MSTheme.font(21, weight: .semibold, relativeTo: .title2))
                        .accessibilityAddTraits(.isHeader)
                }
                switch section {
                case .profile: profile
                case .audio: AccountAudioSettingsView(wide: wide)
                case .notifications: preferences
                case .devices: devices
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
            Text(tr("Доставка зависит от настройки провайдера на сервере. Разрешение уведомлений этого iPhone или iPad включается отдельно в профиле."))
                .font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
        }.toggleStyle(AccountSwitchStyle())
    }
    private func preferenceHeading(_ title: String) -> some View {
        Text(tr(title)).font(MSTheme.font(15, weight: .semibold)).padding(.bottom, 10)
            .accessibilityAddTraits(.isHeader)
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
