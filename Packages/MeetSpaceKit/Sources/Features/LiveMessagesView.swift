import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

struct LiveMessagesView: View {
    @Bindable var app: AppModel
    @Bindable var model: MessagingModel
    @State private var creating = false
    @State private var selected: UUID?
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= 800 && !typeSize.isAccessibilitySize
            HStack(spacing: 0) {
                conversationColumn(wide: wide)
                    .frame(width: wide ? 340 : nil).frame(maxWidth: wide ? 340 : .infinity)
                if wide {
                    Divider()
                    if let selected { LiveThreadView(model: model, id: selected, calls: app.identity.calls).id(selected) }
                    else { ContentUnavailableView(tr("Выберите чат"), systemImage: "bubble.left.and.bubble.right") }
                }
            }.background(MSTheme.background)
                .sheet(isPresented: $creating) {
                    NewConversationView(model: model) { id in select(id, wide: wide) }
                }
        }
        .task(id: "\(model.listSearch)|\(model.onlyUnread)|\(model.groupFilter)") {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            await model.refreshConversations()
        }
        .alert(tr("MeetSpace"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(tr("Понятно"), role: .cancel) { model.error = nil }
        } message: { Text(tr(model.error ?? "")) }
    }
    @ViewBuilder private func conversationColumn(wide: Bool) -> some View {
        if typeSize.isAccessibilitySize {
            // Keep the growing controls and results in one scroll surface so the
            // header cannot consume the conversation viewport at accessibility sizes.
            ScrollView {
                VStack(spacing: 12) {
                    conversationHeader
                    conversationRows(wide: wide)
                }
            }.refreshable { await model.refreshConversations() }
        } else {
            VStack(spacing: 12) {
                conversationHeader
                ScrollView { conversationRows(wide: wide) }
                    .refreshable { await model.refreshConversations() }
            }
        }
    }
    private var conversationHeader: some View {
        VStack(spacing: 12) {
            PageHeader(title: "Сообщения") {
                IconButton("square.and.pencil", label: "Новый чат") { creating = true }
                    .accessibilityIdentifier("newChat")
            }
            ViewThatFits(in: .horizontal) {
                HStack { serverName; Spacer(); connectionStatus }
                VStack(alignment: .leading, spacing: 6) { serverName; connectionStatus }
            }.font(MSTheme.font(11)).foregroundStyle(MSTheme.muted).padding(.horizontal, 20)
            SearchBox(text: $model.listSearch, placeholder: "Поиск чатов").padding(.horizontal, 20)
            HStack(spacing: 12) {
                Toggle(isOn: $model.onlyUnread) { Text(tr("Непрочитанные")).frame(minHeight: 44) }
                Toggle(isOn: $model.groupFilter) { Text(tr("Группы")).frame(minHeight: 44) }
            }.toggleStyle(.button).font(MSTheme.font(12)).padding(.horizontal, 20)
        }
    }
    private func conversationRows(wide: Bool) -> some View {
        LazyVStack(spacing: 8) {
            StateContent(state: model.listState, retry: { Task { await model.refreshConversations() } }) {
                ForEach(model.conversations) { item in
                    Button { select(item.id, wide: wide) } label: { row(item) }
                        .buttonStyle(.plain).accessibilityIdentifier("conversation.\(item.id.uuidString.lowercased())")
                }
                if model.listCursor != nil {
                    Button(tr("Загрузить ещё")) { Task { await model.refreshConversations(more: true) } }.frame(minHeight: 44)
                }
            }
        }.padding(.horizontal, 16).padding(.bottom, 20)
    }
    private func select(_ id: UUID, wide: Bool) {
        if wide { selected = id }
        else { app.navigate(.conversation(id)) }
    }
    private var serverName: some View {
        Text(model.account.server.displayName).fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(tr("Адрес сервера")).accessibilityValue(model.account.server.displayName)
    }
    private var connectionStatus: some View {
        Label(tr(model.realtimeState == .connected ? "Подключено" : "Переподключение…"),
              systemImage: model.realtimeState == .connected ? "checkmark.circle" : "arrow.triangle.2.circlepath")
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("messages.connectionStatus")
    }
    private func row(_ item: Conversation) -> some View {
        HStack(spacing: 12) {
            Avatar(String(item.title.prefix(2)).uppercased(), size: 44)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    if item.isGroup { Image(systemName: "person.2").foregroundStyle(MSTheme.accent).accessibilityHidden(true) }
                    Text(item.title).font(MSTheme.font(14, weight: .semibold)).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    Spacer(minLength: 0)
                    if let time = item.lastMessageAt { Text(time, style: .time).font(MSTheme.font(10)).foregroundStyle(MSTheme.muted) }
                }
                HStack {
                    Text(item.preview.isEmpty ? tr("Пока нет сообщений") : item.preview).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                    Spacer(minLength: 0)
                    if item.unreadCount > 0 {
                        Text("\(item.unreadCount)").font(MSTheme.font(11, weight: .semibold)).foregroundStyle(MSTheme.surface)
                            .padding(7).background(MSTheme.accent, in: Capsule())
                    }
                }
            }
        }.msCard(padding: 14).accessibilityElement(children: .combine)
    }
}

struct LiveThreadView: View {
    @Bindable var model: MessagingModel
    let id: UUID
    var calls: DirectCallCoordinator?
    @State private var importing = false
    @State private var groupDetails = false
    @State private var query = ""
    @State private var showsSearch = false
    @State private var deleting: ChatMessage?
    @Environment(\.dynamicTypeSize) private var typeSize
    private var threadHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Avatar(String((model.conversation?.title ?? "").prefix(2)).uppercased(), size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.conversation?.title ?? tr("Чат"))
                        .font(MSTheme.font(16, weight: .semibold))
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                    if let count = model.conversation?.memberCount {
                        Text("\(tr("Участники")): \(count)").font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
                    }
                }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                if !typeSize.isAccessibilitySize { threadActions }
            }
            if typeSize.isAccessibilitySize { threadActions.frame(maxWidth: .infinity, alignment: .trailing) }
        }.padding(16).background(MSTheme.surface)
    }
    private var threadActions: some View {
        HStack(spacing: 12) {
            if model.conversation?.type == "direct", let peer = model.conversation?.peer, let calls {
                IconButton("phone", label: "Аудиозвонок") {
                    Task { await calls.startOutgoing(peer: DirectCallPeer(id: peer.id, displayName: peer.displayName)) }
                }.fixedSize().accessibilityIdentifier("startAudioCall")
                IconButton("video", label: "Видеозвонок") {
                    Task { await calls.startOutgoing(peer: DirectCallPeer(id: peer.id, displayName: peer.displayName), isVideo: true) }
                }.fixedSize().accessibilityIdentifier("startVideoCall")
            }
            IconButton("magnifyingglass", label: "Поиск сообщений") { showsSearch.toggle(); query = "" }.fixedSize()
            if model.conversation?.isGroup == true {
                IconButton("info.circle", label: "О группе") { groupDetails = true }.fixedSize()
            }
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            threadHeader
            if let error = calls?.error, calls?.isActive != true {
                Text(tr(error)).font(MSTheme.font(12)).foregroundStyle(MSTheme.danger).padding(.horizontal, 16)
            }
            if showsSearch {
                SearchBox(text: $query, placeholder: "Поиск сообщений").padding(12)
                Text(tr("Введите минимум 2 символа.")).font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if showsSearch && !query.isEmpty {
                            if model.searching { ProgressView() }
                            ForEach(model.searchResults) { message in bubble(message) }
                            if !model.searching && model.searchResults.isEmpty { Text(tr("Сообщения не найдены")).foregroundStyle(MSTheme.muted) }
                            if model.searchCursor != nil {
                                Button(tr("Загрузить ещё")) { Task { await model.searchMessages(query, more: true) } }
                            }
                        } else {
                            if model.historyCursor != nil {
                                Button(tr("Более ранние сообщения")) { Task { await model.loadOlder() } }
                                    .frame(minHeight: 44).disabled(model.historyLoadingMore)
                            }
                            if model.historyState == .loading { ProgressView() }
                            if model.historyState == .failed || model.historyState == .offline {
                                Button(tr("Повторить")) { Task { await model.reloadHistory(id) } }.buttonStyle(MSButtonStyle(primary: false))
                            }
                            if model.historyState == .empty { Text(tr("Пока нет сообщений")).foregroundStyle(MSTheme.muted) }
                            ForEach(model.timeline.messages) { message in bubble(message).id(message.id) }
                            ForEach(model.pending.filter { $0.conversation == id }) { pending in
                                VStack(alignment: .trailing, spacing: 6) {
                                    Text(pending.draft.text)
                                    Label(tr(pending.failed ? "Не отправлено" : "Отправляем…"), systemImage: pending.failed ? "exclamationmark.circle" : "clock")
                                        .font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
                                    if pending.failed { Button(tr("Повторить отправку")) { model.retry(pending.id) } }
                                }.padding(12).background(MSTheme.accentSoft, in: RoundedRectangle(cornerRadius: 14))
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                            Color.clear.frame(height: 1).id("latest")
                        }
                    }.padding(16)
                }.onChange(of: model.timeline.messages.last?.id) { _, _ in
                    if !showsSearch { proxy.scrollTo("latest", anchor: .bottom) }
                }
                .onChange(of: model.pending.count) { _, _ in if !showsSearch { proxy.scrollTo("latest", anchor: .bottom) } }
            }
            if let error = model.error {
                HStack { Text(tr(error)); Spacer(); Button(tr("Закрыть")) { model.error = nil } }
                    .font(MSTheme.font(12)).foregroundStyle(MSTheme.danger).padding(12)
            }
            if model.conversation?.id == id { composer }
        }.background(MSTheme.background)
            .task(id: id) { await model.open(id) }
            .onDisappear { model.hide(id) }
            .task(id: query) {
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                await model.searchMessages(query)
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): Task { await model.importFiles(urls) }
                case .failure(let error): model.error = userMessage(error)
                }
            }
            .sheet(isPresented: $groupDetails) { GroupDetailsView(model: model, id: id) }
            .confirmationDialog(tr("Удалить сообщение?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button(tr("Удалить"), role: .destructive) {
                    if let message = deleting { Task { await model.delete(message) } }; deleting = nil
                }
            }
    }
    private var composer: some View {
        VStack(spacing: 8) {
            if let context = model.editing ?? model.reply {
                HStack {
                    VStack(alignment: .leading) {
                        Text(tr(model.editing != nil ? "Редактирование" : "Ответ")).font(MSTheme.font(11, weight: .semibold)).foregroundStyle(MSTheme.accent)
                        Text(context.text).font(MSTheme.font(12)).lineLimit(2)
                    }
                    Spacer()
                    IconButton("xmark", label: "Отменить") { model.reply = nil; model.editing = nil; model.text = "" }
                }
            }
            ForEach(model.uploads) { upload in
                HStack {
                    VStack(alignment: .leading) {
                        Text(upload.file.filename).font(MSTheme.font(12)).lineLimit(1)
                        if let error = upload.error {
                            Text(tr(error)).font(MSTheme.font(11)).foregroundStyle(MSTheme.danger)
                            Button(tr("Повторить")) { model.retryUpload(upload.id) }
                        } else if upload.attachment == nil { ProgressView(value: upload.progress) }
                        else { Label(tr("Файл готов"), systemImage: "checkmark.circle").font(MSTheme.font(11)).foregroundStyle(MSTheme.success) }
                    }
                    Spacer(); IconButton("xmark", label: "Отменить загрузку") { Task { await model.cancelUpload(upload.id) } }
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                IconButton("paperclip", label: "Прикрепить файл") { importing = true }
                    .disabled(model.uploads.count >= 5 || model.editing != nil).accessibilityIdentifier("attachFile")
                TextField(tr("Написать сообщение…"), text: $model.text, axis: .vertical).lineLimit(1...6)
                    .textFieldStyle(.plain).padding(12).background(MSTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("messageComposer")
                IconButton("arrow.up", label: "Отправить") { model.send() }
                    .disabled(!model.canSend).accessibilityIdentifier("sendMessage")
            }
            if !model.uploads.isEmpty { Text(tr("До 5 файлов, каждый до 10 МБ.")).font(MSTheme.font(10)).foregroundStyle(MSTheme.muted) }
        }.padding(12).background(MSTheme.surface)
    }
    private func bubble(_ message: ChatMessage) -> some View {
        let own = message.senderId == model.account.user.id
        return VStack(alignment: .leading, spacing: 6) {
            Text(message.senderName).font(MSTheme.font(11, weight: .semibold)).foregroundStyle(MSTheme.accent)
            if let reply = message.replyPreview, !message.isDeleted {
                VStack(alignment: .leading, spacing: 3) {
                    Text(reply.senderName).font(MSTheme.font(11, weight: .semibold))
                    Text(reply.deleted ? tr("Сообщение удалено") : reply.text).font(MSTheme.font(12)).lineLimit(3)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading).background(MSTheme.line.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
            Text(message.isDeleted ? tr("Сообщение удалено") : message.text).textSelection(.enabled)
            if !message.isDeleted { ForEach(message.attachments) { attachment in attachmentRow(attachment) } }
            HStack {
                Text(message.createdAt, style: .time)
                if message.version > 1 && !message.isDeleted { Text(tr("изменено")) }
            }.font(MSTheme.font(10)).foregroundStyle(MSTheme.muted)
        }.padding(12).frame(maxWidth: 540, alignment: .leading)
            .background(own ? MSTheme.accentSoft : MSTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            .frame(maxWidth: .infinity, alignment: own ? .trailing : .leading)
            .contextMenu {
                if !message.isDeleted && message.call == nil {
                    Button(tr("Ответить"), systemImage: "arrowshape.turn.up.left") { model.reply = message; model.editing = nil }
                }
                if message.canEdit(as: model.account.user.id) {
                    if model.uploads.isEmpty {
                        Button(tr("Редактировать"), systemImage: "pencil") { model.editing = message; model.reply = nil; model.text = message.text }
                    }
                    Button(tr("Удалить"), systemImage: "trash", role: .destructive) { deleting = message }
                }
            }
            .accessibilityIdentifier("message.\(message.id.uuidString.lowercased())")
    }
    private func attachmentRow(_ attachment: Attachment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { model.download(attachment) } label: {
                Label("\(attachment.filename) · \(ByteCountFormatter.string(fromByteCount: attachment.size, countStyle: .file))", systemImage: "arrow.down.doc")
                    .font(MSTheme.font(12)).multilineTextAlignment(.leading)
            }
            if let state = model.downloads[attachment.id] {
                if let url = state.url {
                    ShareLink(item: url) { Label(tr("Сохранить или поделиться"), systemImage: "square.and.arrow.up") }.font(MSTheme.font(12))
                } else if let error = state.error {
                    Text(tr(error)).font(MSTheme.font(11)).foregroundStyle(MSTheme.danger)
                    Button(tr("Повторить")) { model.download(attachment) }
                } else {
                    ProgressView(value: state.progress)
                    Button(tr("Отменить загрузку")) { model.cancelDownload(attachment.id) }.font(MSTheme.font(11))
                }
            }
        }
    }
}
