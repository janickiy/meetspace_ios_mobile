import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

@MainActor @Observable final class DemoAccounts {
    private(set) var profiles: [DemoAccountProfile]
    private(set) var current: DemoAccountProfile

    init(server: ServerOrigin? = nil) {
        let personal = DemoAccountProfile(id: "personal", name: "Александр Соколов", email: "alex@example.org", server: server ?? (try? ServerOrigin("https://meet.example.org")))
        let studio = DemoAccountProfile(id: "studio", name: "Александр · Студия", email: "alex@studio.example.org", server: try? ServerOrigin("https://team.example.org"))
        profiles = [personal, studio]
        current = personal
    }

    func select(_ id: String) {
        if let profile = profiles.first(where: { $0.id == id }) { current = profile }
    }

    func add(name: String, email: String, server: ServerOrigin) {
        if let existing = profiles.first(where: { $0.email == email && $0.server == server }) {
            current = existing
        } else {
            let profile = DemoAccountProfile(id: UUID().uuidString, name: name, email: email, server: server)
            profiles.append(profile)
            current = profile
        }
    }

    func removeCurrent() -> Bool {
        profiles.removeAll { $0.id == current.id }
        guard let next = profiles.first else { return false }
        current = next
        return true
    }
}

struct DemoAddAccountView: View {
    let accounts: DemoAccounts
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var email = ""
    @State private var server = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(tr("Имя для встреч"), text: $name)
                    TextField(tr("Электронная почта"), text: $email).msEmailInput()
                    TextField(tr("Адрес сервера"), text: $server).msURLInput()
                } footer: { Text(tr("Демо-аккаунт доступен до выхода из демонстрационного режима.")) }
                Button(tr("Добавить аккаунт")) {
                    guard let name = try? ProfileValidation.displayName(name), let email = try? AccountValidation.email(email),
                          let server = try? ServerOrigin(server) else { return }
                    accounts.add(name: name, email: email, server: server)
                    dismiss()
                }.disabled((try? ProfileValidation.displayName(name)) == nil || (try? AccountValidation.email(email)) == nil || (try? ServerOrigin(server)) == nil)
            }.navigationTitle(tr("Добавить аккаунт")).msInlineTitle()
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tr("Отмена")) { dismiss() } } }
        }.onAppear { server = accounts.current.server?.url.absoluteString ?? "https://meet.example.org" }
    }
}
