import Foundation

public struct Conversation: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let type: String
    public let peer: Peer?
    public let name: String?
    public let description: String
    public let memberCount: Int?
    public let myRole: String?
    public let updatedAt: Date
    public let lastMessageAt: Date?
    public let lastMessageID: UUID?
    public let preview: String
    public let unreadCount: Int
    public let notificationsEnabled: Bool
    public var title: String { type == "group" ? (name ?? "") : (peer?.displayName ?? "") }
    public var isGroup: Bool { type == "group" }
    public var canManage: Bool { isGroup && ["owner", "admin"].contains(myRole ?? "") }
    enum CodingKeys: String, CodingKey {
        case id, type, peer, name, description, memberCount, myRole, updatedAt, lastMessageAt
        case lastMessageID = "lastMessageId"
        case preview, unreadCount, notificationsEnabled
    }
}

public struct Peer: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let displayName: String
}
public struct GroupMember: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let displayName: String
    public let role: String
    public let online: Bool?
}
public struct ConversationPage: Decodable, Sendable {
    public let items: [Conversation]
    public let nextCursor: String?
    public let unreadCount: Int
}
public struct Attachment: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let conversationId: UUID?
    public let ownerId: UUID
    public let filename: String
    public let mimeType: String
    public let size: Int64
    public let checksum: String?
    public let status: String
    public let messageId: UUID?
    public let expiresAt: Date
}
public struct ReplyPreview: Codable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let senderName: String
    public let deleted: Bool
}
public struct CallHistory: Codable, Equatable, Sendable {
    public let id: UUID
    public let status: String
    public let durationSec: Int64
}

public struct ChatMessage: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let sequence: Int64
    public let conversationId: UUID?
    public let senderId: UUID
    public let senderName: String
    public let clientRequestId: UUID
    public let text: String
    public let replyTo: UUID?
    public let replyPreview: ReplyPreview?
    public let version: Int64
    public let createdAt: Date
    public let updatedAt: Date
    public let deletedAt: Date?
    public let attachments: [Attachment]
    public let call: CallHistory?
    public var isDeleted: Bool { deletedAt != nil }
    public func canEdit(as user: UUID) -> Bool { senderId == user && !isDeleted && call == nil }

    enum CodingKeys: String, CodingKey {
        case id, sequence, conversationId, senderId, senderName, clientRequestId, text, replyTo, replyPreview
        case version, createdAt, updatedAt, deletedAt, attachments, call
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        let raw = try c.decode(String.self, forKey: .sequence)
        guard let number = Int64(raw), number > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .sequence, in: c, debugDescription: "Invalid sequence")
        }
        sequence = number
        conversationId = try c.decodeIfPresent(UUID.self, forKey: .conversationId)
        senderId = try c.decode(UUID.self, forKey: .senderId)
        senderName = try c.decode(String.self, forKey: .senderName)
        clientRequestId = try c.decode(UUID.self, forKey: .clientRequestId)
        text = try c.decode(String.self, forKey: .text)
        replyTo = try c.decodeIfPresent(UUID.self, forKey: .replyTo)
        replyPreview = try c.decodeIfPresent(ReplyPreview.self, forKey: .replyPreview)
        version = try c.decode(Int64.self, forKey: .version)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        call = try c.decodeIfPresent(CallHistory.self, forKey: .call)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(String(sequence), forKey: .sequence)
        try c.encodeIfPresent(conversationId, forKey: .conversationId)
        try c.encode(senderId, forKey: .senderId); try c.encode(senderName, forKey: .senderName)
        try c.encode(clientRequestId, forKey: .clientRequestId); try c.encode(text, forKey: .text)
        try c.encodeIfPresent(replyTo, forKey: .replyTo); try c.encodeIfPresent(replyPreview, forKey: .replyPreview)
        try c.encode(version, forKey: .version); try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt); try c.encodeIfPresent(deletedAt, forKey: .deletedAt)
        try c.encode(attachments, forKey: .attachments); try c.encodeIfPresent(call, forKey: .call)
    }
}

public struct MessagePage: Decodable, Sendable {
    public let items: [ChatMessage]
    public let nextCursor: String?
    public let unreadCount: Int
    public let lastReadMessageId: UUID?
}
public struct ReadState: Decodable, Sendable {
    public let unreadCount: Int
    public let lastReadMessageId: UUID?
}
public struct MessageDraft: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { clientRequestId }
    public let clientRequestId: UUID
    public let text: String
    public let replyTo: UUID?
    public let attachmentIds: [UUID]
    public init(id: UUID = UUID(), text: String, replyTo: UUID? = nil, attachmentIds: [UUID] = []) throws {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.unicodeScalars.count <= 4000, !normalized.contains("\0"),
              !normalized.isEmpty || !attachmentIds.isEmpty,
              attachmentIds.count <= 5, Set(attachmentIds).count == attachmentIds.count else { throw ClientError.invalidInput }
        self.clientRequestId = id; self.text = normalized; self.replyTo = replyTo; self.attachmentIds = attachmentIds
    }
}

/// REST, mutation responses and WS share this merge rule. A stale page cannot resurrect a tombstone.
public struct MessageTimeline: Sendable {
    private var byID: [UUID: ChatMessage] = [:]
    public init() {}
    public var messages: [ChatMessage] {
        byID.values.sorted { $0.sequence == $1.sequence ? $0.id.uuidString < $1.id.uuidString : $0.sequence < $1.sequence }
    }
    public mutating func merge(_ incoming: [ChatMessage], conversation: UUID) {
        for message in incoming where message.conversationId == conversation {
            if let old = byID[message.id], old.version >= message.version { continue }
            byID[message.id] = message
        }
    }
}
