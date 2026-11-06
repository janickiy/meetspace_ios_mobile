import Foundation
import Observation
import MeetSpaceCore
import MeetSpaceAPI
import MeetSpaceStorage
import MeetSpaceRealtime

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
    public private(set) var active = true
    public private(set) var savingEdit = false
    @ObservationIgnored public var onCallUpdate: (@MainActor (DirectCall) -> Void)?
    @ObservationIgnored public var onRealtimeConnected: (@MainActor () -> Void)?
    @ObservationIgnored private let realtime: UserRealtime
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

    public init(client: AuthenticatedClient, downloads: any RequestTransport = URLSessionRequestTransport(),
                sockets: any RealtimeSocketFactory = URLSessionSocketFactory(), files: AccountFileStore? = nil) {
        account = client.account; self.client = client
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
        active = false; visible = false
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
        let search = String(listSearch.prefix(100)); let unread = onlyUnread; let groups = groupFilter
        if !more && conversations.isEmpty { listState = .loading }
        do {
            let page = try await repository.conversations(cursor: cursor, search: search, type: groups ? "group" : nil, unreadOnly: unread)
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
            let detail = try await repository.conversation(id)
            guard active, historyEpoch == epoch else { return }
            conversation = detail
            let page = try await repository.messages(id)
            try Task.checkCancellation()
            guard active, historyEpoch == epoch, conversation?.id == id else { return }
            merge(page.items, in: id); historyCursor = nonempty(page.nextCursor)
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
            searchResults = results.messages; searchCursor = nonempty(page.nextCursor)
        } catch is CancellationError { }
        catch { if active, searchEpoch == epoch { self.error = userMessage(error) } }
    }

    public var canSend: Bool {
        active && !savingEdit && conversation != nil && historyState != .loading &&
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
        guard active, message.canEdit(as: account.user.id), let id = conversation?.id else { return }
        do {
            let deleted = try await repository.delete(id, message: message.id)
            guard active, conversation?.id == id else { return }
            merge([deleted], in: id); scheduleListRefresh()
        } catch { if active { self.error = userMessage(error) } }
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
            if conversation?.id == id { merge([message], in: id); markVisibleRead() }
            if message.senderId == account.user.id { pending.removeAll { $0.id == message.clientRequestId } }
        } else if let id = event.conversationID, id == conversation?.id,
                  event.type != "conversation.read.updated" {
            run(UUID()) { await $0.reloadHistory(id) }
        }
        scheduleListRefresh()
    }
    private func merge(_ messages: [ChatMessage], in id: UUID) {
        timeline.merge(messages, conversation: id)
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
