import Foundation

public struct PersonalFolder: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let position: Int
    public let createdAt: Date
    public let updatedAt: Date
    public let itemCount: Int
    public let conversationCount: Int
    public let conferenceCount: Int
    public let contains: Bool?
}

public enum FolderItemKind: String, Codable, Sendable { case conversation, conference }
public enum FolderFilter: String, CaseIterable, Sendable { case all, conversation, conference }
public struct PersonalFolderItem: Decodable, Equatable, Sendable, Identifiable {
    public let kind: FolderItemKind
    public let conversation: Conversation?
    public let conference: Conference?
    public let inFolder: Bool
    public var itemID: UUID { conversation?.id ?? conference!.id }
    public var id: String { kind.rawValue + ":" + itemID.uuidString }
    public var title: String { conversation?.title ?? conference!.title }
    enum CodingKeys: String, CodingKey { case type, item, inFolder }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(FolderItemKind.self, forKey: .type)
        inFolder = try c.decodeIfPresent(Bool.self, forKey: .inFolder) ?? false
        switch kind {
        case .conversation:
            conversation = try c.decode(Conversation.self, forKey: .item); conference = nil
        case .conference:
            conference = try c.decode(Conference.self, forKey: .item); conversation = nil
        }
    }
}
public struct PersonalFolderPage: Decodable, Sendable {
    public let items: [PersonalFolderItem]
    public let nextCursor: String?
}
public enum FolderValidation {
    public static func text(_ input: String, maximum: Int, required: Bool) throws -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard text.unicodeScalars.count <= maximum, !required || !text.isEmpty,
              !text.unicodeScalars.contains(where: {
                  $0.properties.generalCategory == .control ||
                  ($0.properties.generalCategory == .format && $0.value != 0x200C && $0.value != 0x200D)
              }) else { throw ClientError.invalidInput }
        return text
    }
}
