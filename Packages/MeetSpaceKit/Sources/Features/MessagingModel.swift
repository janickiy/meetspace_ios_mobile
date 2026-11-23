import Foundation
import Observation
import MeetSpaceCore
import MeetSpaceAPI
import MeetSpaceStorage
import MeetSpaceRealtime
import MeetSpaceMedia

public struct PendingMessage: Identifiable {
    public var id: UUID { draft.id }
    public let conversation: UUID
    public let draft: MessageDraft
    public var failed = false
}
public struct UploadState: Identifiable {
    public var id: UUID { file.id }
    public let conversation: UUID
    public let file: StagedFile
    public var progress = 0.0
    public var attachment: Attachment?
    public var error: String?
}
public struct DownloadState: Identifiable {
    public let id: UUID
    public let filename: String
    public var progress = 0.0
    public var url: URL?
    public var error: String?
}

@MainActor @Observable public final class MessagingModel {
    public let account: AccountRecord
    public let client: AuthenticatedClient
    public let repository: MessagingRepository
    public private(set) var conversations: [Conversation] = []
    public private(set) var listState: LoadState = .loading
    public private(set) var listCursor: String?
    public private(set) var unreadCount = 0
    public private(set) var conversation: Conversation?
    public private(set) var timeline = MessageTimeline()
    public private(set) var historyState: LoadState = .loading
    public private(set) var historyCursor: String?
    public private(set) var historyLoadingMore = false
    public private(set) var searchResults: [ChatMessage] = []
    public private(set) var searchCursor: String?
    public private(set) var searching = false
    public private(set) var hiddenMessageIDs: Set<UUID> = []
    public private(set) var selectedMessageIDs: Set<UUID> = []
    public private(set) var selectingMessages = false
    public private(set) var hidingMessages = false
    public private(set) var forwarding = false
    public private(set) var realtimeState: RealtimeState = .disconnected
    public private(set) var pending: [PendingMessage] = []
    public private(set) var uploads: [UploadState] = []
    public private(set) var downloads: [UUID: DownloadState] = [:]
    public var error: String?
    public var text = ""
    public var reply: ChatMessage?
    public var editing: ChatMessage?
    public var listSearch = ""
    public var onlyUnread = false
    public var groupFilter = false
    public var directFilter = false
    public private(set) var active = true
    public private(set) var savingEdit = false
    @ObservationIgnored public var onCallUpdate: (@MainActor (DirectCall) -> Void)?
    @ObservationIgnored public var onRealtimeConnected: (@MainActor () -> Void)?
    @ObservationIgnored private let realtime: UserRealtime
    @ObservationIgnored private let hiddenStore: any HiddenChatMessagesStore
    @ObservationIgnored private var hiddenLoaded = false
    @ObservationIgnored private let files: AccountFileStore
    @ObservationIgnored private var realtimeTask: Task<Void, Never>?
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var listTask: Task<Void, Never>?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var listEpoch = UUID()
    @ObservationIgnored private var historyEpoch = UUID()
    @ObservationIgnored private var selectionEpoch = UUID()
    @ObservationIgnored private var searchEpoch = UUID()
    @ObservationIgnored private var editEpoch = UUID()
    @ObservationIgnored private var foreground = true
    @ObservationIgnored private var callActive = false
    @ObservationIgnored private var visible = false
    @ObservationIgnored private let notificationAudio = AudioSettingsModel()

    public init(client: AuthenticatedClient, downloads: any RequestTransport = URLSessionRequestTransport(),
                sockets: any RealtimeSocketFactory = URLSessionSocketFactory(), files: AccountFileStore? = nil,
                hiddenMessages: any HiddenChatMessagesStore = DeviceHiddenChatMessagesStore.shared) {
        account = client.account; self.client = client; self.hiddenStore = hiddenMessages
        let repository = MessagingRepository(client: client, downloads: downloads)
        self.repository = repository
        realtime = UserRealtime(origin: client.account.server, ticket: { try await repository.ticket().ticket }, sockets: sockets)
        self.files = files ?? AccountFileStore(account: client.account)
    }

    public func start() {
        guard active, realtimeTask == nil else { return }
        realtimeTask = Task { [weak self, realtime] in
            await realtime.start()
            for await update in realtime.updates {
                guard let self, self.active, !Task.isCancelled else { return }
                switch update {
                case .state(let state):
                    self.realtimeState = state
                    if state == .connected {
                        self.onRealtimeConnected?()
                        // Subscription first, then a new REST head: the protocol has no replay.
                        self.scheduleListRefresh()
                        if let id = self.conversation?.id { await self.reloadHistory(id) }
                    }
                case .event(let event):
                    if let call = event.call { self.onCallUpdate?(call) }
                    else { self.receive(event) }
                case .authenticationRequired: self.error = "Сессия завершена. Войдите снова."
                }
            }
        }
        scheduleListRefresh()
    }

    public func setForeground(_ value: Bool) async {
        foreground = value
        if !value { notificationAudio.stop() }
        guard active else { return }
        if value { await realtime.start(); scheduleListRefresh(); markVisibleRead() }
        else { readTask?.cancel(); if !callActive { await realtime.stop() } }
    }
    public func setCallActive(_ value: Bool) async {
        callActive = value
        guard active else { return }
        if value || foreground { await realtime.start() }
        else { await realtime.stop() }
    }
    public func close() async {
        guard active else { return }
        notificationAudio.stop()
        active = false; visible = false; cancelMessageSelection()
        listEpoch = UUID(); historyEpoch = UUID(); searchEpoch = UUID()
        selectionEpoch = UUID()
        let running = Array(tasks.values)
        for task in running { task.cancel() }
        listTask?.cancel(); readTask?.cancel(); realtimeTask?.cancel()
        await realtime.finish(); await repository.cancelDownloads()
        for task in running { await task.value }
        tasks = [:]; pending = []; uploads = []; downloads = [:]
        conversations = []; conversation = nil; timeline = MessageTimeline(); text = ""; reply = nil; editing = nil
        do { try await files.clear() } catch { self.error = userMessage(error) }
    }

    public func refreshConversations(more: Bool = false) async {
        guard active else { return }
        if more && listCursor == nil { return }
        listEpoch = UUID(); let epoch = listEpoch
        let cursor = more ? listCursor : nil
        let search = String(listSearch.prefix(100)); let unread = onlyUnread; let type = groupFilter ? "group" : directFilter ? "direct" : nil
        if !more && conversations.isEmpty { listState = .loading }
        do {
            try await loadHiddenMessages()
            guard active, listEpoch == epoch else { return }
            let page = try await repository.conversations(cursor: cursor, search: search, type: type, unreadOnly: unread)
            try Task.checkCancellation()
            guard active, listEpoch == epoch else { return }
            let prior = more ? conversations : []
            var combined = Dictionary(prior.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            for item in page.items { combined[item.id] = item }
            conversations = combined.values.sorted { $0.updatedAt > $1.updatedAt }
            listCursor = nonempty(page.nextCursor); unreadCount = page.unreadCount
            listState = conversations.isEmpty ? .empty : .content
        } catch is CancellationError { }
        catch {
            guard active, listEpoch == epoch else { return }
            listState = error as? APIError == .offline ? .offline : .failed
            self.error = userMessage(error)
        }
    }

    public func open(_ id: UUID) async {
        guard active else { return }
        selectionEpoch = UUID(); let epoch = selectionEpoch
        if conversation?.id != id {
            cancelMessageSelection()
            await clearComposer()
            guard active, selectionEpoch == epoch else { return }
            conversation = conversations.first { $0.id == id }
            timeline = MessageTimeline(); searchResults = []; searchCursor = nil
        }
        visible = true
        await reloadHistory(id)
    }
    public func hide(_ id: UUID) {
        guard conversation?.id == id else { return }
        visible = false; readTask?.cancel()
    }

    public func reloadHistory(_ id: UUID) async {
        guard active else { return }
        historyEpoch = UUID(); let epoch = historyEpoch
        historyState = .loading; historyCursor = nil; historyLoadingMore = false
        // Reset BEFORE the request; events received during the fetch are merged by version.
        timeline = MessageTimeline()
        do {
            try await loadHiddenMessages()
            guard active, historyEpoch == epoch else { return }
            let detail = try await repository.conversation(id)
            guard active, historyEpoch == epoch else { return }
            conversation = detail
            let page = try await repository.messages(id)
            try Task.checkCancellation()
            guard active, historyEpoch == epoch, conversation?.id == id else { return }
            merge(page.items, in: id); historyCursor = nonempty(page.nextCursor)
            pruneMessageSelection()
            historyState = timeline.messages.isEmpty ? .empty : .content
            markVisibleRead()
        } catch is CancellationError { }
        catch {
            guard active, historyEpoch == epoch else { return }
            historyState = error as? APIError == .offline ? .offline : .failed
            if case APIError.httpStatus(let status) = error, status == 403 || status == 404 {
                timeline = MessageTimeline(); conversation = nil; await clearComposer()
            }
            self.error = userMessage(error)
        }
    }
    public func loadOlder() async {
        guard active, let id = conversation?.id, let cursor = historyCursor, !historyLoadingMore else { return }
        let epoch = historyEpoch; historyLoadingMore = true
        defer { if historyEpoch == epoch { historyLoadingMore = false } }
        do {
            let page = try await repository.messages(id, before: cursor)
            try Task.checkCancellation()
            guard active, historyEpoch == epoch else { return }
            merge(page.items, in: id); historyCursor = nonempty(page.nextCursor)
        } catch is CancellationError { }
        catch { if active, historyEpoch == epoch { self.error = userMessage(error) } }
    }
    public func searchMessages(_ query: String, more: Bool = false) async {
        guard active, let id = conversation?.id else { return }
        searchEpoch = UUID(); let epoch = searchEpoch
        if !more { searchResults = []; searchCursor = nil }
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count >= 2 else { searching = false; return }
        searching = true
        defer { if searchEpoch == epoch { searching = false } }
        do {
            let page = try await repository.messages(id, before: more ? searchCursor : nil, search: query)
            try Task.checkCancellation()
            guard active, conversation?.id == id, searchEpoch == epoch else { return }
            var results = MessageTimeline()
            results.merge(searchResults + page.items, conversation: id)
            searchResults = results.messages.filter { !hiddenMessageIDs.contains($0.id) }; searchCursor = nonempty(page.nextCursor)
        } catch is CancellationError { }
        catch { if active, searchEpoch == epoch { self.error = userMessage(error) } }
    }

    public var canSend: Bool {
        active && !selectingMessages && !savingEdit && conversation != nil && historyState != .loading &&
        text.unicodeScalars.count <= 4000 &&
        uploads.allSatisfy { $0.attachment != nil } &&
        (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !uploads.isEmpty || editing?.attachments.isEmpty == false)
    }
    public func send() {
        guard canSend, let id = conversation?.id else { return }
        do {
            if let editing {
                let value = text; let message = editing
                editEpoch = UUID(); let epoch = editEpoch; savingEdit = true
                run(UUID()) { model in
                    defer { if model.editEpoch == epoch { model.savingEdit = false } }
                    do {
                        let updated = try await model.repository.edit(id, message: message.id, text: value)
                        guard model.active, model.conversation?.id == id else { return }
                        model.merge([updated], in: id)
                        if model.editing?.id == message.id && model.text == value { model.text = ""; model.editing = nil }
                    } catch { if model.active { model.error = userMessage(error) } }
                }
                return
            }
            let draft = try MessageDraft(text: text, replyTo: reply?.id, attachmentIds: uploads.compactMap { $0.attachment?.id })
            pending.append(PendingMessage(conversation: id, draft: draft))
            text = ""; reply = nil
            let sentFiles = uploads; uploads = []
            for upload in sentFiles { Task { await files.remove(upload.file.url) } }
            retry(draft.id)
        } catch { self.error = userMessage(error) }
    }
    public func retry(_ id: UUID) {
        guard active, tasks[id] == nil, let item = pending.first(where: { $0.id == id }) else { return }
        if let position = pending.firstIndex(where: { $0.id == id }) { pending[position].failed = false }
        run(id) { model in
            do {
                let message = try await model.repository.send(item.conversation, draft: item.draft)
                guard model.active else { return }
                if model.conversation?.id == item.conversation { model.merge([message], in: item.conversation) }
                model.pending.removeAll { $0.id == id }
                model.scheduleListRefresh()
            } catch {
                guard model.active, let index = model.pending.firstIndex(where: { $0.id == id }) else { return }
                model.pending[index].failed = true
                model.error = userMessage(error)
            }
        }
    }
    public func delete(_ message: ChatMessage) async {
        guard active, message.senderId == account.user.id, message.isActionable,
              let id = conversation?.id, message.conversationId == id, !hiddenMessageIDs.contains(message.id) else { return }
        do {
            let deleted = try await repository.delete(id, message: message.id)
            guard active, conversation?.id == id else { return }
            merge([deleted], in: id); updateSearch([deleted]); scheduleListRefresh()
        } catch { if active { self.error = userMessage(error) } }
    }

    public var selectableMessages: [ChatMessage] { timeline.messages.filter { $0.isActionable && !hiddenMessageIDs.contains($0.id) } }
    public var selectedMessages: [ChatMessage] { selectableMessages.filter { selectedMessageIDs.contains($0.id) } }
    public func beginMessageSelection(_ message: ChatMessage? = nil) {
        guard active, !hidingMessages else { return }
        selectingMessages = true
        selectedMessageIDs = []
        if let message, message.conversationId == conversation?.id, message.isActionable,
           !hiddenMessageIDs.contains(message.id),
           (timeline.messages + searchResults).contains(where: { $0.id == message.id }) {
            timeline.merge([message], conversation: message.conversationId!)
            selectedMessageIDs.insert(message.id)
        }
    }
    public func toggleMessageSelection(_ id: UUID) {
        guard active, selectingMessages, !hidingMessages, selectableMessages.contains(where: { $0.id == id }) else { return }
        if !selectedMessageIDs.insert(id).inserted { selectedMessageIDs.remove(id) }
    }
    public func toggleAllMessages() {
        guard active, selectingMessages, !hidingMessages else { return }
        let ids = Set(selectableMessages.map(\.id))
        selectedMessageIDs = selectedMessageIDs == ids ? [] : ids
    }
    public func cancelMessageSelection() { selectingMessages = false; selectedMessageIDs = [] }
    /// As on Android, bulk removal is local and never calls server DELETE.
    @discardableResult public func hideSelectedMessages() async -> Bool {
        guard active, !hidingMessages, let id = conversation?.id, !selectedMessageIDs.isEmpty,
              selectedMessages.count == selectedMessageIDs.count else { return false }
        let ids = selectedMessageIDs, epoch = selectionEpoch
        hidingMessages = true; error = nil
        defer { hidingMessages = false }
        do {
            let stored = try await hiddenStore.hide(ids, scope: account.id)
            guard active else { return false }
            hiddenMessageIDs.formUnion(stored); hiddenLoaded = true
            timeline.remove(stored); searchResults.removeAll { stored.contains($0.id) }
            if historyState == .content && timeline.messages.isEmpty { historyState = .empty }
            if let reply, stored.contains(reply.id) { self.reply = nil }
            if let editing, stored.contains(editing.id) { self.editing = nil; text = "" }
            if conversation?.id == id, selectionEpoch == epoch { cancelMessageSelection() }
            pruneMessageSelection()
            return true
        } catch {
            if active { self.error = "Не удалось сохранить список удалённых на этом устройстве сообщений." }
            return false
        }
    }
    public func conversationPreview(_ item: Conversation) -> String {
        guard let last = item.lastMessageID, hiddenMessageIDs.contains(last) else { return item.preview }
        guard item.id == conversation?.id, let previous = timeline.messages.last else { return "" }
        return previous.isDeleted ? "Сообщение удалено" : previous.shareText
    }
    public func pin(_ message: ChatMessage) async {
        guard active, message.isActionable, let id = conversation?.id, message.conversationId == id,
              !hiddenMessageIDs.contains(message.id) else { return }
        do {
            try await repository.pin(id, message: message.id, pinned: !message.pinned)
            guard active, conversation?.id == id else { return }
            await reloadHistory(id)
        } catch { if active { self.error = userMessage(error) } }
    }
    /// Idempotency key belongs to the recipient in the forwarding sheet and survives retries.
    @discardableResult public func forward(_ messages: [ChatMessage], to destination: UUID, requestID: UUID) async throws -> UUID {
        try await performForward(messages, requestID: requestID) { destination }
    }
    @discardableResult public func forward(_ messages: [ChatMessage], toUser userID: UUID, requestID: UUID) async throws -> UUID {
        try await performForward(messages, requestID: requestID) {
            try await self.repository.direct(userID: userID).id
        }
    }
    private func performForward(_ messages: [ChatMessage], requestID: UUID,
                                destination: () async throws -> UUID) async throws -> UUID {
        try Task.checkCancellation()
        guard active, !forwarding, let source = conversation?.id, !messages.isEmpty else { throw ClientError.invalidInput }
        func validMessages() -> Bool {
            active && conversation?.id == source && messages.allSatisfy({ original in
                  let current = (timeline.messages + searchResults).filter { $0.id == original.id }.max { $0.version < $1.version }
                  return original.conversationId == source && current?.conversationId == source &&
                      current?.isActionable == true && !hiddenMessageIDs.contains(original.id)
              })
        }
        guard validMessages() else { throw ClientError.invalidInput }
        forwarding = true
        defer { forwarding = false }
        let target = try await destination()
        try Task.checkCancellation()
        guard validMessages() else { throw ClientError.invalidInput }
        _ = try await repository.forward(target, source: source, messages: messages.map(\.id), requestID: requestID)
        try Task.checkCancellation()
        guard active else { throw CancellationError() }
        scheduleListRefresh()
        if conversation?.id == target { await reloadHistory(target) }
        return target
    }
    private func loadHiddenMessages() async throws {
        guard !hiddenLoaded else { return }
        do {
            let ids = try await hiddenStore.load(scope: account.id)
            guard active else { throw CancellationError() }
            hiddenMessageIDs.formUnion(ids); hiddenLoaded = true
        } catch is CancellationError { throw CancellationError() }
        catch { throw ClientError.storage }
    }
    private func pruneMessageSelection() {
        selectedMessageIDs.formIntersection(Set(selectableMessages.map(\.id)))
    }
    private func updateSearch(_ incoming: [ChatMessage]) {
        let updates = Dictionary(incoming.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        searchResults = searchResults.compactMap { old in
            if hiddenMessageIDs.contains(old.id) { return nil }
            if let fresh = updates[old.id], fresh.version >= old.version { return fresh }
            return old
        }
    }

    public func importFiles(_ urls: [URL]) async {
        guard active, let id = conversation?.id, editing == nil else { return }
        guard urls.count + uploads.count <= FilePolicy.maximumAttachments else { error = "Можно приложить не больше 5 файлов."; return }
        for url in urls {
            do {
                let staged = try await files.stage(url)
                guard active, conversation?.id == id, uploads.count < FilePolicy.maximumAttachments else {
                    await files.remove(staged.url); return
                }
                uploads.append(UploadState(conversation: id, file: staged))
                retryUpload(staged.id)
            } catch { if active { self.error = userMessage(error) } }
        }
    }
    public func retryUpload(_ id: UUID) {
        guard active, tasks[id] == nil, let index = uploads.firstIndex(where: { $0.id == id }) else { return }
        let upload = uploads[index]; uploads[index].error = nil; uploads[index].progress = 0
        run(id) { model in
            do {
                let attachment = try await model.repository.upload(upload.conversation,
                    input: UploadInput(id: id, filename: upload.file.filename, mimeType: upload.file.mimeType, size: upload.file.size),
                    file: upload.file.url, progress: { [weak model] value in
                        Task { @MainActor in model?.uploadProgress(id, value) }
                    })
                guard model.active, let position = model.uploads.firstIndex(where: { $0.id == id }) else { return }
                model.uploads[position].attachment = attachment; model.uploads[position].progress = 1
            } catch {
                guard model.active, let position = model.uploads.firstIndex(where: { $0.id == id }) else { return }
                model.uploads[position].error = userMessage(error)
            }
        }
    }
    public func cancelUpload(_ id: UUID) async {
        tasks[id]?.cancel(); await tasks[id]?.value; tasks[id] = nil
        if let upload = uploads.first(where: { $0.id == id }) { await files.remove(upload.file.url) }
        uploads.removeAll { $0.id == id }
    }
    public func download(_ attachment: Attachment) {
        guard active, let conversation = conversation?.id, tasks[attachment.id] == nil else { return }
        let id = attachment.id
        if downloads[id]?.url != nil { return }
        downloads[id] = DownloadState(id: id, filename: attachment.filename)
        run(id) { model in
            do {
                let data = try await model.repository.download(conversation, attachment: attachment, progress: { [weak model] value in
                    Task { @MainActor in
                        guard let model, model.active else { return }
                        model.downloads[id]?.progress = value
                    }
                })
                try Task.checkCancellation()
                guard model.active else { return }
                let url = try await model.files.storeDownload(data, filename: attachment.filename)
                guard model.active, !Task.isCancelled else { await model.files.remove(url); return }
                model.downloads[id]?.url = url; model.downloads[id]?.progress = 1
            } catch { if model.active { model.downloads[id]?.error = userMessage(error) } }
        }
    }
    public func cancelDownload(_ id: UUID) { tasks[id]?.cancel() }

    /// Used by group and new-chat forms; they own their cancellation and display their own errors.
    public func acceptConversation(_ item: Conversation) async {
        guard active else { return }
        if !conversations.contains(where: { $0.id == item.id }) { conversations.insert(item, at: 0) }
        listState = .content
        await refreshConversations()
    }
    public func removedConversation(_ id: UUID) async {
        conversations.removeAll { $0.id == id }
        if conversation?.id == id {
            cancelMessageSelection()
            historyEpoch = UUID(); searchEpoch = UUID(); conversation = nil; timeline = MessageTimeline()
            searchResults = []; historyCursor = nil; await clearComposer()
        }
        pending.removeAll { $0.conversation == id }
        scheduleListRefresh()
    }

    private func receive(_ event: UserEvent) {
        guard active else { return }
        if event.type == "conversation.member.removed", event.userID == account.user.id, let id = event.conversationID {
            // Revoke visible data immediately; never keep removed group history on screen.
            run(UUID()) { await $0.removedConversation(id) }
            return
        }
        if let id = event.conversationID, let message = event.message {
            if event.type == "message.created", message.isActionable, message.senderId != account.user.id,
               event.notificationsEnabled == true, !(visible && conversation?.id == id) {
                Task { [weak self] in
                    guard let self, self.active, self.foreground, !self.callActive,
                          ForegroundNotificationSound.enabled, AudioSessionUse.idle else { return }
                    await self.notificationAudio.test(.signals, respectingSilentMode: true)
                }
            }
            if conversation?.id == id { merge([message], in: id); markVisibleRead() }
            if message.senderId == account.user.id { pending.removeAll { $0.id == message.clientRequestId } }
        } else if let id = event.conversationID, id == conversation?.id,
                  event.type != "conversation.read.updated" {
            run(UUID()) { await $0.reloadHistory(id) }
        }
        scheduleListRefresh()
    }
    private func merge(_ messages: [ChatMessage], in id: UUID) {
        timeline.merge(messages.filter { !hiddenMessageIDs.contains($0.id) }, conversation: id)
        updateSearch(messages)
        pruneMessageSelection()
        let acknowledged = Set(messages.filter { $0.senderId == account.user.id }.map(\.clientRequestId))
        pending.removeAll { $0.conversation == id && acknowledged.contains($0.id) }
        if !timeline.messages.isEmpty { historyState = .content }
    }
    private func markVisibleRead() {
        guard active, visible, foreground, let id = conversation?.id, let last = timeline.messages.last else { return }
        readTask?.cancel()
        readTask = Task { [weak self, repository] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                _ = try await repository.markRead(id, through: last.id)
                guard let self, self.active, !Task.isCancelled else { return }
                self.scheduleListRefresh()
            } catch { /* Read receipts retry on visibility/resnapshot; message delivery stays usable. */ }
        }
    }
    private func scheduleListRefresh() {
        listTask?.cancel()
        listTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            await self?.refreshConversations()
        }
    }
    private func clearComposer() async {
        let previous = uploads
        text = ""; reply = nil; editing = nil; uploads = []
        editEpoch = UUID(); savingEdit = false
        for upload in previous {
            tasks[upload.id]?.cancel(); await tasks[upload.id]?.value; tasks[upload.id] = nil
            await files.remove(upload.file.url)
        }
    }
    private func uploadProgress(_ id: UUID, _ progress: Double) {
        guard active, let position = uploads.firstIndex(where: { $0.id == id }), uploads[position].attachment == nil else { return }
        uploads[position].progress = progress
    }
    private func run(_ id: UUID, operation: @escaping @MainActor (MessagingModel) async -> Void) {
        guard active, tasks[id] == nil else { return }
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            await operation(self)
            self.tasks[id] = nil
        }
    }
    private func nonempty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
}
