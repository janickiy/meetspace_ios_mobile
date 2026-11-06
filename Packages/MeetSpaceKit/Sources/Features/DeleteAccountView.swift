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
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .onSubmit {
                            #if DEBUG
                            traceFixtureInput("submit", password)
                            #endif
                            passwordFocused = false
                        }.accessibilityIdentifier("deleteAccount.password")
                    Button(tr("Удалить аккаунт на сервере"), role: .destructive) {
                        // The confirmation owns the submitted value, independent of subsequent
                        // SecureField/Form presentation and focus changes.
                        #if DEBUG
                        traceFixtureInput("prepare", password)
                        #endif
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
                .alert(tr("Удалить этот аккаунт на сервере без возможности восстановления?"),
                    isPresented: Binding(get: { pendingPassword != nil }, set: { if !$0 { pendingPassword = nil } }),
                    presenting: pendingPassword) { supplied in
                    Button(tr("Удалить навсегда"), role: .destructive) {
                        #if DEBUG
                        traceFixtureInput("confirm", supplied)
                        #endif
                        password = ""; pendingPassword = nil
                        Task { if await identity.deleteAccount(account, password: supplied) { dismiss() } }
                    }.accessibilityIdentifier("deleteAccount.confirm")
                    Button(tr("Отмена"), role: .cancel) { pendingPassword = nil }
                        .accessibilityIdentifier("deleteAccount.cancelConfirmation")
                }
        }.onDisappear { password = ""; pendingPassword = nil }
    }

    #if DEBUG
    // Only synthetic UI-test input is classified. Never log a password, length, or hash.
    private func traceFixtureInput(_ stage: String, _ value: String) {
        guard ProcessInfo.processInfo.arguments.contains("-uitesting") else { return }
        NSLog("MeetSpaceDeletionDiagnostic stage=%@ input=%@", stage, UITestPasswordInputClassification.classify(value))
    }
    #endif
}

#if DEBUG
/// Describes only how synthetic UI-test values differ from the two known fixtures.
/// No contents, character counts, hashes, or input transformations leave this helper.
public enum UITestPasswordInputClassification {
    public static func classify(_ value: String?) -> String {
        guard let value else { return "missing" }
        guard !value.isEmpty else { return "empty" }
        let fixtures = [("fixture-password", "expected"), ("incorrect-password", "rejected")]
        for (fixture, label) in fixtures {
            if value == fixture { return label }
            if value == fixture + "\n" { return label + "-lf" }
            if value == fixture + "\r" { return label + "-cr" }
            if value == fixture + "\r\n" { return label + "-crlf" }
            if value.trimmingCharacters(in: .whitespacesAndNewlines) == fixture { return label + "-whitespace" }
            if value == fixture.uppercased() { return label + "-uppercase" }
            if value.caseInsensitiveCompare(fixture) == .orderedSame { return label + "-case" }
            for (dash, name) in [("\u{2010}", "hyphen"), ("\u{2011}", "nonbreaking-hyphen"),
                                 ("\u{2013}", "en-dash"), ("\u{2014}", "em-dash"), ("\u{2212}", "minus")] {
                if value == fixture.replacingOccurrences(of: "-", with: dash) { return label + "-" + name }
            }
        }
        if value == "incorrect-passwordfixture-password" { return "appended-input" }
        if value.allSatisfy(\.isWhitespace) { return "whitespace-only" }
        let letters = value.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        if !letters.isEmpty, letters.allSatisfy({ (0x0400...0x052F).contains($0.value) || (0x2DE0...0x2DFF).contains($0.value) || (0xA640...0xA69F).contains($0.value) }) {
            return "cyrillic-letters-only"
        }
        if value.contains("\n") || value.contains("\r") { return "other-with-linebreak" }
        if value.unicodeScalars.allSatisfy({ $0.isASCII }) { return "ascii-other" }
        return "unicode-other"
    }
}
#endif
