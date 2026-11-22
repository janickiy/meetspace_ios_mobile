import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

struct ProfileView: View {
    @Bindable var model: AppModel
    var body: some View {
        AccountHome(name: model.demoProfile.name, email: "alex@example.org", server: model.configuration.server?.displayName ?? "meet.example.org",
                    demo: true, photo: model.demoProfile.photo, logout: { model.leaveDemo() }) { section, wide in
            switch section {
            case .profile: DemoProfileEditor(profile: model.demoProfile, wide: wide)
            case .accounts: SettingsDetailView(model: model, route: .accounts)
            case .audio: ScrollView { AccountAudioSettingsView(wide: wide).padding(20) }
            case .video: SettingsDetailView(model: model, route: .videoSettings)
            case .notifications: SettingsDetailView(model: model, route: .notificationSettings)
            case .appearance: SettingsDetailView(model: model, route: .appearance)
            case .connection: SettingsDetailView(model: model, route: .connection)
            }
        } extras: {
            VStack(alignment: .leading, spacing: 12) {
                Button { model.navigate(.interfaceCatalog) } label: {
                    Label(tr("Каталог экранов"), systemImage: "square.grid.2x2").frame(minHeight: 44)
                }
                Text(tr("Состояния интерфейса")).font(MSTheme.font(14, weight: .semibold))
                Picker(tr("Состояние"), selection: $model.contentState) {
                    Text(tr("Данные")).tag(LoadState.content)
                    Text(tr("Загрузка")).tag(LoadState.loading)
                    Text(tr("Пусто")).tag(LoadState.empty)
                    Text(tr("Ошибка")).tag(LoadState.failed)
                    Text(tr("Офлайн")).tag(LoadState.offline)
                }.accessibilityIdentifier("demoStatePicker")
            }
        }.toolbar(.hidden)
    }
}

private struct DemoProfileEditor: View {
    let profile: DemoAccountProfile
    let wide: Bool
    @State private var name = ""
    @State private var bio = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ProfileEditorHeading()
                ProfilePhotoCard(name: profile.name, photo: profile.photo, hasPhoto: profile.photo != nil) { profile.photo = $0; return true }
                ProfileField(label: "Имя для встреч", hint: "От 1 до 100 символов.") {
                    TextField(tr("Имя"), text: $name).textFieldStyle(.plain).profileInput()
                }
                ProfileField(label: "О себе") {
                    TextField(tr("Расскажите о себе"), text: $bio, axis: .vertical).textFieldStyle(.plain).lineLimit(3...12)
                        .profileInput(multiline: true)
                }
                ProfileField(label: "Email", hint: "Адрес используется для входа. Изменение email недоступно.") {
                    Text(verbatim: "alex@example.org").profileInput(readOnly: true)
                }
                Button(tr("Сохранить профиль")) {
                    if let validName = try? ProfileValidation.displayName(name), let validBio = try? ProfileValidation.bio(bio) {
                        profile.name = validName; profile.bio = validBio
                    }
                }.buttonStyle(MSButtonStyle()).fixedSize(horizontal: true, vertical: false)
                    .disabled((try? ProfileValidation.displayName(name)) == nil ||
                        (try? ProfileValidation.bio(bio)) == nil || (profile.name == name && profile.bio == bio))
            }.padding(.horizontal, wide ? 48 : 20).padding(.vertical, wide ? 36 : 18)
                .frame(maxWidth: 860).frame(maxWidth: .infinity, alignment: .topLeading)
        }.background(MSTheme.background).onAppear { name = profile.name; bio = profile.bio }
    }
}

struct ProfileEditorHeading: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("Ваш профиль")).font(MSTheme.font(23, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Text(tr("Как вас видят участники встречи.")).font(MSTheme.font(13)).foregroundStyle(MSTheme.muted)
        }
    }
}

struct ProfileField<Content: View>: View {
    let label: String
    var hint: String?
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr(label)).font(MSTheme.font(14, weight: .semibold))
            content()
            if let hint { Text(tr(hint)).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted) }
        }
    }
}

extension View {
    func profileInput(multiline: Bool = false, readOnly: Bool = false) -> some View {
        self.font(MSTheme.font(14)).padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: multiline ? 94 : 50, alignment: multiline ? .topLeading : .leading)
            .foregroundStyle(readOnly ? MSTheme.muted : MSTheme.ink)
            .background(readOnly ? MSTheme.background : MSTheme.surface, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(MSTheme.muted.opacity(0.58)))
    }
}

struct SettingsDetailView: View {
    @Bindable var model: AppModel
    let route: AppRoute
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                switch route {
                case .appearance:
                    VStack(alignment: .leading, spacing: 18) {
                        Text(tr("Тема приложения")).font(MSTheme.font(19, weight: .semibold, relativeTo: .title2))
                            .accessibilityAddTraits(.isHeader)
                        if typeSize.isAccessibilitySize {
                            // Segmented controls do not grow with accessibility text sizes.
                            VStack(spacing: 12) {
                                appearanceOption(.system, title: "Системная")
                                appearanceOption(.light, title: "Светлая")
                                appearanceOption(.dark, title: "Тёмная")
                            }
                        } else {
                            Picker(tr("Тема приложения"), selection: Binding(get: { model.configuration.appearance }, set: { value in model.setAppearance(value) })) {
                                Text(tr("Системная")).tag(Appearance.system)
                                Text(tr("Светлая")).tag(Appearance.light)
                                Text(tr("Тёмная")).tag(Appearance.dark)
                            }.pickerStyle(.segmented).accessibilityIdentifier("appearancePicker")
                        }
                        Text(tr("Размер текста определяется настройками устройства.")).foregroundStyle(MSTheme.muted)
                    }.msCard()
                case .connection:
                    Label(model.configuration.server?.url.absoluteString ?? tr("Сервер не выбран"), systemImage: "lock.shield").msCard()
                    Button(tr("Подключиться к серверу")) { model.leaveDemo(); model.show(.connect) }.buttonStyle(MSButtonStyle())
                case .accounts:
                    HStack { Avatar("АС"); Text(tr("Демо-профиль")); Spacer(); Image(systemName: "checkmark.circle.fill").foregroundStyle(MSTheme.accent) }.msCard()
                    FeatureNotice("Добавление аккаунтов станет доступно после подключения авторизации.")
                case .audioSettings:
                    settingPreview("Микрофон", "mic", "Устройство по умолчанию")
                    settingPreview("Динамики", "speaker.wave.2", "Устройство по умолчанию")
                    FeatureNotice("Медиа-устройства будут подключены на этапе звонков. Разрешения пока не запрашиваются.")
                case .videoSettings:
                    RoundedRectangle(cornerRadius: 16).fill(MSTheme.surfaceSecondary).aspectRatio(16 / 9, contentMode: .fit)
                        .overlay { Label(tr("Камера выключена"), systemImage: "video.slash") }
                    settingPreview("Камера", "video", "Устройство по умолчанию")
                    FeatureNotice("Медиа-устройства будут подключены на этапе звонков. Разрешения пока не запрашиваются.")
                default:
                    settingPreview("Уведомления", "bell", "Не подключены")
                    FeatureNotice("Push-уведомления требуют отдельной интеграции APNs и проверки на устройстве.")
                }
            }.padding(24).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }.background(MSTheme.background).navigationTitle(tr(route.title)).msInlineTitle()
    }
    private func settingPreview(_ title: String, _ icon: String, _ value: String) -> some View {
        HStack { Label(tr(title), systemImage: icon); Spacer(); Text(tr(value)).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted) }.msCard()
    }
    private func appearanceOption(_ value: Appearance, title: String) -> some View {
        Button { model.setAppearance(value) } label: {
            HStack(spacing: 12) {
                Text(tr(title)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: model.configuration.appearance == value ? "checkmark.circle.fill" : "circle")
                    .accessibilityHidden(true)
            }.padding(.vertical, 10).frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(MSTheme.accent)
            .accessibilityIdentifier("appearance.\(value.rawValue)")
            .accessibilityAddTraits(model.configuration.appearance == value ? .isSelected : [])
    }
}
