import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

struct AccountListItem: Identifiable {
    let id: String
    let name: String
    let email: String
    let server: String
    let photo: Data?
}

struct AccountListPanel: View {
    let items: [AccountListItem]
    let currentID: String
    let wide: Bool
    let select: (AccountListItem) -> Void
    let add: () -> Void
    let delete: (AccountListItem) -> Void
    var logout: ((AccountListItem) -> Void)?
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 15) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(tr("ВАШИ ПРОСТРАНСТВА"))
                        .font(MSTheme.font(9, weight: .semibold, relativeTo: .caption))
                        .tracking(1.5).foregroundStyle(MSTheme.muted).padding(.bottom, 10)
                    Text(tr("Аккаунты")).font(MSTheme.font(wide ? 23 : 21, weight: .semibold, relativeTo: .title2))
                        .tracking(-0.5).accessibilityAddTraits(.isHeader).padding(.bottom, 8)
                    Text(tr("Выберите аккаунт для встреч и общения."))
                        .font(MSTheme.font(13)).lineSpacing(4).foregroundStyle(MSTheme.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text(String(items.count)).font(MSTheme.font(16, weight: .semibold))
                    .padding(6).frame(minWidth: 42, minHeight: 42)
                    .foregroundStyle(MSTheme.accent).background(MSTheme.accentSoft, in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityLabel(tr("Количество аккаунтов")).accessibilityValue(String(items.count))
                    .accessibilityIdentifier("accounts.count")
            }.padding(.bottom, wide ? 32 : 30)

            VStack(spacing: 12) {
                ForEach(items) { item in card(item) }
            }
            Button(action: add) {
                HStack(spacing: 9) {
                    WorkspaceIcon("plus", size: 18)
                    Text(tr("Добавить аккаунт"))
                }.frame(maxWidth: wide ? nil : .infinity, minHeight: 32)
            }.buttonStyle(MSButtonStyle()).fixedSize(horizontal: wide, vertical: false).accessibilityIdentifier("addAccount").padding(.top, 18)

            HStack(alignment: .top, spacing: 9) {
                WorkspaceIcon("info.circle", size: 16).padding(.top, 2)
                Text(tr("Можно добавить аккаунты с одного или разных серверов. Настройки сохраняются отдельно для каждого аккаунта."))
                    .font(MSTheme.font(11.5)).lineSpacing(4)
            }.foregroundStyle(MSTheme.muted).padding(.top, 24)

            if let current = items.first(where: { $0.id == currentID }) {
                Divider().overlay(MSTheme.line).padding(.top, 30).padding(.bottom, 22)
                HStack(alignment: .top, spacing: wide ? 14 : 10) {
                    WorkspaceIcon("trash", size: 18)
                        .foregroundStyle(MSTheme.danger).frame(width: 35, height: 35)
                        .background(MSTheme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 7) {
                        Text(tr("Удаление аккаунта")).font(MSTheme.font(14, weight: .semibold)).accessibilityAddTraits(.isHeader)
                        Text(verbatim: String(format: tr("Удалить %@ с сервера %@."), current.email, current.server))
                            .font(MSTheme.font(12)).lineSpacing(4).foregroundStyle(MSTheme.muted)
                            .accessibilityIdentifier("accounts.deleteSummary")
                        Button { delete(current) } label: {
                            HStack(spacing: 7) {
                                Text(tr("Удалить аккаунт с сервера")).font(MSTheme.font(12))
                                WorkspaceIcon("arrow.up.right", size: 14)
                            }.frame(minHeight: 46).contentShape(Rectangle())
                        }.buttonStyle(.plain).foregroundStyle(MSTheme.danger)
                            .accessibilityIdentifier("openDeleteAccount")
                    }
                }
            }
        }.fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(MSTheme.ink).padding(.horizontal, wide ? 48 : 20)
            .padding(.top, wide ? 36 : 18).padding(.bottom, wide ? 42 : 30)
            .frame(maxWidth: 860, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func card(_ item: AccountListItem) -> some View {
        let current = item.id == currentID
        let shape = RoundedRectangle(cornerRadius: wide ? 18 : 15)
        let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) :
            AnyLayout(HStackLayout(spacing: wide ? 14 : 10))
        let button = Button {
            if !current { select(item) }
        } label: {
            layout {
                ProfileAvatar(name: item.name, size: wide ? 54 : 42, height: wide ? 54 : 46, cornerRadius: wide ? 18 : 14, photo: item.photo)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: item.name).font(MSTheme.font(wide ? 14 : 13, weight: .semibold))
                        .foregroundStyle(MSTheme.ink).padding(.bottom, 3)
                    Text(verbatim: item.email).font(MSTheme.font(wide ? 12 : 11.5)).padding(.bottom, 8)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        WorkspaceIcon("server.rack", size: 13)
                        Text(verbatim: item.server).font(MSTheme.font(11))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(MSTheme.muted)
                VStack(spacing: 6) {
                    WorkspaceIcon(current ? "checkmark.circle" : "arrow.right", size: 21)
                    Text(tr(current ? "Текущий" : "Выбрать")).font(MSTheme.font(wide ? 10 : 9, relativeTo: .caption))
                }.foregroundStyle(current ? MSTheme.accent : MSTheme.muted)
            }.multilineTextAlignment(.leading).padding(.horizontal, wide ? 18 : 12)
                .padding(.vertical, wide ? 18 : 14).frame(maxWidth: .infinity, minHeight: wide ? 96 : 92)
                .background { shape.fill(MSTheme.surface).overlay { shape.fill(MSTheme.accentSoft.opacity(current ? 0.45 : 0)) } }
                .overlay { shape.strokeBorder(current ? MSTheme.accent : MSTheme.line).allowsHitTesting(false) }
                .contentShape(shape)
        }.buttonStyle(.plain)
            .accessibilityLabel([item.name, item.email, item.server].joined(separator: ", "))
            .accessibilityValue(tr(current ? "Текущий" : "Выбрать"))
            .accessibilityAddTraits(current ? .isSelected : [])
            .accessibilityIdentifier("accounts.row.\(item.id)")
        if let logout {
            button.contextMenu {
                Button(tr("Выйти из аккаунта"), systemImage: "rectangle.portrait.and.arrow.right") { logout(item) }
            }
        } else { button }
    }
}

struct AccountSwitcherView: View {
    let app: AppModel
    let wide: Bool
    @State private var logoutTarget: AccountRecord?
    @State private var deleteTarget: AccountRecord?
    @State private var addingDemo = false
    @State private var deletingDemo = false

    var body: some View {
        if app.isDemo {
            let accounts = app.demoAccounts
            AccountListPanel(items: accounts.profiles.map { profile in
                AccountListItem(id: profile.id, name: profile.name, email: profile.email,
                                server: host(profile.server ?? app.configuration.server), photo: profile.photo)
            }, currentID: accounts.current.id, wide: wide, select: { accounts.select($0.id) },
                             add: { addingDemo = true }, delete: { _ in deletingDemo = true })
                .sheet(isPresented: $addingDemo) {
                    DemoAddAccountView(accounts: accounts)
                }
                .alert(tr("Удалить демонстрационный аккаунт?"), isPresented: $deletingDemo) {
                    Button(tr("Отмена"), role: .cancel) {}
                    Button(tr("Удалить"), role: .destructive) {
                        if !accounts.removeCurrent() { app.leaveDemo() }
                    }
                } message: { Text(verbatim: accounts.current.email) }
        } else if let current = app.identity.messaging?.account {
            VStack(alignment: .leading, spacing: 0) {
                AccountListPanel(items: app.identity.index.accounts.map { account in
                    AccountListItem(id: account.id, name: account.user.name, email: account.user.email,
                                    server: host(account.server), photo: account.id == current.id ? app.identity.settings?.photo : nil)
                }, currentID: current.id, wide: wide, select: { item in
                    guard let record = record(item) else { return }
                    Task { await app.identity.switchAccount(record) }
                }, add: {
                    app.identity.error = nil; app.identity.information = nil
                    app.identity.addingAccount = true; app.show(.connect)
                }, delete: { item in
                    guard item.id == current.id else { return }
                    app.identity.error = nil; deleteTarget = current
                }, logout: { logoutTarget = record($0) })
                VStack(alignment: .leading, spacing: 8) {
                    if app.identity.busy { ProgressView() }
                    if let error = app.identity.error { Text(tr(error)).foregroundStyle(MSTheme.danger) }
                    if let information = app.identity.information { Text(tr(information)).foregroundStyle(MSTheme.muted) }
                }.padding(.horizontal, wide ? 48 : 20)
            }
            .disabled(app.identity.busy)
            .sheet(item: $deleteTarget) { account in DeleteAccountView(identity: app.identity, account: account) }
            .confirmationDialog(tr("Выйти из аккаунта на этом устройстве?"), isPresented: Binding(
                get: { logoutTarget != nil }, set: { if !$0 { logoutTarget = nil } }
            ), presenting: logoutTarget) { account in
                Button(tr("Выйти"), role: .destructive) { Task { await app.identity.logout(account) } }
            } message: { account in Text(verbatim: account.user.email) }
        }
    }

    private func record(_ item: AccountListItem) -> AccountRecord? {
        app.identity.index.accounts.first { $0.id == item.id }
    }

    private func host(_ server: ServerOrigin?) -> String {
        guard let server else { return "meet.example.org" }
        return server.displayName + (server.url.port.map { ":\($0)" } ?? "")
    }
}
