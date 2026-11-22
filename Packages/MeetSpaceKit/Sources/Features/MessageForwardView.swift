import SwiftUI
import MeetSpaceCore
import MeetSpaceAPI
import MeetSpaceDesignSystem

/// Native recipient picker. Requests use the server's forwarding endpoint, preserving author and attachments.
struct MessageForwardView: View {
    @Bindable var model: MessagingModel
    let messages: [ChatMessage]
    var didForward: (UUID) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var recipients: [Conversation] = []
    @State private var users: [Peer] = []
    @State private var cursor: String?
    @State private var loading = false
    @State private var failure: String?
    @State private var requestIDs: [UUID: UUID] = [:]
    @State private var epoch = UUID()
    @State private var sending = false
    @State private var forwardTask: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(tr("Получатель")).font(MSTheme.font(12, weight: .semibold))
                    SearchBox(text: $query, placeholder: "Найти чат или группу")
                    if let first = messages.first { ForwardPreview(author: first.senderName, text: first.shareText) }
                    if loading || sending { ProgressView() }
                    if let failure { Text(tr(failure)).foregroundStyle(MSTheme.danger).font(MSTheme.font(13)) }
                    ForEach(recipients) { target in
                        Button { beginForward(to: target.id) } label: {
                            ChatRecipientLabel(name: target.title, group: target.isGroup)
                        }.buttonStyle(.plain).accessibilityIdentifier("message.forward.\(target.id.uuidString.lowercased())")
                    }
                    ForEach(users) { user in
                        Button { beginForward(to: user.id, isUser: true) } label: {
                            ChatRecipientLabel(name: user.displayName)
                        }.buttonStyle(.plain)
                    }
                    if cursor != nil { Button(tr("Загрузить ещё")) { Task { await load(more: true) } } }
                    if !loading && recipients.isEmpty && users.isEmpty { Text(tr("Чат не найден")).foregroundStyle(MSTheme.muted) }
                }.padding(20).disabled(sending || model.forwarding)
            }.background(MSTheme.surface)
                .navigationTitle(tr("Переслать сообщение")).msInlineTitle()
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tr("Отмена")) { dismiss() }.disabled(sending || model.forwarding) } }
                .interactiveDismissDisabled(sending || model.forwarding)
                .onDisappear { forwardTask?.cancel(); forwardTask = nil }
                .task(id: query) {
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                    await load()
                }
        }
    }
    private func load(more: Bool = false) async {
        epoch = UUID(); let current = epoch
        loading = true; failure = nil
        defer { if epoch == current { loading = false } }
        do {
            let search = String(String.UnicodeScalarView(query.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.prefix(100)))
            let page = try await model.repository.conversations(cursor: more ? cursor : nil, search: search)
            try Task.checkCancellation()
            guard model.active, epoch == current else { return }
            recipients = (more ? recipients : []) + page.items
            var seen: Set<UUID> = []
            recipients = recipients.filter { seen.insert($0.id).inserted }
            cursor = page.nextCursor
            users = []
            // A people-search failure must not discard valid conversation results.
            let people = search.unicodeScalars.count < 2 ? [] : try await model.repository.users(search: search)
            try Task.checkCancellation()
            guard model.active, epoch == current else { return }
            let direct = Set(recipients.compactMap { $0.peer?.id })
            users = people.filter { $0.id != model.account.user.id && !direct.contains($0.id) }
        } catch is CancellationError { }
        catch { if epoch == current { failure = userMessage(error) } }
    }
    private func beginForward(to id: UUID, isUser: Bool = false) {
        guard !sending, !model.forwarding else { return }
        sending = true
        forwardTask = Task { await forward(to: id, isUser: isUser) }
    }
    private func forward(to id: UUID, isUser: Bool) async {
        defer { sending = false; forwardTask = nil }
        failure = nil
        let request = requestIDs[id] ?? UUID(); requestIDs[id] = request
        do {
            try Task.checkCancellation()
            let target: UUID
            if isUser { target = try await model.forward(messages, toUser: id, requestID: request) }
            else { target = try await model.forward(messages, to: id, requestID: request) }
            try Task.checkCancellation()
            didForward(target)
            dismiss()
        }
        catch is CancellationError { }
        catch APIError.httpStatus(let status) where status == 405 || status == 501 {
            failure = "Сервер не поддерживает пересылку сообщений. Обновите MeetSpace на сервере."
        }
        catch { failure = userMessage(error) }
    }
}
