import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

struct DeleteAccountView: View {
    @Bindable var identity: IdentityModel
    let account: AccountRecord
    @State private var password = ""
    @State private var pendingPassword: String?
    @FocusState private var passwordFocused: Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(account.user.email)
                    Text(account.server.displayName).foregroundStyle(.secondary)
                    Text(tr("Удаление аккаунта необратимо. Сервер удалит данные входа и личные настройки. Общая история переписки может сохраниться с анонимным автором."))
                    Text(tr("Перед удалением завершите звонки, закройте свои встречи и передайте владение групповыми чатами."))
                }
                Section {
                    SecureField(tr("Пароль аккаунта"), text: $password)
                        .textContentType(.password).focused($passwordFocused).submitLabel(.done)
                        .onSubmit { passwordFocused = false }.accessibilityIdentifier("deleteAccount.password")
                    Button(tr("Удалить аккаунт на сервере"), role: .destructive) {
                        // The confirmation owns the submitted value, independent of subsequent
                        // SecureField/Form presentation and focus changes.
                        pendingPassword = password; passwordFocused = false
                    }.disabled(password.isEmpty || identity.busy).accessibilityIdentifier("deleteAccount.submit")
                }
                if let error = identity.error {
                    Text(tr(error)).foregroundStyle(MSTheme.danger).accessibilityIdentifier("deleteAccount.error")
                }
                if identity.busy { ProgressView() }
            }.scrollDismissesKeyboard(.interactively)
                .navigationTitle(tr("Удаление аккаунта")).msInlineTitle()
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tr("Отмена")) { dismiss() }.disabled(identity.busy) } }
                .disabled(identity.busy).interactiveDismissDisabled(identity.busy)
                .confirmationDialog(tr("Удалить этот аккаунт на сервере без возможности восстановления?"),
                    isPresented: Binding(get: { pendingPassword != nil }, set: { if !$0 { pendingPassword = nil } }),
                    titleVisibility: .visible, presenting: pendingPassword) { supplied in
                    Button(tr("Удалить навсегда"), role: .destructive) {
                        password = ""; pendingPassword = nil
                        Task { if await identity.deleteAccount(account, password: supplied) { dismiss() } }
                    }.accessibilityIdentifier("deleteAccount.confirm")
                    Button(tr("Отмена"), role: .cancel) { pendingPassword = nil }
                        .accessibilityIdentifier("deleteAccount.cancelConfirmation")
                }
        }.onDisappear { password = ""; pendingPassword = nil }
    }
}
