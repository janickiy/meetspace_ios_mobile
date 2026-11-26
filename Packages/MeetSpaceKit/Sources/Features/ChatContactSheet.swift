import SwiftUI
import MeetSpaceAPI
import MeetSpaceCore
import MeetSpaceDesignSystem

struct LiveChatContactSheet: View {
    let model: MessagingModel
    let conversation: Conversation
    let peer: Peer
    let startCall: ((Bool) -> Void)?
    @Environment(\.scenePhase) private var scenePhase
    @State private var presence = "Проверяем статус…"
    @State private var profile: ContactProfile?
    @State private var error: String?
    @State private var loading = true
    @State private var requestID = UUID()

    var body: some View {
        let name = profile?.displayName ?? peer.displayName
        let visible = scenePhase == .active && model.active && model.conversation?.id == conversation.id
        ChatInfoSheet(name: name, status: tr(presence),
                      call: startCall.map { start in { start(false) } },
                      videoCall: startCall.map { start in { start(true) } }) {
            contactDetails(name, bio: profile?.bio, email: profile?.email)
            if loading { ProgressView().accessibilityLabel(tr("Загрузка профиля")) }
            if let error {
                Text(tr(error)).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
                Button(tr("Повторить")) { requestID = UUID() }.frame(minHeight: 44)
            }
        } materials: { kind in
            ContactMaterials(model: model, conversation: conversation.id, kind: kind).id(kind)
        }
        .task(id: visible) {
            presence = "Проверяем статус…"
            guard visible else { return }
            while !Task.isCancelled {
                do {
                    let online = try await model.repository.peerOnline(conversation.id, user: peer.id)
                    try Task.checkCancellation()
                    presence = online ? "В сети" : "Не в сети"
                } catch {
                    guard !Task.isCancelled else { return }
                    presence = "Статус недоступен"
                    if case APIError.httpStatus(let code) = error, [401, 403, 404, 405, 501].contains(code) { return }
                }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
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

struct LiveChatGroupSheet: View {
    let model: MessagingModel
    let conversation: Conversation
    let edit: () -> Void
    @State private var members: [GroupMember]?
    @State private var error: String?
    @State private var requestID = UUID()

    var body: some View {
        let count = members?.count ?? conversation.memberCount
        ChatInfoSheet(name: conversation.title, status: count.map(chatMemberCount) ?? tr("Групповой чат"),
                      group: true, edit: conversation.canManage ? edit : nil) {
            groupDetails(conversation.title, description: conversation.description)
            ChatInfoMembers(count: count) {
                if let members {
                    ForEach(members) { member in
                        let role = switch member.role { case "owner": "Владелец"; case "admin": "Администратор"; default: "Участник" }
                        ChatInfoMember(name: member.displayName, role: role)
                    }
                } else if let error {
                    Text(tr(error)).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
                    Button(tr("Повторить")) { requestID = UUID() }.frame(minHeight: 44)
                } else { ProgressView() }
            }
        } materials: { kind in
            ContactMaterials(model: model, conversation: conversation.id, kind: kind).id(kind)
        }
        .task(id: requestID) {
            error = nil
            do {
                let result = try await model.repository.members(conversation.id)
                guard !Task.isCancelled, model.active, model.conversation?.id == conversation.id else { return }
                members = result
            } catch { if !Task.isCancelled { self.error = userMessage(error) } }
        }
    }
}

private func contactDetails(_ name: String, bio: String?, email: String?) -> some View {
    ChatInfoDetails(fields: [("Имя", name), ("О себе", bio.flatMap { $0.isEmpty ? nil : $0 } ?? tr("Не указано")),
                             ("Email", email.flatMap { $0.isEmpty ? nil : $0 } ?? tr("Не указан"))])
}

private func groupDetails(_ name: String, description: String) -> some View {
    ChatInfoDetails(fields: [("Название", name), ("Описание", description.isEmpty ? tr("Описание не добавлено") : description)])
}

struct DemoChatInfoSheet: View {
    let contact: DemoChatStore.Contact
    let messages: [DemoChatStore.Message]
    let call: () -> Void

    var body: some View {
        ChatInfoSheet(name: contact.name, initials: contact.initials,
                      status: contact.group ? chatMemberCount(contact.members.count) : tr("В сети"),
                      group: contact.group, call: contact.group ? nil : call) {
            if contact.group {
                groupDetails(contact.name, description: contact.description)
                ChatInfoMembers(count: contact.members.count) {
                    ForEach(contact.members, id: \.self) { ChatInfoMember(name: $0) }
                }
            } else {
                let info: (email: String?, bio: String?) = switch contact.name {
                case "Анна Кузнецова": ("anna@example.org", "Занимаюсь дизайном продукта и исследованиями интерфейсов.")
                case "Максим Петров": ("max@example.org", "Разрабатываю MeetSpace и поддерживаю интеграции команды.")
                default: (nil, nil)
                }
                contactDetails(contact.name, bio: info.bio, email: info.email)
            }
        } materials: { kind in
            let visible = messages.reversed().filter { !$0.deleted }
            if kind == .link {
                let links = uniqueContactItems(visible.flatMap { ContactLink.inText($0.text) })
                if links.isEmpty { contactEmpty(kind) }
                else { ChatInfoLinks(links: links) }
            } else {
                let files = uniqueContactItems(visible.flatMap(\.files)).filter { filename in
                    let ext = (filename as NSString).pathExtension.lowercased()
                    return ["jpg", "jpeg", "png", "heic", "webp", "gif", "mp4", "mov"].contains(ext) == (kind == .media)
                }
                if files.isEmpty { contactEmpty(kind) }
                else { DemoChatAttachments(files: files, gallery: true) }
            }
        }
    }
}

private struct ChatInfoLinks: View {
    let links: [URL]
    var body: some View {
        VStack(spacing: 2) {
            ForEach(links, id: \.self) { url in
                Link(destination: url) {
                    ChatInfoFileRow(icon: "link", title: url.host ?? url.absoluteString,
                                    subtitle: url.absoluteString, trailing: "arrow.up.right")
                }
            }
        }.buttonStyle(.plain)
    }
}

struct ChatInfoFileRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let trailing: String
    var body: some View {
        HStack(spacing: 10) {
            WorkspaceIcon(icon, size: 17).foregroundStyle(MSTheme.brandAccent)
                .frame(width: 36, height: 36).background(MSTheme.accentSoft, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(MSTheme.font(13, weight: .semibold)).foregroundStyle(MSTheme.ink)
                Text(subtitle).font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
            }
            Spacer(minLength: 0)
            WorkspaceIcon(trailing, size: 17).foregroundStyle(MSTheme.brandAccent)
                .frame(minWidth: 44, minHeight: 44)
        }.padding(.horizontal, 6).frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .contentShape(Rectangle())
    }
}

extension ChatMaterialKind {
    var title: String { switch self { case .media: "Медиа"; case .file: "Файлы"; case .link: "Ссылки" } }
    var symbol: String { switch self { case .media: "photo"; case .file: "doc.text"; case .link: "link" } }
    var empty: String {
        switch self {
        case .media: "В этом чате пока нет медиа."
        case .file: "В этом чате пока нет файлов."
        case .link: "В этом чате пока нет ссылок."
        }
    }
}

@MainActor private func contactEmpty(_ kind: ChatMaterialKind) -> some View {
    VStack(spacing: 8) {
        WorkspaceIcon(kind.symbol, size: 22).frame(width: 42, height: 42)
            .background(MSTheme.background, in: Circle()).accessibilityHidden(true)
        Text(tr(kind.empty)).font(MSTheme.font(13)).multilineTextAlignment(.center)
    }.padding(14).foregroundStyle(MSTheme.muted).frame(maxWidth: .infinity, minHeight: 100)
}

private func uniqueContactItems<T: Hashable>(_ items: [T]) -> [T] {
    var seen = Set<T>()
    return items.filter { seen.insert($0).inserted }
}

private enum ContactLink {
    /// Проверяет ссылку и возвращает допустимый HTTP- или HTTPS-адрес без встроенных учётных данных.
    /// - Parameter text: Текст для проверки в качестве адреса.
    static func safe(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
        return url
    }
    /// Находит в тексте допустимые веб-ссылки.
    /// - Parameter text: Текст сообщения для поиска ссылок.
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
            if kind == .link && !links.isEmpty {
                ChatInfoLinks(links: uniqueContactItems(links))
            } else if kind == .media && !files.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 3), spacing: 5) {
                    ForEach(files) { attachment($0) }
                }
            } else if kind == .file && !files.isEmpty {
                VStack(spacing: 2) { ForEach(files) { attachment($0) } }
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

    /// Показывает вложение и состояние его загрузки в материалах чата.
    /// - Parameter file: Вложение, доступное для загрузки.
    private func attachment(_ file: Attachment) -> some View {
        let download = model.downloads[file.id]
        return VStack(spacing: 4) {
            if let url = download?.url {
                ShareLink(item: url) { fileLabel(file, url: url) }
                    .accessibilityLabel("\(tr("Поделиться")) \(file.filename)")
            } else {
                Button { model.download(file) } label: { fileLabel(file, url: nil) }
                    .accessibilityLabel(file.filename)
                if let download {
                    if let error = download.error { Text(tr(error)).font(MSTheme.font(12)).foregroundStyle(MSTheme.danger) }
                    else { ProgressView(value: download.progress) }
                }
            }
        }
    }

    /// Строит подпись или превью вложения в выбранном разделе материалов.
    /// - Parameters:
    ///   - file: Вложение для отображения.
    ///   - url: Локальный адрес загруженного файла, если он доступен.
    @ViewBuilder private func fileLabel(_ file: Attachment, url: URL?) -> some View {
        if kind == .media {
            RoundedRectangle(cornerRadius: 9).fill(MSTheme.surfaceSecondary)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let url, file.mimeType.hasPrefix("image/") {
                        AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { mediaLabel(file) }
                    } else { mediaLabel(file) }
                }.clipShape(RoundedRectangle(cornerRadius: 9))
        } else {
            ChatInfoFileRow(icon: "doc.text", title: file.filename,
                            subtitle: ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file),
                            trailing: url == nil ? "arrow.down.to.line" : "square.and.arrow.up")
        }
    }

    /// Оформляет тип и имя медиафайла в миниатюре.
    /// - Parameter file: Вложение с MIME-типом и именем.
    private func mediaLabel(_ file: Attachment) -> some View {
        VStack(spacing: 5) {
            WorkspaceIcon(file.mimeType.hasPrefix("video/") ? "video" : "photo", size: 18)
            Text(file.filename).font(MSTheme.font(10)).foregroundStyle(MSTheme.ink).lineLimit(1)
        }.padding(8)
    }

}
