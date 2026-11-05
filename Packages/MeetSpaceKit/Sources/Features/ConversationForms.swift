import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

struct NewConversationView: View {
    @Bindable var model: MessagingModel
    let open: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var group = false
    @State private var name = ""
    @State private var detail = ""
    @State private var selection: [Peer] = []
    @State private var choosing = false
    @State private var requestID = UUID()
    @State private var busy = false
    @State private var error: String?
    @State private var operation: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            Form {
                Toggle(tr("Групповой чат"), isOn: $group)
                if group {
                    TextField(tr("Название группы"), text: $name)
                    TextField(tr("Описание"), text: $detail, axis: .vertical)
                    Text(tr("Название: до 50 символов. Описание: до 200.")).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
                }
                Section(tr(group ? "Участники" : "Собеседник")) {
                    ForEach(selection) { peer in
                        HStack { Text(peer.displayName); Spacer(); Button(tr("Убрать")) { selection.removeAll { $0.id == peer.id } } }
                    }
                    Button(tr("Выбрать участников")) { choosing = true }
                }
                if let error { Text(tr(error)).foregroundStyle(MSTheme.danger) }
                if busy { ProgressView() }
                Button(tr(group ? "Создать группу" : "Открыть чат")) { create() }
                    .disabled(selection.isEmpty || (group && (name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.unicodeScalars.count > 50 || detail.unicodeScalars.count > 200)))
                    .accessibilityIdentifier("createConversation")
            }.disabled(busy).navigationTitle(tr("Новый чат"))
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tr("Отменить")) { dismiss() }.disabled(busy) } }
                .sheet(isPresented: $choosing) {
                    UserChooser(model: model, multiple: group, excluding: Set(selection.map(\.id))) { peers in
                        selection = group ? selection + peers : peers
                    }
                }
                .onChange(of: name) { _, _ in requestID = UUID() }
                .onChange(of: detail) { _, _ in requestID = UUID() }
                .onChange(of: selection.map(\.id)) { _, _ in requestID = UUID() }
                .onChange(of: group) { _, value in requestID = UUID(); if !value { selection = Array(selection.prefix(1)) } }
                .onDisappear { operation?.cancel() }
        }.tint(MSTheme.accent).font(MSTheme.font())
    }
    private func create() {
        guard !busy else { return }; busy = true; error = nil
        operation = Task {
            defer { busy = false }
            do {
                let conversation: Conversation
                if group {
                    conversation = try await model.repository.createGroup(id: requestID, name: name, description: detail, members: selection.map(\.id))
                } else {
                    guard let peer = selection.first else { return }
                    conversation = try await model.repository.direct(userID: peer.id)
                }
                try Task.checkCancellation(); guard model.active else { return }
                await model.acceptConversation(conversation)
                open(conversation.id); dismiss()
            } catch is CancellationError { }
            catch { self.error = userMessage(error) }
        }
    }
}

struct UserChooser: View {
    let model: MessagingModel
    let multiple: Bool
    let excluding: Set<UUID>
    let selected: ([Peer]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var peers: [Peer] = []
    @State private var selection: [UUID: Peer] = [:]
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                TextField(tr("Поиск пользователей"), text: $query).accessibilityIdentifier("userSearch")
                if loading { ProgressView() }
                if let error { Text(tr(error)).foregroundStyle(MSTheme.danger) }
                ForEach(peers.filter { !excluding.contains($0.id) && $0.id != model.account.user.id }) { peer in
                    Button {
                        if multiple {
                            if selection[peer.id] != nil { selection[peer.id] = nil }
                            else if selection.count < 99 { selection[peer.id] = peer }
                        } else { selected([peer]); dismiss() }
                    } label: {
                        HStack { Text(peer.displayName); Spacer(); if selection[peer.id] != nil { Image(systemName: "checkmark") } }
                    }.accessibilityIdentifier("peer.\(peer.id.uuidString.lowercased())")
                }
                if !loading && peers.isEmpty { Text(tr("Пользователи не найдены")).foregroundStyle(MSTheme.muted) }
            }.navigationTitle(tr("Участники"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(tr("Отменить")) { dismiss() } }
                    if multiple {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(tr("Готово")) { selected(Array(selection.values)); dismiss() }.disabled(selection.isEmpty)
                        }
                    }
                }
                .task(id: query) {
                    loading = true; error = nil
                    do {
                        try await Task.sleep(for: .milliseconds(300))
                        let result = try await model.repository.users(search: String(query.prefix(100)))
                        try Task.checkCancellation(); peers = result; loading = false
                    } catch is CancellationError { }
                    catch { self.error = userMessage(error); loading = false }
                }
        }.tint(MSTheme.accent).font(MSTheme.font())
    }
}

struct GroupDetailsView: View {
    @Bindable var model: MessagingModel
    let id: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var conversation: Conversation?
    @State private var members: [GroupMember] = []
    @State private var name = ""
    @State private var detail = ""
    @State private var choosing = false
    @State private var busy = false
    @State private var error: String?
    @State private var action: GroupAction?
    @State private var operation: Task<Void, Never>?
    private enum GroupAction {
        case remove(UUID), transfer(UUID), leave, delete
    }
    var body: some View {
        NavigationStack {
            Form {
                Section(tr("О группе")) {
                    TextField(tr("Название группы"), text: $name).disabled(conversation?.canManage != true)
                    TextField(tr("Описание"), text: $detail, axis: .vertical).disabled(conversation?.canManage != true)
                    if conversation?.canManage == true {
                        Button(tr("Сохранить")) {
                            perform {
                                _ = try await model.repository.updateGroup(id, name: name, description: detail)
                            }
                        }
                    }
                }
                Section(tr("Участники")) {
                    ForEach(members) { member in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(member.displayName)
                                Text(tr(roleName(member.role))).font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
                            }
                            Spacer()
                            if conversation?.canManage == true && member.id != model.account.user.id && member.role != "owner" {
                                Menu {
                                    if conversation?.myRole == "owner" {
                                        Button(tr(member.role == "admin" ? "Сделать участником" : "Назначить администратором")) {
                                            perform { try await model.repository.changeRole(id, user: member.id, role: member.role == "admin" ? "member" : "admin") }
                                        }
                                        Button(tr("Передать владение")) { action = .transfer(member.id) }
                                    }
                                    if conversation?.myRole == "owner" || member.role == "member" {
                                        Button(tr("Удалить из группы"), role: .destructive) { action = .remove(member.id) }
                                    }
                                } label: { Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44) }
                                    .accessibilityLabel(tr("Действия участника"))
                            }
                        }
                    }
                    if conversation?.canManage == true { Button(tr("Добавить участников")) { choosing = true } }
                }
                if conversation?.myRole == "owner" {
                    Text(tr("Чтобы выйти, сначала передайте владение другому участнику.")).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
                    Button(tr("Удалить группу"), role: .destructive) { action = .delete }
                } else if conversation != nil {
                    Button(tr("Выйти из группы"), role: .destructive) { action = .leave }
                }
                if busy { ProgressView() }
                if let error { Text(tr(error)).foregroundStyle(MSTheme.danger) }
            }.disabled(busy).navigationTitle(tr("О группе"))
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(tr("Готово")) { dismiss() }.disabled(busy) } }
                .task { await reload() }
                .onDisappear { operation?.cancel() }
                .sheet(isPresented: $choosing) {
                    UserChooser(model: model, multiple: true, excluding: Set(members.map(\.id))) { peers in
                        perform { try await model.repository.addMembers(id, users: peers.map(\.id)) }
                    }
                }
                .confirmationDialog(tr("Подтвердите действие с группой"), isPresented: Binding(get: { action != nil }, set: { if !$0 { action = nil } })) {
                    Button(tr("Подтвердить"), role: .destructive) {
                        guard let action else { return }; self.action = nil
                        perform {
                            switch action {
                            case .remove(let user): try await model.repository.removeMember(id, user: user)
                            case .transfer(let user): try await model.repository.transferOwnership(id, user: user)
                            case .leave:
                                try await model.repository.leaveGroup(id)
                                await model.removedConversation(id); dismiss(); return
                            case .delete:
                                try await model.repository.deleteGroup(id)
                                await model.removedConversation(id); dismiss(); return
                            }
                        }
                    }
                }
        }.tint(MSTheme.accent).font(MSTheme.font())
    }
    private func reload() async {
        do {
            let item = try await model.repository.conversation(id)
            let people = try await model.repository.members(id)
            try Task.checkCancellation(); guard model.active else { return }
            conversation = item; name = item.name ?? ""; detail = item.description; members = people
        } catch is CancellationError { }
        catch { self.error = userMessage(error) }
    }
    private func perform(_ body: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; error = nil
        operation = Task {
            defer { busy = false }
            do {
                try await body(); try Task.checkCancellation()
                guard model.active else { return }
                await reload(); await model.refreshConversations()
            } catch is CancellationError { }
            catch { self.error = userMessage(error) }
        }
    }
    private func roleName(_ role: String) -> String {
        switch role { case "owner": "Владелец"; case "admin": "Администратор"; default: "Участник" }
    }
}
