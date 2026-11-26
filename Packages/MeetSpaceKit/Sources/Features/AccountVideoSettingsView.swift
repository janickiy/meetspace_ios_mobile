import SwiftUI
import AVFoundation
import MeetSpaceCore
import MeetSpaceDesignSystem
#if os(iOS)
import UIKit
#endif

enum AccountCameraChoice: String, Codable, CaseIterable {
    case automatic, front, back

    var title: String {
        switch self {
        case .automatic: "По умолчанию"
        case .front: "Фронтальная камера"
        case .back: "Основная камера"
        }
    }
}

struct AccountVideoPreferences: Codable, Equatable {
    var camera: AccountCameraChoice = .automatic
    var cameraOff = true
    var selfVideo = true
    var hideVideo = false

    /// Формирует ключ локального хранения настроек видео для аккаунта или деморежима.
    /// - Parameter account: Ключ аккаунта или nil для деморежима.
    private static func storageKey(_ account: CredentialKey?) -> String {
        "meetspace.video.v1." + (account?.storageKey ?? "demo")
    }

    /// Читает настройки камеры из хранилища и возвращает стандартные значения при отсутствии пригодной записи.
    /// - Parameters:
    ///   - account: Ключ аккаунта или nil для деморежима.
    ///   - defaults: Хранилище настроек видео.
    static func load(for account: CredentialKey?, defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: storageKey(account)),
              let value = try? JSONDecoder().decode(Self.self, from: data) else {
            // An existing live account keeps its camera off until the user chooses otherwise.
            return Self(cameraOff: account != nil)
        }
        return value
    }

    /// Записывает текущие настройки камеры для выбранного аккаунта.
    /// - Parameters:
    ///   - account: Ключ аккаунта или nil для деморежима.
    ///   - defaults: Хранилище настроек видео.
    func save(for account: CredentialKey?, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.storageKey(account))
        }
    }
}

struct AccountVideoSettingsView: View {
    let account: CredentialKey?
    let wide: Bool
    @State private var preferences: AccountVideoPreferences
    @State private var permission = AVCaptureDevice.authorizationStatus(for: .video)
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.workspaceWidth) private var width

    /// Загружает настройки аккаунта для отображения на экране видео.
    /// - Parameters:
    ///   - account: Ключ аккаунта или nil для деморежима.
    ///   - wide: Использовать ли компоновку для широкого экрана.
    init(account: CredentialKey?, wide: Bool) {
        self.account = account
        self.wide = wide
        _preferences = State(initialValue: AccountVideoPreferences.load(for: account))
    }

    private var split: Bool { wide && width >= 1100 && !typeSize.isAccessibilitySize }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AccountDetailHeading(title: "Видео", subtitle: "Предпросмотр доступен только вам.")
                .padding(.bottom, wide ? 32 : 30)
            let layout = split ? AnyLayout(HStackLayout(alignment: .top, spacing: 24)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 24))
            layout {
                VStack(alignment: .leading, spacing: split ? 18 : 20) {
                    preview
                    cameraSelector
                }.frame(maxWidth: .infinity)
                options.frame(maxWidth: .infinity)
            }
            if account != nil && (permission == .denied || permission == .restricted) {
                HStack {
                    Text(tr("Доступ к камере отключён"))
                    #if os(iOS)
                    if permission == .denied, let url = URL(string: UIApplication.openSettingsURLString) {
                        Spacer()
                        Link(tr("Открыть настройки"), destination: url).frame(minHeight: 44)
                    }
                    #endif
                }.font(MSTheme.font(12)).foregroundStyle(MSTheme.muted).padding(.top, 16)
            }
            Rectangle().fill(MSTheme.line).frame(height: 1).padding(.top, 24).accessibilityHidden(true)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(MSTheme.ink)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { permission = AVCaptureDevice.authorizationStatus(for: .video) }
            }
    }

    private var preview: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color(red: 36 / 255, green: 33 / 255, blue: 39 / 255))
            .aspectRatio(16.0 / 9, contentMode: .fit)
            .overlay {
                VStack(spacing: 12) {
                    WorkspaceIcon("video.slash", size: 32)
                    Text(tr("Предпросмотр камеры")).font(MSTheme.font(12.6))
                }.foregroundStyle(Color(white: 0.95)).padding(.horizontal, 16)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tr("Предпросмотр камеры"))
            .accessibilityAddTraits(.isImage)
            .accessibilityIdentifier("video.preview")
    }

    private var cameraSelector: some View {
        let inline = wide && !split && !typeSize.isAccessibilitySize
        let layout = inline ? AnyLayout(HStackLayout(spacing: 18)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
        return layout {
            Text(tr("Камера")).font(MSTheme.font(14, weight: .medium))
                .frame(maxWidth: inline ? .infinity : nil, alignment: .leading)
            Menu {
                Picker(tr("Камера"), selection: setting(\.camera)) {
                    ForEach(AccountCameraChoice.allCases, id: \.self) { choice in
                        Text(tr(choice.title)).tag(choice)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(tr(preferences.camera.title)).font(MSTheme.font(14))
                    Spacer(minLength: 0)
                    WorkspaceIcon("chevron.down", size: 14)
                }.padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(MSTheme.surface, in: RoundedRectangle(cornerRadius: wide ? 10 : 12))
                    .overlay { RoundedRectangle(cornerRadius: wide ? 10 : 12).strokeBorder(MSTheme.muted.opacity(0.62)) }
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).menuIndicator(.hidden)
                .accessibilityLabel(tr("Камера")).accessibilityValue(tr(preferences.camera.title))
                .accessibilityIdentifier("video.camera")
                .layoutPriority(inline ? 1 : 0)
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: split ? 24 : 20) {
            option("Подключаться с выключенной камерой", setting: \.cameraOff, id: "video.cameraOff")
            option("Видеть себя на звонке", hint: "Ваше видео или аватар", setting: \.selfVideo, id: "video.selfVideo")
            option("Скрыть видео участников", hint: "Снижает нагрузку на сеть. Звук сохраняется; видео и экраны скрываются.",
                   setting: \.hideVideo, id: "video.hideVideo")
        }.toggleStyle(AccountSwitchStyle())
    }

    /// Создаёт переключатель выбранной настройки видео.
    /// - Parameters:
    ///   - title: Подпись настройки.
    ///   - hint: Пояснение под подписью.
    ///   - key: Путь к логическому свойству настроек.
    ///   - id: Идентификатор элемента для тестов интерфейса и средств доступности.
    private func option(_ title: String, hint: String? = nil, setting key: WritableKeyPath<AccountVideoPreferences, Bool>, id: String) -> some View {
        Toggle(isOn: setting(key)) {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr(title)).font(MSTheme.font(13.4))
                if let hint {
                    Text(tr(hint)).font(MSTheme.font(11.5)).lineSpacing(3).foregroundStyle(MSTheme.muted)
                }
            }
        }.accessibilityIdentifier(id)
    }

    /// Создаёт привязку, сохраняющую изменённую настройку видео.
    /// - Parameter key: Путь к свойству, которое редактирует элемент управления.
    private func setting<T>(_ key: WritableKeyPath<AccountVideoPreferences, T>) -> Binding<T> {
        Binding {
            preferences[keyPath: key]
        } set: { newValue in
            preferences[keyPath: key] = newValue
            preferences.save(for: account)
        }
    }
}
