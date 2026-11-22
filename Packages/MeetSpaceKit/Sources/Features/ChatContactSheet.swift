import SwiftUI
import MeetSpaceAPI
import MeetSpaceCore
import MeetSpaceDesignSystem

struct LiveChatContactSheet: View {
    let model: MessagingModel
    let conversation: Conversation
    let peer: Peer
    let calls: DirectCallCoordinator?
    @State private var profile: ContactProfile?
    @State private var error: String?
    @State private var loading = true
    @State private var requestID = UUID()

    var body: some View {
        ChatContactSheet(name: profile?.displayName ?? peer.displayName, email: profile?.email, bio: profile?.bio,
                         call: calls.map { coordinator in { Task { await coordinator.startOutgoing(peer: DirectCallPeer(id: peer.id, displayName: peer.displayName)) } } }) {
            if loading { ProgressView().accessibilityLabel(tr("Загрузка профиля")) }
            if let error {
                Text(tr(error)).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
                Button(tr("Повторить")) { requestID = UUID() }.frame(minHeight: 44)
            }
        } materials: { kind in
            ContactMaterials(model: model, conversation: conversation.id, kind: kind).id(kind)
        }
        .task(id: requestID) {
            loading = true; error = nil
            defer { if !Task.isCancelled { loading = false } }
            do {
                let result = try await model.repository.contactProfile(conversation.id, user: peer.id)
                guard !Task.isCancelled, model.active, model.conversation?.id == conversation.id else { return }
                profile = result
            } catch {
                guard !Task.isCancelled else { return }
                self.error = userMessage(error)
            }
        }
    }
}

struct DemoChatContactSheet: View {
    let name: String
    let initials: String
    let messages: [DemoChatStore.Message]
    let call: () -> Void

    var body: some View {
        let info: (email: String?, bio: String?) = switch name {
        case "Анна Кузнецова": ("anna@example.org", "Занимаюсь дизайном продукта и исследованиями интерфейсов.")
        case "Максим Петров": ("max@example.org", "Разрабатываю MeetSpace и поддерживаю интеграции команды.")
        default: (nil, nil)
        }
        let filenames = messages.reversed().flatMap(\.files)
        let links = messages.reversed().flatMap { ContactLink.inText($0.text) }
        ChatContactSheet(name: name, initials: initials, email: info.email, bio: info.bio,
                         status: "В сети", call: call) { EmptyView() } materials: { kind in
            let files = filenames.filter { filename in
                let ext = (filename as NSString).pathExtension.lowercased()
                return ["jpg", "jpeg", "png", "heic", "webp", "gif", "mp4", "mov"].contains(ext) == (kind == .media)
            }
            if kind == .link {
                if links.isEmpty { contactEmpty(kind) }
                ForEach(uniqueContactItems(links), id: \.self) { url in
                    Link(destination: url) { Label(url.absoluteString, systemImage: "link") }
                }
            } else if files.isEmpty { contactEmpty(kind) }
            else {
                ForEach(uniqueContactItems(files), id: \.self) { name in
                    Label(name, systemImage: kind.symbol).font(MSTheme.font(14)).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
            }
        }
    }
}

private struct ChatContactSheet<Status: View, Materials: View>: View {
    let name: String
    var initials: String?
    let email: String?
    let bio: String?
    var status: String?
    var call: (() -> Void)?
    @ViewBuilder var loadStatus: () -> Status
    @ViewBuilder var materials: (ChatMaterialKind) -> Materials
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var kind = ChatMaterialKind.media
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(tr("О контакте")).font(MSTheme.font(14, weight: .semibold)).foregroundStyle(MSTheme.muted)
                Spacer(); IconButton("xmark", label: "Закрыть") { dismiss() }
            }.padding(.horizontal, 16).frame(minHeight: 56)
            ScrollView {
                VStack(spacing: sizeClass == .regular ? 18 : 16) {
                    ChatAvatar(name: name, initials: initials, size: sizeClass == .regular ? 72 : 60).clipShape(Circle())
                    VStack(spacing: 4) {
                        Text(name).font(MSTheme.font(23, weight: .semibold)).accessibilityAddTraits(.isHeader)
                        if let status { Text(tr(status)).font(MSTheme.font(13)).foregroundStyle(MSTheme.muted) }
                    }.multilineTextAlignment(.center)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { actions }
                        VStack(spacing: 8) { actions }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        detail("Имя", name)
                        detail("О себе", bio.flatMap { $0.isEmpty ? nil : $0 } ?? tr("Не указано"))
                        detail("Email", email.flatMap { $0.isEmpty ? nil : $0 } ?? tr("Не указан"))
                        loadStatus()
                    }.padding(16).background(MSTheme.background, in: RoundedRectangle(cornerRadius: 16))
                    HStack(spacing: 0) {
                        ForEach(ChatMaterialKind.allCases, id: \.self) { item in
                            Button { kind = item } label: {
                                Text(tr(item.title)).font(MSTheme.font(13, weight: .semibold)).padding(.horizontal, 4)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .foregroundStyle(item == kind ? MSTheme.accent : MSTheme.muted)
                                    .background(item == kind ? MSTheme.surface : .clear, in: Capsule())
                            }.buttonStyle(.plain).accessibilityAddTraits(kind == item ? .isSelected : [])
                        }
                    }.padding(4).frame(maxWidth: 332).background(MSTheme.surfaceSecondary, in: Capsule())
                    materials(kind)
                }.padding(.horizontal, sizeClass == .regular ? 24 : 16).padding(.bottom, 24)
                    .frame(maxWidth: 560).frame(maxWidth: .infinity)
            }
        }.background(MSTheme.surface).accessibilityIdentifier("chatContactSheet")
            .presentationDetents([.large])
    }
    @ViewBuilder private var actions: some View {
        action("Сообщение", icon: "message") { dismiss() }
        if let call { action("Позвонить", icon: "phone") { dismiss(); call() } }
    }
    private func action(_ title: String, icon: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Label(tr(title), systemImage: icon).font(MSTheme.font(13, weight: .semibold))
            .padding(.horizontal, 16).frame(minHeight: 44).background(MSTheme.accentSoft, in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain).foregroundStyle(MSTheme.accent)
    }
    private func detail(_ key: String, _ value: String) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) :
            AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        return layout {
            Text(tr(key)).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
                .frame(width: typeSize.isAccessibilitySize ? nil : 70, alignment: .leading)
            Text(value).font(MSTheme.font(14)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }.accessibilityElement(children: .combine)
    }
}

private extension ChatMaterialKind {
    var title: String { switch self { case .media: "Медиа"; case .file: "Файлы"; case .link: "Ссылки" } }
    var symbol: String { switch self { case .media: "photo"; case .file: "doc"; case .link: "link" } }
    var empty: String {
        switch self {
        case .media: "В этом чате пока нет медиа."
        case .file: "В этом чате пока нет файлов."
        case .link: "В этом чате пока нет ссылок."
        }
    }
}

private func contactEmpty(_ kind: ChatMaterialKind) -> some View {
    VStack(spacing: 8) {
        Image(systemName: kind.symbol).font(.title2).accessibilityHidden(true)
        Text(tr(kind.empty)).font(MSTheme.font(13))
    }.foregroundStyle(MSTheme.muted).frame(maxWidth: .infinity, minHeight: 96)
}

private func uniqueContactItems<T: Hashable>(_ items: [T]) -> [T] {
    var seen = Set<T>()
    return items.filter { seen.insert($0).inserted }
}

private enum ContactLink {
    static func safe(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
        return url
    }
    static func inText(_ text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return safe(String(text[range]))
        }
    }
}

private struct ContactMaterials: View {
    let model: MessagingModel
    let conversation: UUID
    let kind: ChatMaterialKind
    @State private var items: [ChatMaterialPage.Item] = []
    @State private var cursor: String?
    @State private var loading = true
    @State private var error: String?
    @State private var legacy = false
    @State private var requestID = UUID()

    var body: some View {
        let current = Dictionary(uniqueKeysWithValues: model.timeline.messages.map { ($0.id, $0) })
        let visible = items.filter { item in
            guard !model.hiddenMessageIDs.contains(item.message.id) else { return false }
            guard let latest = current[item.message.id] else { return true }
            return latest.isActionable && (latest.version <= item.message.version ||
                (item.attachment.map { latest.attachments.contains($0) } ?? item.url.map { latest.text.contains($0) } ?? false))
        }
        let history = model.timeline.messages.reversed().filter(\.isActionable)
        let files = legacy ? history.flatMap(\.attachments).filter {
            ($0.mimeType.hasPrefix("image/") || $0.mimeType.hasPrefix("video/")) == (kind == .media)
        } : visible.compactMap(\.attachment)
        let links = legacy ? history.flatMap { ContactLink.inText($0.text) } : visible.compactMap { $0.url.flatMap(ContactLink.safe) }
        VStack(spacing: 8) {
            if kind == .link {
                ForEach(uniqueContactItems(links), id: \.self) { url in
                    Link(destination: url) { Label(url.absoluteString, systemImage: "link").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading) }
                }
            } else {
                ForEach(files) { file in
                    if let url = model.downloads[file.id]?.url {
                        ShareLink(item: url) { Label(file.filename, systemImage: "square.and.arrow.up") }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    } else {
                        Button { model.download(file) } label: { Label(file.filename, systemImage: kind.symbol)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading) }
                        if let transfer = model.downloads[file.id] {
                            if let error = transfer.error { Text(tr(error)).font(MSTheme.font(12)).foregroundStyle(MSTheme.danger) }
                            else { ProgressView(value: transfer.progress) }
                        }
                    }
                }
            }
            if loading { ProgressView() }
            else if let error {
                Text(tr(error)).font(MSTheme.font(12)).foregroundStyle(MSTheme.danger)
                Button(tr("Повторить")) { requestID = UUID() }.frame(minHeight: 44)
            } else if (kind == .link ? links.isEmpty : files.isEmpty) && cursor == nil && (!legacy || model.historyCursor == nil) {
                contactEmpty(kind)
            }
            if !loading && error == nil && cursor != nil { Button(tr("Загрузить ещё")) { requestID = UUID() }.frame(minHeight: 44) }
            if legacy && model.historyCursor != nil {
                Button(tr("Более ранние сообщения")) { Task { await model.loadOlder() } }.frame(minHeight: 44).disabled(model.historyLoadingMore)
            }
        }.font(MSTheme.font(14)).buttonStyle(.plain).foregroundStyle(MSTheme.accent)
            .task(id: requestID) {
                loading = true; error = nil
                defer { if !Task.isCancelled { loading = false } }
                do {
                    let page = try await model.repository.materials(conversation, kind: kind, cursor: cursor)
                    guard !Task.isCancelled, model.active, model.conversation?.id == conversation else { return }
                    items.append(contentsOf: page.items)
                    cursor = page.nextCursor
                } catch APIError.httpStatus(let code) where [404, 405, 501].contains(code) {
                    if !Task.isCancelled { legacy = true }
                } catch { if !Task.isCancelled { self.error = userMessage(error) } }
            }
    }
}
