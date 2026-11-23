import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct LiveMessagesView: View {
    @Bindable var app: AppModel
    @Bindable var model: MessagingModel
    var hasHinge = false
    @State private var creating = false
    @State private var createdConversation: UUID?
    @State private var selected: UUID?
    @State private var searching = false
    @ScaledMetric(relativeTo: .body) private var compactListBottomSpace: CGFloat = 84
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var filter: Binding<ChatFilter> {
        Binding(get: { model.onlyUnread ? .unread : model.groupFilter ? .groups : model.directFilter ? .direct : .all },
                set: { value in model.onlyUnread = value == .unread; model.groupFilter = value == .groups; model.directFilter = value == .direct })
    }

    private var unreadChatBadge: String {
        let chats = model.conversations.filter { $0.unreadCount > 0 }
        // The server total counts messages. A filter or a page can hide other unread chats.
        let unlistedMessages = model.unreadCount - chats.reduce(0) { $0 + $1.unreadCount }
        if unlistedMessages <= 0 { return String(chats.count) }
        let minimumChats = chats.count + 1
        return unlistedMessages == 1 ? String(minimumChats) : "\(minimumChats)+"
    }
    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let wide = WorkspaceLayout.usesColumns(width: width, sizeClass: sizeClass, typeSize: typeSize)
            let detailID = selected ?? (wide && app.messagesPath.isEmpty ? model.conversations.first?.id : nil)
            let detailOnly = !wide && selected != nil
            let gutter = wide ? WorkspaceLayout.chatGutter(width) : 0
            let sidebar = WorkspaceLayout.chatSidebarWidth(width)
            VStack(spacing: 0) {
                if !detailOnly {
                    PageHeader(title: "Чаты") {
                        WorkspaceHeaderButton("magnifyingglass", label: "Поиск чатов") { searching.toggle(); model.listSearch = "" }
                        WorkspaceBell { app.presentWorkspaceNotifications() }
                    }
                }
                HStack(spacing: 0) {
                    if !detailOnly {
                        conversationColumn(wide: wide)
                            .frame(width: wide ? sidebar : nil).background(MSTheme.surface)
                    }
                    if wide { Divider() }
                    if let id = detailID {
                        LiveThreadView(model: model, app: app, id: id, calls: app.identity.calls, embedded: true,
                                       embeddedBack: wide ? nil : { selected = nil }, openRecipient: { selected = $0 },
                                       newChat: wide ? { creating = true } : nil, removed: { selected = nil })
                            .id(id).frame(maxWidth: .infinity)
                            .environment(\.workspaceWidth, wide ? width - sidebar - 2 * gutter - 1 : width)
                            .onAppear { if selected == nil && wide { selected = id } }
                    } else if wide {
                        VStack {
                            ContentUnavailableView(tr("Выберите чат"), systemImage: "bubble.left.and.bubble.right")
                            ChatNewButton { creating = true }.padding()
                        }.frame(maxWidth: .infinity)
                    }
                }.padding(.horizontal, gutter)
            }.background(MSTheme.background)
                .preference(key: InlineChatVisible.self, value: detailOnly)
                .workspaceFormPresentation(isPresented: $creating, onDismiss: {
                    if let createdConversation { select(createdConversation, wide: wide) }
                    createdConversation = nil
                }) { NewConversationView(model: model) { createdConversation = $0 } }
        }.toolbar(.hidden)
        .ignoresSafeArea(model.selectingMessages && !searching ? .keyboard : [], edges: .bottom)
        .task(id: "\(model.listSearch)|\(model.onlyUnread)|\(model.groupFilter)|\(model.directFilter)") {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            await model.refreshConversations()
        }
    }

    @ViewBuilder private func conversationColumn(wide: Bool) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                ChatFilterBar(filter: filter, unread: unreadChatBadge) { app.navigate(.folders) }
                if searching {
                    SearchBox(text: $model.listSearch, placeholder: "Найти человека или чат")
                        .padding(.horizontal, wide ? 16 : 15).padding(.bottom, 16)
                }
                if model.realtimeState == .reconnecting {
                    Label(tr("Переподключение…"), systemImage: "arrow.triangle.2.circlepath")
                        .font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
                        .padding(.bottom, 8).accessibilityIdentifier("messages.connectionStatus")
                }
                conversationRows(wide: wide)
            }
        }.refreshable { await model.refreshConversations() }
        .overlay(alignment: .bottomTrailing) {
            if !wide {
                ChatNewButton(compact: true) { creating = true }
                    .padding(.trailing, 18).padding(.bottom, 17)
            }
        }
    }

    private func conversationRows(wide: Bool) -> some View {
        LazyVStack(spacing: 0) {
            ChatInviteCard(url: model.account.server.url)
            StateContent(state: model.listState, retry: { Task { await model.refreshConversations() } }) {
                ForEach(model.conversations) { item in
                    Button { select(item.id, wide: wide) } label: {
                        let preview = model.conversationPreview(item)
                        ChatListRow(name: item.title, group: item.isGroup,
                                    subtitle: item.isGroup ? item.memberCount.map(chatGroupSubtitle) ?? tr("Групповой чат") : nil,
                                    preview: preview.isEmpty ? tr("Пока нет сообщений") : preview,
                                    time: item.lastMessageAt.map(listTime) ?? "",
                                    unread: item.unreadCount, muted: !item.notificationsEnabled,
                                    selected: wide && (selected ?? model.conversations.first?.id) == item.id)
                    }.buttonStyle(.plain).accessibilityIdentifier("conversation.\(item.id.uuidString.lowercased())")
                }
                if model.listCursor != nil {
                    Button(tr("Загрузить ещё")) { Task { await model.refreshConversations(more: true) } }.frame(minHeight: 44)
                }
            }
            if let error = model.error, !wide {
                Button(tr(error)) { model.error = nil }.foregroundStyle(MSTheme.danger).font(MSTheme.font(12))
            }
        }.padding(.horizontal, 16).padding(.bottom, wide ? 20 : compactListBottomSpace)
    }
    private func listTime(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return tr("Вчера") }
        let today = calendar.startOfDay(for: .now)
        let daysAgo = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day ?? 0
        if (2...6).contains(daysAgo) { return date.formatted(.dateTime.weekday(.abbreviated)) }
        return date.formatted(date: .numeric, time: .omitted)
    }

    private func select(_ id: UUID, wide: Bool) {
        if wide || hasHinge || selected != nil { selected = id }
        else { app.navigate(.conversation(id)) }
    }
}

struct LiveThreadView: View {
    @Bindable var model: MessagingModel
    let app: AppModel
    let id: UUID
    var calls: DirectCallCoordinator?
    var embedded = false
    var embeddedBack: (() -> Void)?
    var openRecipient: ((UUID) -> Void)?
    var newChat: (() -> Void)?
    var removed: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.chatMenu) private var chatMenu
    @FocusState private var composerFocused: Bool
    @State private var coveredConversation: UUID?
    @State private var chatInfo = false
    private enum AfterInfo { case edit, call(DirectCallPeer, video: Bool) }
    @State private var afterInfo: AfterInfo?
    @State private var menuOpen = false
    @State private var ownCard = false
    @State private var folders = false
    @State private var headerActionBusy = false
    @State private var pendingChatAction: ChatHeaderAction?
    @State private var importing = false
    @State private var groupDetails = false
    @State private var query = ""
    @State private var showsSearch = false
    @State private var deleting: ChatMessage?
    @State private var localDelete = false
    @State private var forwardingMessage: ChatMessage?
    @State private var forwardedDestination: UUID?
    #if canImport(UIKit)
    @State private var sharing: MessageShareRequest?
    #endif
    private var selectedShareText: String { model.selectedMessages.map { "\($0.senderName):\n\($0.shareText)" }.joined(separator: "\n\n") }
    private var threadHeader: some View {
        ChatThreadHeading(name: model.conversation?.title ?? tr("Чат"),
                          subtitle: model.conversation?.isGroup == true ? model.conversation?.memberCount.map(chatGroupSubtitle) : nil,
                          group: model.conversation?.isGroup == true, back: embedded ? embeddedBack : { dismiss() },
                          info: showDetails) {
            if let peer = model.conversation?.peer, let calls {
                Button {
                    Task { await calls.startOutgoing(peer: DirectCallPeer(id: peer.id, displayName: peer.displayName)) }
                } label: { ChatHeaderIcon(name: "phone") }
                    .buttonStyle(.plain).accessibilityLabel(tr("Аудиозвонок")).accessibilityIdentifier("startAudioCall")
            }
            Button { showsSearch.toggle(); query = "" } label: { ChatHeaderIcon(name: "magnifyingglass") }
                .buttonStyle(.plain).accessibilityLabel(tr("Поиск сообщений"))
            ChatActionTrigger(active: menuOpen) {
                composerFocused = false
                menuOpen.toggle()
            }.disabled(headerActionBusy || model.conversation?.id != id)
        }
    }
    private func chooseHeaderAction(_ action: ChatHeaderAction) {
        guard let item = model.conversation, item.id == id else { return }
        switch action {
        case .info: showDetails()
        case .selfCard: ownCard = true
        case .select: beginSelection()
        case .edit: if item.canManage { groupDetails = true }
        case .mute: applyHeaderAction(.mute)
        case .folder: folders = true
        case .leave where item.myRole == "owner": groupDetails = true
        case .clear, .hide, .leave: pendingChatAction = action
        }
    }
    private func applyHeaderAction(_ action: ChatHeaderAction) {
        guard !headerActionBusy else { return }
        headerActionBusy = true
        let sourceTab = app.tab
        Task {
            defer { headerActionBusy = false }
            do {
                try await model.applyHeaderAction(action, to: id)
                guard model.active else { return }
                if action == .clear, model.conversation?.id == id { showsSearch = false; query = "" }
                if action == .hide || action == .leave {
                    if embedded {
                        if model.conversation == nil { removed?() }
                    } else {
                        let route = AppRoute.conversation(id)
                        switch sourceTab {
                        case .messages where app.messagesPath.last == route: app.messagesPath.removeLast()
                        case .meetings where app.meetingsPath.last == route: app.meetingsPath.removeLast()
                        case .profile where app.profilePath.last == route: app.profilePath.removeLast()
                        default: break
                        }
                    }
                }
            } catch is CancellationError { }
            catch { if model.active, model.conversation?.id == id { model.error = userMessage(error) } }
        }
    }
    private func showDetails() {
        guard let item = model.conversation, item.id == id, item.isGroup || item.peer != nil else { return }
        composerFocused = false
        chatInfo = true
    }
    private func beginSelection(_ message: ChatMessage? = nil) {
        // Resign the native input before replacing it with the selection toolbar.
        // Removing a focused text field can leave its keyboard inset on the iPad split view.
        #if os(iOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
        composerFocused = false
        showsSearch = false
        query = ""
        model.beginMessageSelection(message)
    }
    var body: some View {
        VStack(spacing: 0) {
            if model.selectingMessages {
                ChatSelectionHeader(count: model.selectedMessages.count,
                                    allSelected: !model.selectableMessages.isEmpty && model.selectedMessages.count == model.selectableMessages.count,
                                    cancel: model.cancelMessageSelection, toggleAll: model.toggleAllMessages)
                    .disabled(model.hidingMessages)
            } else { threadHeader }
            if let error = calls?.error, calls?.isActive != true {
                Text(tr(error)).font(MSTheme.font(12)).foregroundStyle(MSTheme.danger).padding(.horizontal, 16)
            }
            if showsSearch {
                SearchBox(text: $query, placeholder: "Поиск сообщений").padding(12)
                Text(tr("Введите минимум 2 символа.")).font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
            }
            ScrollViewReader { proxy in
                let pins = model.timeline.messages.filter { $0.pinned && $0.isActionable }
                if !showsSearch, let first = pins.first {
                    ChatPinnedBar(preview: first.shareText, count: pins.count) { proxy.scrollTo(first.id, anchor: .center) }
                }
                ScrollView {
                    LazyVStack(spacing: embedded ? 18 : 14) {
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
                            if let first = model.timeline.messages.first {
                                Text(first.createdAt.formatted(date: .long, time: .omitted)).font(MSTheme.font(10)).foregroundStyle(MSTheme.muted).frame(minHeight: 15)
                                if !embedded || model.selectingMessages { ChatGestureHint(selecting: model.selectingMessages).padding(.vertical, 4) }
                            }
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
                    }.padding(.horizontal, embedded ? 24 : 12).padding(.top, embedded ? 20 : 18).padding(.bottom, 8)
                }.onChange(of: model.timeline.messages.last?.id) { _, _ in
                    if !showsSearch { proxy.scrollTo("latest", anchor: .bottom) }
                }
                .onChange(of: model.pending.count) { _, _ in if !showsSearch { proxy.scrollTo("latest", anchor: .bottom) } }
            }
            if let error = model.error {
                HStack { Text(tr(error)); Spacer(); Button(tr("Закрыть")) { model.error = nil } }
                    .font(MSTheme.font(12)).foregroundStyle(MSTheme.danger).padding(12)
            }
            if model.selectingMessages {
                ChatSelectionBar(count: model.selectedMessages.count, remove: { model.error = nil; localDelete = true }) { selectedShare }
                    .disabled(model.hidingMessages)
            } else if model.conversation?.id == id {
                if let newChat { ChatNewButton(action: newChat).frame(maxWidth: .infinity, alignment: .trailing).padding(.horizontal, 24).padding(.vertical, 10) }
                composer
            }
        }.background(MSTheme.background).toolbar(.hidden)
            .chatHeaderMenu(open: $menuOpen, group: model.conversation?.isGroup == true,
                            editable: model.conversation?.canManage == true, muted: model.conversation?.notificationsEnabled == false,
                            perform: chooseHeaderAction)
            .confirmChatAction($pendingChatAction, perform: applyHeaderAction)
            .task(id: id) {
                let resuming = coveredConversation == id
                coveredConversation = nil
                if !resuming || model.historyState == .loading { await model.open(id) }
            }
            .onDisappear {
                guard model.conversation?.id == id else { return }
                // Full-screen chat sheets cover the thread temporarily. Keep its loaded history and selection.
                if chatMenu?.isPresented == true || chatInfo { coveredConversation = id }
                else { model.hide(id); model.cancelMessageSelection() }
            }
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
            .sheet(isPresented: $ownCard) {
                let user = app.identity.settings?.profile ?? model.account.user
                ChatOwnCard(name: user.name, email: user.email, bio: user.bio, photo: app.identity.settings?.photo)
            }
            .sheet(isPresented: $folders) {
                if let folderModel = app.identity.folders, let item = model.conversation, item.id == id {
                    WorkspaceFolderPicker(model: folderModel, kind: .conversation, id: id, title: item.title)
                }
            }
            .sheet(isPresented: $groupDetails) { GroupDetailsView(model: model, id: id) }
            .workspaceFormPresentation(isPresented: $chatInfo, onDismiss: {
                let next = afterInfo
                afterInfo = nil
                guard model.active, model.conversation?.id == id else { return }
                switch next {
                case .edit: groupDetails = model.conversation?.canManage == true
                case .call(let peer, let video): Task { await calls?.startOutgoing(peer: peer, isVideo: video) }
                case nil: break
                }
            }) {
                if let conversation = model.conversation, conversation.id == id {
                    if conversation.isGroup {
                        LiveChatGroupSheet(model: model, conversation: conversation) {
                            afterInfo = .edit
                            chatInfo = false
                        }
                    } else if let peer = conversation.peer {
                        LiveChatContactSheet(model: model, conversation: conversation, peer: peer, startCall: calls == nil ? nil : { video in
                            afterInfo = .call(DirectCallPeer(id: peer.id, displayName: peer.displayName), video: video)
                            chatInfo = false
                        })
                    }
                } else {
                    Color.clear.onAppear { afterInfo = nil; chatInfo = false }
                }
            }
            .sheet(item: $forwardingMessage, onDismiss: {
                if let target = forwardedDestination, target != id { openRecipient?(target) }
                forwardedDestination = nil
            }) { message in
                MessageForwardView(model: model, messages: [message]) { forwardedDestination = $0 }
            }
            .sheet(isPresented: $localDelete) { localDeleteSheet }
            #if canImport(UIKit)
            .sheet(item: $sharing) { request in
                MessageActivitySheet(request: request) { sharing = nil }
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            #endif
            .onChange(of: model.selectedMessages.count) { _, count in if count == 0 { localDelete = false } }
            .confirmationDialog(tr("Удалить сообщение?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button(tr("Удалить для всех"), role: .destructive) {
                    if let message = deleting { Task { await model.delete(message) } }; deleting = nil
                }
            } message: { Text(tr("Сообщение будет удалено для участников чата.")) }
    }
    private var selectedShare: some View {
        Group {
            #if canImport(UIKit)
            Button { sharing = MessageShareRequest(payload: .text(selectedShareText)) } label: {
                Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44)
            }
            #else
            ShareLink(item: selectedShareText) { Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44) }
            #endif
        }.accessibilityLabel(tr("Поделиться")).disabled(model.selectedMessages.isEmpty || model.hidingMessages).accessibilityIdentifier("message.shareSelected")
    }
    private var localDeleteSheet: some View {
        ChatDeleteConfirmation(count: model.selectedMessages.count, busy: model.hidingMessages, error: model.error,
                               confirm: { Task { if await model.hideSelectedMessages() { localDelete = false } } },
                               cancel: { localDelete = false })
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
                Button { importing = true } label: { WorkspaceIcon("paperclip", size: 22).frame(width: 48, height: 48) }
                    .buttonStyle(.plain).accessibilityLabel(tr("Прикрепить файл"))
                    .disabled(model.uploads.count >= 5 || model.editing != nil).accessibilityIdentifier("attachFile")
                TextField(tr("Написать сообщение…"), text: $model.text, axis: .vertical).lineLimit(1...6)
                    .focused($composerFocused)
                    .font(MSTheme.font(13)).textFieldStyle(.plain).padding(12).frame(minHeight: 48)
                    .background(MSTheme.background, in: RoundedRectangle(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(MSTheme.line) }
                    .accessibilityIdentifier("messageComposer")
                Button { model.send() } label: {
                    WorkspaceIcon("arrow.up", size: 22)
                }.buttonStyle(ChatSendButtonStyle()).accessibilityLabel(tr("Отправить"))
                    .disabled(!model.canSend).accessibilityIdentifier("sendMessage")
            }
            if !model.uploads.isEmpty { Text(tr("До 5 файлов, каждый до 10 МБ.")).font(MSTheme.font(10)).foregroundStyle(MSTheme.muted) }
        }.padding(.horizontal, embedded ? 24 : 10).padding(.vertical, embedded ? 12 : 10).background(MSTheme.surface)
            .overlay(alignment: .top) { Rectangle().fill(MSTheme.line).frame(height: 1) }
    }
    private func bubble(_ message: ChatMessage) -> some View {
        let own = message.senderId == model.account.user.id
        return ChatMessageRow(own: own, author: message.senderName, time: message.createdAt.formatted(date: .omitted, time: .shortened),
                              selecting: model.selectingMessages, selected: model.selectedMessageIDs.contains(message.id),
                              actionable: message.isActionable, pinned: message.pinned && !message.isDeleted,
                              edited: message.version > 1 && !message.isDeleted, forwarded: message.isDeleted ? nil : message.forwardedFrom?.senderName,
                              identifier: message.id.uuidString.lowercased(), summary: message.text, attachments: message.attachments.map(\.filename),
                              toggle: { model.toggleMessageSelection(message.id) }) {
            if let reply = message.replyPreview, !message.isDeleted, !model.hiddenMessageIDs.contains(reply.id) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(reply.senderName).font(MSTheme.font(11, weight: .semibold))
                    Text(reply.deleted ? tr("Сообщение удалено") : reply.text).font(MSTheme.font(12)).lineLimit(3)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading).background(MSTheme.line.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    .allowsHitTesting(false)
            }
            ChatMessageText(text: message.isDeleted ? tr("Сообщение удалено") : message.text)
            if !message.isDeleted { ForEach(message.attachments) { attachment in attachmentRow(attachment) } }
        } actions: {
                if message.isActionable && !model.selectingMessages {
                    ChatMessageCommand("Ответить", systemImage: "arrowshape.turn.up.left") { model.reply = message; model.editing = nil }
                    ChatMessageCommand("Копировать", systemImage: "doc.on.doc") {
                        #if canImport(UIKit)
                        UIPasteboard.general.string = message.shareText
                        #elseif canImport(AppKit)
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.shareText, forType: .string)
                        #endif
                    }
                    ChatMessageCommand("Переслать", systemImage: "arrowshape.turn.up.right") { forwardingMessage = message }
                        .accessibilityIdentifier("message.forwardAction")
                    ChatMessageCommand("Выбрать", systemImage: "checkmark.circle") { beginSelection(message) }
                    ChatMessageCommand(message.pinned ? "Открепить" : "Закрепить", systemImage: "pin") { Task { await model.pin(message) } }
                    ChatMenuShareButton(text: message.shareText)
                }
                if message.canEdit(as: model.account.user.id) && !model.selectingMessages {
                    if model.uploads.isEmpty {
                        ChatMessageCommand("Редактировать", systemImage: "pencil") { model.editing = message; model.reply = nil; model.text = message.text }
                    }
                }
                if own && message.isActionable && !model.selectingMessages {
                    ChatMessageCommand("Удалить для всех", systemImage: "trash", role: .destructive) { deleting = message }
                }
        }
    }
    private func attachmentRow(_ attachment: Attachment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { model.download(attachment) } label: {
                ChatFileCard(name: attachment.filename, size: ByteCountFormatter.string(fromByteCount: attachment.size, countStyle: .file))
            }.buttonStyle(.plain).padding(.top, 5)
            if let state = model.downloads[attachment.id] {
                if let url = state.url {
                    #if canImport(UIKit)
                    Button { sharing = MessageShareRequest(payload: .file(url)) } label: {
                        Label(tr("Сохранить или поделиться"), systemImage: "square.and.arrow.up")
                    }.font(MSTheme.font(12))
                    #else
                    ShareLink(item: url) { Label(tr("Сохранить или поделиться"), systemImage: "square.and.arrow.up") }.font(MSTheme.font(12))
                    #endif
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

#if canImport(UIKit)
/// Snapshot the requested content so selection changes cannot alter an open activity sheet.
struct MessageShareRequest: Identifiable {
    enum Payload { case text(String), file(URL) }
    let id = UUID()
    let payload: Payload
    var activityItems: [Any] {
        switch payload { case .text(let text): [text]; case .file(let url): [url] }
    }
}

/// Present from the thread's sheet, avoiding a popover constrained below its bottom toolbar.
struct MessageActivitySheet: UIViewControllerRepresentable {
    let request: MessageShareRequest
    let didFinish: @MainActor () -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: request.activityItems, applicationActivities: nil)
        let completion = didFinish
        controller.completionWithItemsHandler = { _, _, _, _ in
            Task { @MainActor in completion() }
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
