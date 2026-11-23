import Foundation
import Observation

/// History belongs only to the current demo session and never touches an authenticated account.
@MainActor @Observable final class DemoChatStore {
    struct Contact: Identifiable {
        let id: Int
        let name: String
        let initials: String
        let members: [String]
        let preview: String
        let time: String
        var unread = 0
        var group: Bool { !members.isEmpty }
        var subtitle: String? { group ? chatGroupSubtitle(members.count) : nil }
    }

    struct Message: Identifiable, Equatable {
        let id = UUID()
        let author: String
        let own: Bool
        var text: String
        let time: String
        var files: [String] = []
        var forwarded: String?
        var pinned = false
        var reaction: String?
        var replyTo: UUID?
        var edited = false
        var deleted = false
        var canEdit: Bool { own && !deleted && forwarded == nil }
        var shareText: String { ([text] + files).joined(separator: "\n") }
    }

    static let contacts = [
        Contact(id: 1, name: "Команда продукта", initials: "П", members: ["Вы", "Мария Полякова", "Анна Кузнецова", "Максим Петров", "Дмитрий Волков"], preview: "Мария: собрала всё в одном файле", time: "09:38", unread: 3),
        Contact(id: 0, name: "Анна Кузнецова", initials: "АК", members: [], preview: "Да, до встречи!", time: "09:24", unread: 1),
        Contact(id: 3, name: "Разработка", initials: "Р", members: ["Вы", "Дмитрий Волков", "Анна Кузнецова", "Максим Петров"], preview: "Дмитрий: обновление готово", time: "Вчера"),
        Contact(id: 2, name: "Максим Петров", initials: "МП", members: [], preview: "Вы: Спасибо, посмотрю сегодня", time: "Вчера"),
        Contact(id: 4, name: "Дизайн-команда", initials: "Д", members: ["Вы", "Анна Кузнецова", "Мария Полякова"], preview: "Анна: новая версия макетов в папке", time: "Пт")
    ]

    private(set) var history: [Int: [Message]]
    private(set) var updated: Set<Int> = []
    private(set) var muted: Set<Int> = []
    private(set) var visibleContacts = contacts

    func toggleMute(_ id: Int) {
        if !muted.insert(id).inserted { muted.remove(id) }
    }

    func clearHistory(_ id: Int) {
        guard let index = visibleContacts.firstIndex(where: { $0.id == id }) else { return }
        visibleContacts[index].unread = 0
        history[id] = []
        updated.insert(id)
    }

    func removeConversation(_ id: Int) {
        visibleContacts.removeAll { $0.id == id }
        history.removeValue(forKey: id)
        muted.remove(id)
        updated.remove(id)
    }

    init() {
        history = Dictionary(uniqueKeysWithValues: Self.contacts.map { contact in
            let authors = contact.members.dropFirst()
            let first = authors.first ?? contact.name
            let second = authors.dropFirst().first ?? contact.name
            return (contact.id, [
                Message(author: first, own: false, text: "Доброе утро! Материалы к встрече готовы. Посмотрите, когда будет минутка.", time: "09:32", files: ["Обзор продукта.pdf"]),
                Message(author: "Вы", own: true, text: "Спасибо! Посмотрю перед встречей. Есть пара идей по навигации.", time: "09:34", files: contact.id == 1 ? ["Наш офис.jpg"] : []),
                Message(author: second, own: false, text: "Встречаемся в 10:00. Обсудим новую версию и планы команды.", time: "09:38", files: contact.id == 1 ? ["Переговорная.jpg", "Рабочее пространство.jpg", "Офис команды.jpg"] : [], pinned: true)
            ])
        })
    }

    func forward(_ id: UUID, from source: Int, to destination: Int) -> Bool {
        guard let original = history[source]?.first(where: { $0.id == id && !$0.deleted }),
              history[destination] != nil else { return false }
        let copy = Message(author: "Вы", own: true, text: original.text, time: Date().formatted(date: .omitted, time: .shortened),
                           files: original.files, forwarded: original.forwarded ?? original.author)
        history[destination]?.append(copy)
        updated.insert(destination)
        return true
    }

    func reply(to id: UUID, text: String, in chat: Int) -> Bool {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, activeIndex(id, in: chat) != nil else { return false }
        history[chat]?.append(Message(author: "Вы", own: true, text: content,
                                      time: Date().formatted(date: .omitted, time: .shortened), replyTo: id))
        updated.insert(chat)
        return true
    }

    func edit(_ id: UUID, text: String, in chat: Int) -> Bool {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, let index = activeIndex(id, in: chat),
              history[chat]?[index].canEdit == true else { return false }
        if history[chat]?[index].text != content {
            history[chat]?[index].text = content
            history[chat]?[index].edited = true
            if history[chat]?.last?.id == id { updated.insert(chat) }
        }
        return true
    }

    func togglePin(_ id: UUID, in chat: Int) {
        guard let index = activeIndex(id, in: chat) else { return }
        history[chat]?[index].pinned.toggle()
    }

    func toggleReaction(_ emoji: String, for id: UUID, in chat: Int) {
        guard let index = activeIndex(id, in: chat) else { return }
        let current = history[chat]?[index].reaction
        history[chat]?[index].reaction = current == emoji ? nil : emoji
    }

    func deleteOwn(_ id: UUID, in chat: Int) {
        guard let index = activeIndex(id, in: chat), var message = history[chat]?[index], message.own else { return }
        message.text = ""
        message.files = []
        message.forwarded = nil
        message.replyTo = nil
        message.reaction = nil
        message.pinned = false
        message.edited = false
        message.deleted = true
        history[chat]?[index] = message
        if history[chat]?.last?.id == id { updated.insert(chat) }
    }

    private func activeIndex(_ id: UUID, in chat: Int) -> Int? {
        history[chat]?.firstIndex { $0.id == id && !$0.deleted }
    }

    func remove(_ ids: Set<UUID>, in source: Int) {
        guard !ids.isEmpty, history[source] != nil else { return }
        history[source]?.removeAll { ids.contains($0.id) }
        updated.insert(source)
    }
}
