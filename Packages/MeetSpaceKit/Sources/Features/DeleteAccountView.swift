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
                        #if DEBUG
                        .onChange(of: password) { _, value in traceFixtureInput("edit", value) }
                        #endif
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
        if value == "<redacted>" { return "literal-redacted" }
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
        for (fixture, label) in fixtures {
            if value == fixture.replacingOccurrences(of: "-", with: "") { return label + "-minus-hyphen" }
            if value == fixture + fixture { return label + "-repeated" }
            for index in fixture.indices {
                var removed = fixture; removed.remove(at: index)
                if value == removed { return label + "-single-deletion" }
            }
            if value.count == fixture.count, zip(value, fixture).filter({ $0 != $1 }).count == 1 {
                return label + "-single-replacement"
            }
            if value.count == fixture.count + 1 {
                for index in value.indices {
                    var removed = value; removed.remove(at: index)
                    if removed == fixture { return label + "-single-insertion" }
                }
            }
        }
        if value == "incorrect-passwordfixture-password" || value == "fixture-passwordincorrect-password" { return "appended-known-inputs" }
        for (fixture, label) in fixtures {
            if fixture.hasPrefix(value) { return label + "-prefix" }
        }
        if fixtures.contains(where: { $0.0.hasSuffix(value) }) { return "known-suffix" }
        if fixtures.contains(where: { isSubsequence(value, of: $0.0) }) { return "known-dropped-characters" }
        if value.allSatisfy({ $0 == "*" || $0 == "•" }) { return "mask-characters-only" }
        if value.allSatisfy(\.isWhitespace) { return "whitespace-only" }
        let letters = value.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        if !letters.isEmpty, letters.allSatisfy({ (0x0400...0x052F).contains($0.value) || (0x2DE0...0x2DFF).contains($0.value) || (0xA640...0xA69F).contains($0.value) }) {
            return "cyrillic-letters-only"
        }
        if value.contains("\n") || value.contains("\r") { return "other-with-linebreak" }
        if value.unicodeScalars.allSatisfy({ $0.isASCII }) { return "ascii-other" }
        return "unicode-other"
    }

    private static func isSubsequence(_ value: String, of fixture: String) -> Bool {
        var cursor = value.startIndex
        for character in fixture where cursor != value.endIndex {
            if value[cursor] == character { cursor = value.index(after: cursor) }
        }
        return cursor == value.endIndex
    }
}
#endif
