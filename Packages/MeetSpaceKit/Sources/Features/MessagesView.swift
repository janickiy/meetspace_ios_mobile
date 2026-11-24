import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private extension DemoChatStore.Message {
    var displayText: String { deleted ? tr("Сообщение удалено") : text }
}

struct MessagesView: View {
    @Bindable var model: AppModel
    var hasHinge = false
    @State private var query = ""
    @State private var searching = false
    @State private var selected: Int?
    @State private var filter = ChatFilter.all
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var contacts: [DemoChatStore.Contact] {
        model.demoChats.visibleContacts.filter { item in
            let matchesFilter = switch filter {
            case .all: true
            case .direct: !item.group
            case .groups: item.group
            case .unread: item.unread > 0
            }
            return matchesFilter && (query.isEmpty || item.name.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let wide = WorkspaceLayout.usesColumns(width: width, sizeClass: sizeClass, typeSize: typeSize, hasHinge: hasHinge)
            let selectedID = model.demoChats.visibleContacts.first(where: { $0.id == selected })?.id
            let detailID = selectedID ?? (wide && model.messagesPath.isEmpty ? model.demoChats.visibleContacts.first?.id : nil)
            let detailOnly = !wide && selectedID != nil
            let gutter = wide ? WorkspaceLayout.chatGutter(width) : 0
            let sidebar = WorkspaceLayout.chatSidebarWidth(width)
            VStack(spacing: 0) {
                if !detailOnly {
                    PageHeader(title: "Чаты") {
                        WorkspaceHeaderButton("magnifyingglass", label: "Поиск чатов") { searching.toggle(); query = "" }
                        WorkspaceBell { model.presentWorkspaceNotifications() }
                    }
                }
                HStack(spacing: 0) {
                    if !detailOnly {
                        ScrollView {
                            VStack(spacing: 0) {
                                ChatFilterBar(filter: $filter, unread: String(model.demoChats.visibleContacts.filter { $0.unread > 0 }.count)) { model.navigate(.folders) }
                                if searching {
                                    SearchBox(text: $query, placeholder: "Найти человека или чат")
                                        .padding(.horizontal, wide ? 16 : 15).padding(.bottom, 16)
                                }
                                StateContent(state: model.contentState, retry: { model.contentState = .content }) {
                                    LazyVStack(spacing: 0) {
                                        if let demoInvite = URL(string: "https://meet.example.org/room/design") {
                                            ChatInviteCard(url: demoInvite)
                                        }
                                        ForEach(contacts) { item in
                                            Button {
                                                if wide || hasHinge || ChatLayout.keepsSelectionInline { selected = item.id }
                                                else { model.navigate(.thread(item.id)) }
                                            } label: {
                                                let last = model.demoChats.history[item.id]?.last
                                                let changed = model.demoChats.updated.contains(item.id)
                                                ChatListRow(name: item.name, initials: item.initials, group: item.group,
                                                            subtitle: item.subtitle,
                                                            preview: changed ? last?.displayText ?? tr("Пока нет сообщений") : item.preview,
                                                            time: changed ? last?.time ?? "" : item.time,
                                                            unread: item.unread, muted: model.demoChats.muted.contains(item.id),
                                                            selected: wide && detailID == item.id)
                                            }.buttonStyle(.plain).accessibilityIdentifier("chat.\(item.id)")
                                        }
                                        if contacts.isEmpty { Text(tr("Чат не найден")).font(MSTheme.font(13)).padding() }
                                    }.padding(.horizontal, 16).padding(.bottom, wide ? 0 : 80)
                                }
                            }
                        }.overlay(alignment: .bottomTrailing) {
                            if !wide { newChat.padding(.trailing, 18).padding(.bottom, 17) }
                        }.frame(width: wide ? sidebar : nil).background(MSTheme.surface)
                    }
                    if wide { Divider() }
                    if let id = detailID {
                        ThreadView(model: model, personIndex: id, embedded: true,
                                   embeddedBack: wide ? nil : { selected = nil }, openRecipient: { selected = $0 },
                                   removed: { selected = nil })
                            .id(id).frame(maxWidth: .infinity)
                            .environment(\.chatPaneWidth, wide ? width - sidebar - 2 * gutter - 1 : width)
                            .onAppear { if selected == nil && wide { selected = id } }
                    } else if wide {
                        ContentUnavailableView(tr("Выберите чат"), systemImage: "bubble.left.and.bubble.right")
                    }
                }
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: width >= 780 ? 24 : 0,
                                                  topTrailingRadius: width >= 780 ? 24 : 0))
                .padding(.horizontal, gutter)
            }
        }.background(MSTheme.background).toolbar(.hidden)
    }

    private var newChat: some View {
        ChatNewButton(compact: true) { model.notice = "Новые чаты станут доступны после входа." }
    }
}

struct ThreadView: View {
    private enum ComposerContext {
        case reply(UUID), edit(UUID)
        var id: UUID {
            switch self { case .reply(let id), .edit(let id): id }
        }
        var editing: Bool { if case .edit = self { true } else { false } }
    }

    @Bindable var model: AppModel
    var personIndex = 0
    var embedded = false
    var embeddedBack: (() -> Void)?
    var openRecipient: ((Int) -> Void)?
    var removed: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.workspaceWidth) private var width
    @State private var draft = ""
    @State private var draftBeforeEdit: String?
    @State private var composerContext: ComposerContext?
    @FocusState private var composerFocused: Bool
    @State private var selecting = false
    @State private var selected: Set<UUID> = []
    @State private var confirmingDelete = false
    @State private var deleting: DemoChatStore.Message?
    @State private var forwarding: DemoChatStore.Message?
    @State private var forwardedDestination: Int?
    @State private var info = false
    @State private var callAfterInfo = false
    @State private var menuOpen = false
    @State private var ownCard = false
    @State private var folders = false
    @State private var pendingChatAction: ChatHeaderAction?
    @State private var searching = false
    @State private var query = ""
    @State private var recipientQuery = ""

    private var contact: DemoChatStore.Contact { DemoChatStore.contacts.first { $0.id == personIndex } ?? DemoChatStore.contacts[0] }
    private var messages: [DemoChatStore.Message] { model.demoChats.history[personIndex] ?? [] }
    private var selectableIDs: Set<UUID> { Set(messages.filter { !$0.deleted }.map(\.id)) }
    private var selectedText: String { messages.filter { selected.contains($0.id) }.map { "\($0.author):\n\($0.shareText)" }.joined(separator: "\n\n") }

    var body: some View {
        VStack(spacing: 0) {
            if selecting {
                ChatSelectionHeader(count: selected.count, allSelected: !selected.isEmpty && selected == selectableIDs,
                                    cancel: endSelection, toggleAll: { selected = selected == selectableIDs ? [] : selectableIDs })
            } else {
                ChatThreadHeading(name: contact.name, initials: contact.initials, subtitle: contact.subtitle ?? tr("В сети"),
                                  group: contact.group, back: embedded ? embeddedBack : { dismiss() }, info: { info = true }) {
                    if !contact.group {
                        Button { model.navigate(.contactCall(personIndex)) } label: { ChatHeaderIcon(name: "phone") }
                            .buttonStyle(.plain).accessibilityLabel(tr("Личный звонок"))
                    }
                    Button { searching.toggle(); query = "" } label: { ChatHeaderIcon(name: "magnifyingglass") }
                        .buttonStyle(.plain).accessibilityLabel(tr("Поиск сообщений"))
                    ChatActionTrigger(active: menuOpen) {
                        composerFocused = false
                        menuOpen.toggle()
                    }
                }
            }
            if searching { SearchBox(text: $query, placeholder: "Поиск сообщений").padding(10) }
            ScrollViewReader { proxy in
                let pins = messages.filter(\.pinned)
                if let first = pins.first { ChatPinnedBar(preview: first.text, count: pins.count) { proxy.scrollTo(first.id, anchor: .center) } }
                ScrollView {
                    LazyVStack(spacing: width >= 780 ? 18 : 14) {
                        Text(tr("Сегодня, 16 октября")).font(MSTheme.font(10)).foregroundStyle(MSTheme.muted).frame(minHeight: 15)
                        if !messages.isEmpty && (width < 780 || selecting) { ChatGestureHint(selecting: selecting).padding(.vertical, 4) }
                        let results = messages.filter { query.isEmpty || (!$0.deleted && $0.shareText.localizedCaseInsensitiveContains(query)) }
                        ForEach(results) { message in
                            bubble(message).id(message.id)
                        }
                        if results.isEmpty { Text(tr(query.isEmpty ? "Пока нет сообщений" : "Сообщения не найдены")).foregroundStyle(MSTheme.muted) }
                    }.padding(.horizontal, width >= 780 ? 24 : 12).padding(.top, width >= 780 ? 20 : 18).padding(.bottom, 8)
                }.task(id: messages.last?.id) {
                    if let last = messages.last, last.forwarded != nil || last.replyTo != nil { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            if selecting {
                ChatSelectionBar(count: selected.count, remove: { confirmingDelete = true }) {
                    ShareLink(item: selectedText) { Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44) }
                        .accessibilityLabel(tr("Поделиться")).disabled(selected.isEmpty).accessibilityIdentifier("message.shareSelected")
                }
            } else {
                if embedded && embeddedBack == nil {
                    ChatNewButton { model.notice = "Новые чаты станут доступны после входа." }
                        .frame(maxWidth: .infinity, alignment: .trailing).padding(.horizontal, 24).padding(.vertical, 10)
                }
                composer
            }
        }.background(MSTheme.background).toolbar(.hidden)
            .chatHeaderMenu(open: $menuOpen, group: contact.group, muted: model.demoChats.muted.contains(personIndex), perform: chooseHeaderAction)
            .confirmChatAction($pendingChatAction, perform: confirmHeaderAction)
            .sheet(isPresented: $ownCard) {
                ChatOwnCard(name: model.demoProfile.name, email: model.demoProfile.email, bio: model.demoProfile.bio, photo: model.demoProfile.photo)
            }
            .sheet(isPresented: $folders) {
                WorkspaceFolderPicker(demo: model.demoFolders, item: .chat(personIndex), title: contact.name)
            }
            .sheet(item: $forwarding, onDismiss: {
                if let target = forwardedDestination, target != personIndex {
                    if let openRecipient { openRecipient(target) } else { model.navigate(.thread(target)) }
                }
                forwardedDestination = nil
            }) { item in recipientPicker(item) }
            .sheet(isPresented: $confirmingDelete) {
                ChatDeleteConfirmation(count: selected.count, confirm: {
                    model.demoChats.remove(selected, in: personIndex); endSelection(); confirmingDelete = false
                }, cancel: { confirmingDelete = false })
            }
            .confirmationDialog(tr("Удалить сообщение?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { message in
                Button(tr("Удалить для всех"), role: .destructive) {
                    if composerContext?.id == message.id { clearComposerContext() }
                    model.demoChats.deleteOwn(message.id, in: personIndex)
                }
                Button(tr("Отмена"), role: .cancel) {}
            }
            .workspaceFormPresentation(isPresented: $info, onDismiss: {
                if callAfterInfo {
                    callAfterInfo = false
                    model.navigate(.contactCall(personIndex))
                }
            }) {
                DemoChatInfoSheet(contact: contact, messages: messages) {
                    callAfterInfo = true
                    info = false
                }
            }
    }

    private func chooseHeaderAction(_ action: ChatHeaderAction) {
        switch action {
        case .info: info = true
        case .selfCard: ownCard = true
        case .select: select(nil)
        case .mute: model.demoChats.toggleMute(personIndex)
        case .folder: folders = true
        case .clear, .hide, .leave: pendingChatAction = action
        case .edit: break
        }
    }

    private func confirmHeaderAction(_ action: ChatHeaderAction) {
        switch action {
        case .clear:
            model.demoChats.clearHistory(personIndex)
            clearComposerContext()
            endSelection()
            query = ""; searching = false
        case .hide, .leave:
            model.demoFolders.remove(.chat(personIndex))
            model.demoChats.removeConversation(personIndex)
            if embedded { removed?() } else { dismiss() }
        default: break
        }
    }

    private func bubble(_ message: DemoChatStore.Message) -> some View {
        ChatMessageRow(own: message.own, author: message.author, time: message.time,
                       selecting: selecting, selected: selected.contains(message.id), actionable: !message.deleted,
                       pinned: message.pinned, edited: message.edited, forwarded: message.forwarded,
                       identifier: message.id.uuidString.lowercased(), summary: message.displayText, attachments: message.files, photoAlbum: DemoChatAttachments.containsPhoto(message.files),
                       reaction: message.reaction, react: { emoji in model.demoChats.toggleReaction(emoji, for: message.id, in: personIndex) },
                       toggle: { if !selected.insert(message.id).inserted { selected.remove(message.id) } }) {
            if let id = message.replyTo, let original = messages.first(where: { $0.id == id }) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(original.author).font(MSTheme.font(11, weight: .semibold))
                    Text(original.displayText).font(MSTheme.font(12)).lineLimit(3)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading).background(MSTheme.line.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    .allowsHitTesting(false)
            }
            ChatMessageText(text: message.displayText)
            if !message.files.isEmpty { DemoChatAttachments(files: message.files) }
        } actions: {
            if !message.deleted && !selecting {
                ChatMessageCommand("Ответить", systemImage: "arrowshape.turn.up.left") {
                    clearComposerContext()
                    composerContext = .reply(message.id)
                    composerFocused = true
                }
                ChatMessageCommand("Копировать", systemImage: "doc.on.doc") {
                    #if canImport(UIKit)
                    UIPasteboard.general.string = message.shareText
                    #elseif canImport(AppKit)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.shareText, forType: .string)
                    #endif
                }
                ChatMessageCommand("Переслать", systemImage: "arrowshape.turn.up.right") { recipientQuery = ""; forwarding = message }
                    .accessibilityIdentifier("message.forwardAction")
                ChatMessageCommand("Выбрать", systemImage: "checkmark.circle") { select(message.id) }
                ChatMessageCommand(message.pinned ? "Открепить" : "Закрепить", systemImage: "pin") { model.demoChats.togglePin(message.id, in: personIndex) }
                ChatMenuShareButton(text: message.shareText)
                if message.canEdit {
                    ChatMessageCommand("Редактировать", systemImage: "pencil") {
                        if draftBeforeEdit == nil { draftBeforeEdit = draft }
                        composerContext = .edit(message.id)
                        draft = message.text
                        composerFocused = true
                    }
                }
                if message.own {
                    ChatMessageCommand("Удалить для всех", systemImage: "trash", role: .destructive) { deleting = message }
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if let context = composerContext, let message = messages.first(where: { $0.id == context.id }) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(tr(context.editing ? "Редактирование" : "Ответ")).font(MSTheme.font(11, weight: .semibold)).foregroundStyle(MSTheme.accent)
                        Text(message.text).font(MSTheme.font(12)).lineLimit(2)
                    }
                    Spacer()
                    IconButton("xmark", label: "Отменить") { clearComposerContext() }
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                Button { showDemoNotice() } label: {
                    WorkspaceIcon("paperclip", size: 22).frame(width: 48, height: 48)
                }.buttonStyle(.plain).accessibilityLabel(tr("Прикрепить файл")).disabled(composerContext?.editing == true)
                TextField(tr("Написать сообщение…"), text: $draft, axis: .vertical).lineLimit(1...5).textFieldStyle(.plain)
                    .focused($composerFocused).font(MSTheme.font(13)).padding(12).frame(minHeight: 48)
                    .background(MSTheme.background, in: RoundedRectangle(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(MSTheme.line) }.accessibilityIdentifier("messageDraft")
                Button(action: submitDraft) { WorkspaceIcon("arrow.up", size: 22) }
                    .buttonStyle(ChatSendButtonStyle()).accessibilityLabel(tr(composerContext?.editing == true ? "Сохранить" : "Отправить сообщение"))
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(.horizontal, width >= 780 ? 24 : 10).padding(.vertical, width >= 780 ? 12 : 10).background(MSTheme.surface)
            .overlay(alignment: .top) { Rectangle().fill(MSTheme.line).frame(height: 1) }
    }

    private func submitDraft() {
        guard let context = composerContext else { showDemoNotice(); return }
        switch context {
        case .reply(let id):
            guard model.demoChats.reply(to: id, text: draft, in: personIndex) else { return }
            draft = ""
        case .edit(let id):
            guard model.demoChats.edit(id, text: draft, in: personIndex) else { return }
        }
        clearComposerContext()
        composerFocused = false
    }

    private func clearComposerContext() {
        if let draftBeforeEdit { draft = draftBeforeEdit }
        draftBeforeEdit = nil
        composerContext = nil
    }

    private func showDemoNotice() {
        model.notice = "Сообщения в демо не отправляются. История здесь — пример из макетов."
    }

    private func select(_ id: UUID?) {
        clearComposerContext()
        composerFocused = false
        query = ""; searching = false; selected = id.map { [$0] } ?? []; selecting = true
    }
    private func endSelection() { selecting = false; selected.removeAll() }

    private func recipientPicker(_ message: DemoChatStore.Message) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(tr("Получатель")).font(MSTheme.font(12, weight: .semibold))
                    SearchBox(text: $recipientQuery, placeholder: "Найти чат или группу")
                    ForwardPreview(author: message.author, text: message.shareText)
                    let targets = model.demoChats.visibleContacts.filter { recipientQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(recipientQuery) }
                    ForEach(targets) { target in
                        Button {
                            guard model.demoChats.forward(message.id, from: personIndex, to: target.id) else { return }
                            forwardedDestination = target.id
                            forwarding = nil
                        } label: { ChatRecipientLabel(name: target.name, group: target.group) }.buttonStyle(.plain)
                            .accessibilityIdentifier("message.forward.\(target.id)")
                    }
                    if targets.isEmpty { Text(tr("Чат не найден")).foregroundStyle(MSTheme.muted) }
                }.padding(18)
            }.navigationTitle(tr("Переслать сообщение")).msInlineTitle()
                .toolbar { ToolbarItem(placement: .cancellationAction) { IconButton("xmark", label: "Отмена") { forwarding = nil } } }
        }.presentationDetents([.medium, .large])
    }
}
