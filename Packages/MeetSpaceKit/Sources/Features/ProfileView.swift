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
            case .appearance: SettingsDetailView(model: model, route: .appearance, wide: wide)
            case .connection: SettingsDetailView(model: model, route: .connection)
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
        }.background(MSTheme.surface).onAppear { name = profile.name; bio = profile.bio }
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
    var wide = false
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                switch route {
                case .appearance:
                    VStack(alignment: .leading, spacing: 16) {
                        AccountDetailHeading(title: "Оформление", subtitle: "Настройте MeetSpace под себя.")
                            .padding(.bottom, 14)
                        Text(tr("Тема приложения")).font(MSTheme.font(15, weight: .semibold))
                            .accessibilityAddTraits(.isHeader)
                        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
                        layout {
                            appearanceOption(.light, title: "Светлая")
                            appearanceOption(.dark, title: "Тёмная")
                        }.frame(maxWidth: .infinity).accessibilityElement(children: .contain)
                            .accessibilityIdentifier("appearancePicker")
                        appearanceOption(.system, title: "Системная")
                        Text(tr("Размер текста определяется настройками устройства.")).font(MSTheme.font(12))
                            .foregroundStyle(MSTheme.muted)
                    }
                    if model.isDemo { demoTools }
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
            }.padding(.horizontal, wide ? 48 : 20).padding(.vertical, wide ? 36 : 18)
                .frame(maxWidth: 860).frame(maxWidth: .infinity, alignment: .topLeading)
        }.background(MSTheme.background).navigationTitle(tr(route.title)).msInlineTitle()
    }
    private var demoTools: some View {
        VStack(alignment: .leading, spacing: 12) {
            AccountShortcutRow(title: "Каталог экранов", symbol: "square.grid.2x2", identifier: "profileMenu.demoCatalog") {
                model.navigate(.interfaceCatalog)
            }.msCard(padding: 0)
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Состояния интерфейса")).font(MSTheme.font(13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                Picker(tr("Состояние"), selection: $model.contentState) {
                    Text(tr("Данные")).tag(LoadState.content)
                    Text(tr("Загрузка")).tag(LoadState.loading)
                    Text(tr("Пусто")).tag(LoadState.empty)
                    Text(tr("Ошибка")).tag(LoadState.failed)
                    Text(tr("Офлайн")).tag(LoadState.offline)
                }.frame(minHeight: 44).accessibilityIdentifier("demoStatePicker")
            }.frame(maxWidth: .infinity, alignment: .leading).msCard(padding: 14)
        }
    }

    private func settingPreview(_ title: String, _ icon: String, _ value: String) -> some View {
        HStack { Label(tr(title), systemImage: icon); Spacer(); Text(tr(value)).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted) }.msCard()
    }
    private func appearanceOption(_ value: Appearance, title: String) -> some View {
        let selected = model.configuration.appearance == value
        return Button { model.setAppearance(value) } label: {
            VStack(alignment: .leading, spacing: 8) {
                if !typeSize.isAccessibilitySize && value != .system {
                    themePreview(dark: value == .dark).accessibilityHidden(true)
                }
                HStack(spacing: 6) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 15)).foregroundStyle(selected ? MSTheme.accent : MSTheme.muted)
                        .accessibilityHidden(true)
                    Text(tr(title)).font(MSTheme.font(13)).fixedSize(horizontal: false, vertical: true)
                }.padding(.horizontal, 4)
            }.padding(8).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .foregroundStyle(MSTheme.ink)
                .background(selected ? MSTheme.accentSoft : MSTheme.surface, in: RoundedRectangle(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(selected ? MSTheme.accent : MSTheme.line))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityIdentifier("appearance.\(value.rawValue)")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func themePreview(dark: Bool) -> some View {
        let outline = previewColor(dark ? 0x494151 : 0xe8e5ee)
        return HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 5).fill(previewColor(dark ? 0x40354e : 0xe5dced))
                .frame(width: wide ? 44 : 28)
            VStack(alignment: .leading, spacing: 7) {
                RoundedRectangle(cornerRadius: 2).fill(previewColor(dark ? 0xb4a7c6 : 0x7b6b8e))
                    .frame(width: 28, height: 5)
                ForEach(0..<2) { _ in RoundedRectangle(cornerRadius: 4).strokeBorder(outline).frame(height: 18) }
                Spacer(minLength: 0)
            }.padding(7).frame(maxWidth: .infinity)
                .background(dark ? previewColor(0x302b39) : .white, in: RoundedRectangle(cornerRadius: 5))
        }.padding(9).frame(height: wide ? 132 : 94)
            .background(previewColor(dark ? 0x19171f : 0xf7f6fa), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(outline))
    }

    private func previewColor(_ rgb: UInt32) -> Color {
        Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255,
              blue: Double(rgb & 255) / 255)
    }
}
