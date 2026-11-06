import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

struct DeleteAccountView: View {
    @Bindable var identity: IdentityModel
    let account: AccountRecord
    @State private var password = ""
    @State private var confirming = false
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
                        passwordFocused = false; confirming = true
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
                .confirmationDialog(tr("Удалить этот аккаунт на сервере без возможности восстановления?"), isPresented: $confirming, titleVisibility: .visible) {
                    Button(tr("Удалить навсегда"), role: .destructive) {
                        let supplied = password; password = ""
                        Task { if await identity.deleteAccount(account, password: supplied) { dismiss() } }
                    }.accessibilityIdentifier("deleteAccount.confirm")
                }
                .onDisappear { password = "" }
        }
    }
}
