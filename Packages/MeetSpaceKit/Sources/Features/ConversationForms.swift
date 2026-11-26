import SwiftUI
import MeetSpaceAPI
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
    @State private var requestID = UUID()
    @State private var busy = false
    @State private var error: String?
    @State private var operation: Task<Void, Never>?
    @FocusState private var editingInput: Bool

    var body: some View {
        WorkspaceFormSheet(title: group ? "Создать группу" : "Новая беседа", identifier: "newConversation",
                           closeAction: .cancel, closeLabel: "Отменить", busy: busy, close: { dismiss() }) {
            if group {
                groupFields
            } else {
                Button {
                    group = true
                } label: {
                    Label(tr("Создать группу"), systemImage: "person.2")
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).padding(.vertical, 7)
                }.buttonStyle(MSButtonStyle(primary: false)).accessibilityIdentifier("newConversation.group")
                Text(tr("Или начните личную переписку.")).foregroundStyle(MSTheme.muted)
            }
            WorkspacePeopleList(model: model, excluded: [], retained: selection, showSeparators: !group) { peer in
                let picked = selection.contains { $0.id == peer.id }
                WorkspacePersonButton(peer: peer, multiple: group, selected: picked) {
                    editingInput = false
                    if group {
                        if picked { selection.removeAll { $0.id == peer.id } }
                        else if selection.count < 99 { selection.append(peer) }
                    } else {
                        create(peer)
                    }
                }
            }
            if group {
                Text(tr("Вы будете администратором группы. Она появится во вкладке «Все»."))
                    .font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
            }
            if let error { Text(tr(error)).foregroundStyle(MSTheme.danger) }
            if busy { ProgressView().frame(maxWidth: .infinity) }
            if group {
                Button { create(nil) } label: {
                    Text(tr("Создать группу")).fixedSize(horizontal: false, vertical: true).padding(.vertical, 7)
                }.buttonStyle(MSButtonStyle())
                    .disabled(selection.isEmpty || !(1...50).contains(name.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count)
                              || detail.unicodeScalars.count > 200)
                    .accessibilityIdentifier("createConversation")
            }
        }
        .onChange(of: name) { _, _ in requestID = UUID() }
        .onChange(of: detail) { _, _ in requestID = UUID() }
        .onChange(of: selection.map(\.id)) { _, _ in requestID = UUID() }
        .onDisappear { operation?.cancel() }
    }

    private var groupFields: some View {
        Group {
            WorkspaceFormField(title: "Название группы") {
                TextField(tr("Например, Команда проекта"), text: $name)
                    .textFieldStyle(.plain).workspaceFormInput().focused($editingInput)
                    .accessibilityLabel(tr("Название группы")).accessibilityIdentifier("newConversation.groupName")
            }
            WorkspaceFormField(title: "Описание") {
                TextField(tr("Описание"), text: $detail, axis: .vertical).lineLimit(2...4)
                    .textFieldStyle(.plain).workspaceFormInput(minHeight: 68)
            }
            Text(tr("Участники")).font(MSTheme.font(13, weight: .semibold)).accessibilityAddTraits(.isHeader)
        }
    }

    /// Открывает личный диалог с контактом или создаёт группу из выбранных участников.
    /// - Parameter peer: Собеседник для личного диалога или nil для создания группы.
    private func create(_ peer: Peer?) {
        guard !busy else { return }
        busy = true; error = nil
        editingInput = false
        operation = Task {
            defer { busy = false }
            do {
                let conversation: Conversation
                if let peer {
                    conversation = try await model.repository.direct(userID: peer.id)
                } else {
                    conversation = try await model.repository.createGroup(id: requestID, name: name, description: detail, members: selection.map(\.id))
                }
                try Task.checkCancellation(); guard model.active else { return }
                await model.acceptConversation(conversation)
                open(conversation.id); dismiss()
            } catch is CancellationError { }
            catch { self.error = userMessage(error) }
        }
    }
}

private struct WorkspacePeopleList<Row: View>: View {
    let model: MessagingModel
    let excluded: Set<UUID>
    let retained: [Peer]
    var showSeparators = false
    @ViewBuilder let row: (Peer) -> Row
    @State private var query = ""
    @State private var peers: [Peer] = []
    @State private var loading = true
    @State private var error: String?

    private var choices: [Peer] {
        var seen = excluded
        seen.insert(model.account.user.id)
        return (peers + retained).filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        let available = choices
        VStack(alignment: .leading, spacing: 12) {
            SearchBox(text: $query, placeholder: "Поиск пользователей", identifier: "userSearch")
            if let error { Text(tr(error)).foregroundStyle(MSTheme.danger) }
            else if loading { ProgressView().frame(maxWidth: .infinity, minHeight: 48) }
            else if available.isEmpty { Text(tr("Пользователи не найдены")).foregroundStyle(MSTheme.muted) }
            else {
                VStack(spacing: 0) {
                    ForEach(available) { peer in
                        row(peer)
                        if showSeparators && peer.id != available.last?.id { Divider() }
                    }
                }
            }
        }
        .task(id: query) {
            loading = true; error = nil
            do {
                try await Task.sleep(for: .milliseconds(300))
                let result = try await model.repository.users(search: String(query.prefix(100)))
                try Task.checkCancellation()
                peers = result
                loading = false
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled else { return }
                self.error = userMessage(error); loading = false
            }
        }
    }
}

private struct WorkspacePersonButton: View {
    let peer: Peer
    let multiple: Bool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                ChatAvatar(name: peer.displayName, size: 40)
                Text(peer.displayName).font(MSTheme.font(13)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: multiple ? (selected ? "checkmark.square.fill" : "square") : "arrow.right")
                    .font(.system(size: 18)).frame(width: 24).foregroundStyle(selected ? MSTheme.accent : MSTheme.muted)
                    .accessibilityHidden(true)
            }.padding(.vertical, 10).frame(maxWidth: .infinity, minHeight: 64).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(peer.displayName)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("peer.\(peer.id.uuidString.lowercased())")
    }
}

struct UserChooser: View {
    let model: MessagingModel
    let multiple: Bool
    let excluding: Set<UUID>
    let selected: ([Peer]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection: [Peer] = []

    var body: some View {
        WorkspaceFormSheet(title: multiple ? "Участники" : "Собеседник", identifier: "userChooser",
                           closeAction: .cancel, closeLabel: "Отменить", close: { dismiss() }) {
            WorkspacePeopleList(model: model, excluded: excluding, retained: selection) { peer in
                let picked = selection.contains { $0.id == peer.id }
                WorkspacePersonButton(peer: peer, multiple: multiple, selected: picked) {
                    if multiple {
                        if picked { selection.removeAll { $0.id == peer.id } }
                        else if selection.count < 99 { selection.append(peer) }
                    } else {
                        selected([peer]); dismiss()
                    }
                }
            }
            if multiple {
                Button(tr("Готово")) { selected(selection); dismiss() }
                    .buttonStyle(MSButtonStyle()).disabled(selection.isEmpty)
            }
        }
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
                .interactiveDismissDisabled(busy)
                .workspaceFormPresentation(isPresented: $choosing) {
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
    /// Загружает актуальные сведения о группе и обновляет поля формы.
    private func reload() async {
        do {
            let item = try await model.repository.conversation(id)
            guard item.id == id, item.isGroup else { throw APIError.invalidResponse }
            let people = try await model.repository.members(id)
            try Task.checkCancellation(); guard model.active else { return }
            model.updateCachedConversation(item)
            conversation = item; name = item.name ?? ""; detail = item.description; members = people
        } catch is CancellationError { }
        catch { self.error = userMessage(error) }
    }
    /// Выполняет изменение группы, блокируя повторный запрос и показывая ошибки.
    /// - Parameter body: Асинхронная операция над группой.
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
    /// Возвращает название роли участника группы для интерфейса.
    /// - Parameter role: Серверный код роли.
    private func roleName(_ role: String) -> String {
        switch role { case "owner": "Владелец"; case "admin": "Администратор"; default: "Участник" }
    }
}
