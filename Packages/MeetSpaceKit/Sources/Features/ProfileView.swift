import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

struct ProfileView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Профиль") { EmptyView() }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 16) {
                        Avatar("АС", size: 64)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(tr("Александр Соколов")).font(MSTheme.font(19, weight: .semibold, relativeTo: .title2))
                            Text("alex@meetspace.example").font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
                            Text(tr("Демо-профиль")).font(MSTheme.font(11)).foregroundStyle(MSTheme.accent)
                        }
                    }.msCard()
                    VStack(spacing: 0) {
                        row("Аудио", "mic", .audioSettings)
                        row("Видео", "video", .videoSettings)
                        row("Уведомления", "bell", .notificationSettings)
                        row("Оформление", "paintpalette", .appearance)
                    }.msCard(padding: 4)
                    VStack(spacing: 0) {
                        row("Подключение", "network", .connection)
                        row("Аккаунты", "person.2", .accounts)
                        row("Каталог экранов", "square.grid.2x2", .interfaceCatalog)
                    }.msCard(padding: 4)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(tr("Состояния интерфейса")).font(MSTheme.font(14, weight: .semibold))
                        Text(tr("Применяется к спискам встреч и сообщений в демо.")).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
                        Picker(tr("Состояние"), selection: $model.contentState) {
                            Text(tr("Данные")).tag(LoadState.content)
                            Text(tr("Загрузка")).tag(LoadState.loading)
                            Text(tr("Пусто")).tag(LoadState.empty)
                            Text(tr("Ошибка")).tag(LoadState.failed)
                            Text(tr("Офлайн")).tag(LoadState.offline)
                        }.accessibilityIdentifier("demoStatePicker")
                    }.msCard()
                    Button(tr("Выйти из демо")) { model.leaveDemo() }.buttonStyle(MSButtonStyle(primary: false))
                }.padding(20).frame(maxWidth: 720).frame(maxWidth: .infinity)
            }
        }.background(MSTheme.background).toolbar(.hidden).accessibilityIdentifier("screen.profile")
    }
    private func row(_ title: String, _ icon: String, _ route: AppRoute) -> some View {
        Button { model.navigate(route) } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).foregroundStyle(MSTheme.accent).frame(width: 24)
                Text(tr(title)); Spacer(); Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(MSTheme.muted)
            }.padding(14).frame(minHeight: 48)
        }.buttonStyle(.plain)
    }
}

struct SettingsDetailView: View {
    @Bindable var model: AppModel
    let route: AppRoute
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                switch route {
                case .appearance:
                    VStack(alignment: .leading, spacing: 18) {
                        Text(tr("Тема приложения")).font(MSTheme.font(19, weight: .semibold))
                        Picker(tr("Тема приложения"), selection: Binding(get: { model.configuration.appearance }, set: model.setAppearance)) {
                            Text(tr("Системная")).tag(Appearance.system)
                            Text(tr("Светлая")).tag(Appearance.light)
                            Text(tr("Тёмная")).tag(Appearance.dark)
                        }.pickerStyle(.segmented).accessibilityIdentifier("appearancePicker")
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
}
