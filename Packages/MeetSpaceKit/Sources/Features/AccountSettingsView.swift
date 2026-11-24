import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

enum AccountSettingsSection {
    case profile, audio
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
            }.modifier(AccountPanelLayout(wide: wide))
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
