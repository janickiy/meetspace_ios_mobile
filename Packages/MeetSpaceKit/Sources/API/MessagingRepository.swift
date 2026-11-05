import Foundation
import CryptoKit
import MeetSpaceCore

public struct WSTicket: Decodable, Sendable {
    public let ticket: String
    public let expiresAt: Date
}
public struct AttachmentUpload: Decodable, Sendable {
    public let item: Attachment
    public let uploadUrl: String
}
public struct DownloadDescriptor: Decodable, Sendable {
    public let url: String
    public let expiresAt: Date
    public let authenticated: Bool?
}
public struct UploadInput: Encodable, Sendable {
    public let clientRequestId: UUID
    public let filename: String
    public let mimeType: String
    public let size: Int
    public init(id: UUID, filename: String, mimeType: String, size: Int) {
        clientRequestId = id; self.filename = filename; self.mimeType = mimeType; self.size = size
    }
}

public struct MessagingRepository: Sendable {
    public let client: AuthenticatedClient
    private let downloads: any RequestTransport
    public init(client: AuthenticatedClient, downloads: any RequestTransport = URLSessionRequestTransport()) {
        self.client = client; self.downloads = downloads
    }
    public func conversations(cursor: String? = nil, search: String = "", type: String? = nil, unreadOnly: Bool = false) async throws -> ConversationPage {
        var query = pageQuery(cursor)
        if !search.isEmpty { query.append(URLQueryItem(name: "search", value: search)) }
        if let type { query.append(URLQueryItem(name: "type", value: type)) }
        if unreadOnly { query.append(URLQueryItem(name: "unreadOnly", value: "true")) }
        return try decodeJSON(ConversationPage.self, from: await client.request("GET", path: ["conversations"], query: query))
    }
    public func conversation(_ id: UUID) async throws -> Conversation {
        try decodeJSON(ItemResponse<Conversation>.self, from: await client.request("GET", path: scope(id))).item
    }
    public func users(search: String) async throws -> [Peer] {
        try decodeJSON(ItemsResponse<Peer>.self, from: await client.request("GET", path: ["users"],
            query: [URLQueryItem(name: "search", value: search)])).items
    }
    public func direct(userID: UUID) async throws -> Conversation {
        struct Body: Encodable { let userId: UUID }
        return try decodeJSON(ItemResponse<Conversation>.self, from: await client.request("POST", path: ["conversations", "direct"],
            body: WireJSON.encoder().encode(Body(userId: userID)))).item
    }
    public func createGroup(id: UUID, name: String, description: String, members: [UUID]) async throws -> Conversation {
        try validateGroup(name: name, description: description)
        guard members.count < 100 else { throw ClientError.invalidInput }
        struct Body: Encodable { let clientRequestId: UUID; let name: String; let description: String; let memberIds: [UUID] }
        let body = Body(clientRequestId: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), description: description, memberIds: members)
        return try decodeJSON(ItemResponse<Conversation>.self, from: await client.request("POST", path: ["conversations", "group"],
            body: WireJSON.encoder().encode(body))).item
    }
    public func messages(_ conversation: UUID, before: String? = nil, search: String? = nil) async throws -> MessagePage {
        var query = pageQuery(before)
        var path = scope(conversation) + ["messages"]
        if let search, !search.isEmpty {
            guard (2...200).contains(search.unicodeScalars.count) else { throw ClientError.invalidInput }
            path += ["search"]; query.append(URLQueryItem(name: "q", value: search))
        }
        return try decodeJSON(MessagePage.self, from: await client.request("GET", path: path, query: query))
    }
    public func context(_ conversation: UUID, message: UUID) async throws -> MessagePage {
        try decodeJSON(MessagePage.self, from: await client.request("GET", path: scope(conversation) + ["messages", sid(message), "context"]))
    }
    public func send(_ conversation: UUID, draft: MessageDraft) async throws -> ChatMessage {
        try decodeJSON(ItemResponse<ChatMessage>.self, from: await client.request("POST", path: scope(conversation) + ["messages"],
            body: WireJSON.encoder().encode(draft))).item
    }
    public func edit(_ conversation: UUID, message: UUID, text: String) async throws -> ChatMessage {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.unicodeScalars.count <= 4000, !normalized.contains("\0") else { throw ClientError.invalidInput }
        struct Body: Encodable { let text: String }
        return try decodeJSON(ItemResponse<ChatMessage>.self, from: await client.request("PATCH",
            path: scope(conversation) + ["messages", sid(message)], body: WireJSON.encoder().encode(Body(text: normalized)))).item
    }
    public func delete(_ conversation: UUID, message: UUID) async throws -> ChatMessage {
        try decodeJSON(ItemResponse<ChatMessage>.self, from: await client.request("DELETE",
            path: scope(conversation) + ["messages", sid(message)])).item
    }
    public func markRead(_ conversation: UUID, through message: UUID) async throws -> ReadState {
        struct Body: Encodable { let messageId: UUID }
        return try decodeJSON(ItemResponse<ReadState>.self, from: await client.request("PUT", path: scope(conversation) + ["chat", "read"],
            body: WireJSON.encoder().encode(Body(messageId: message)))).item
    }
    public func members(_ conversation: UUID) async throws -> [GroupMember] {
        try decodeJSON(ItemsResponse<GroupMember>.self, from: await client.request("GET", path: scope(conversation) + ["members"])).items
    }
    public func updateGroup(_ conversation: UUID, name: String, description: String) async throws -> Conversation {
        try validateGroup(name: name, description: description)
        struct Body: Encodable { let name: String; let description: String }
        return try decodeJSON(ItemResponse<Conversation>.self, from: await client.request("PATCH", path: scope(conversation),
            body: WireJSON.encoder().encode(Body(name: name, description: description)))).item
    }
    public func addMembers(_ conversation: UUID, users: [UUID]) async throws {
        struct Body: Encodable { let userIds: [UUID] }
        _ = try await client.request("POST", path: scope(conversation) + ["members"], body: WireJSON.encoder().encode(Body(userIds: users)))
    }
    public func removeMember(_ conversation: UUID, user: UUID) async throws {
        _ = try await client.request("DELETE", path: scope(conversation) + ["members", sid(user)])
    }
    public func changeRole(_ conversation: UUID, user: UUID, role: String) async throws {
        guard ["admin", "member"].contains(role) else { throw ClientError.invalidInput }
        struct Body: Encodable { let role: String }
        _ = try await client.request("PATCH", path: scope(conversation) + ["members", sid(user)], body: WireJSON.encoder().encode(Body(role: role)))
    }
    public func transferOwnership(_ conversation: UUID, user: UUID) async throws {
        struct Body: Encodable { let userId: UUID }
        _ = try await client.request("POST", path: scope(conversation) + ["ownership"], body: WireJSON.encoder().encode(Body(userId: user)))
    }
    public func leaveGroup(_ conversation: UUID) async throws {
        _ = try await client.request("POST", path: scope(conversation) + ["leave"], body: Data("{}".utf8))
    }
    public func deleteGroup(_ conversation: UUID) async throws { _ = try await client.request("DELETE", path: scope(conversation)) }
    public func ticket() async throws -> WSTicket {
        let ticket = try decodeJSON(WSTicket.self, from: await client.request("POST", path: ["ws-ticket"]))
        guard ticket.expiresAt > Date(), ticket.ticket.utf8.count == 43, SessionCookie.valid(ticket.ticket) else { throw APIError.invalidResponse }
        return ticket
    }
    public func upload(_ conversation: UUID, input: UploadInput, file: URL, progress: TransferProgress? = nil) async throws -> Attachment {
        try FilePolicy.validateName(input.filename)
        guard input.mimeType == (try FilePolicy.mimeType(for: input.filename)), (1...FilePolicy.maximumBytes).contains(input.size)
        else { throw ClientError.invalidInput }
        let started = try decodeJSON(AttachmentUpload.self, from: await client.request("POST", path: scope(conversation) + ["attachments", "init"],
            body: WireJSON.encoder().encode(input)))
        let attachment = started.item
        guard attachment.conversationId == conversation, attachment.ownerId == client.account.user.id,
              attachment.size == input.size, attachment.filename == input.filename, attachment.mimeType == input.mimeType
        else { throw ClientError.scopeMismatch }
        let path = scope(conversation) + ["attachments", sid(attachment.id), "content"]
        let expected = try EndpointURL.make(client.account.server, path: path)
        guard resolve(started.uploadUrl) == expected else { throw ClientError.scopeMismatch }
        // A finalize response may have been lost. Reuse the ready attachment instead of PUT-ing it again.
        if attachment.status == "ready", attachment.expiresAt > Date() { progress?(1); return attachment }
        guard attachment.status == "pending", attachment.expiresAt > Date() else { throw APIError.httpStatus(409) }
        _ = try await client.request("PUT", path: path, uploadFile: file, contentType: input.mimeType, progress: progress)
        let ready = try decodeJSON(ItemResponse<Attachment>.self, from: await client.request("POST",
            path: scope(conversation) + ["attachments", sid(attachment.id), "finalize"], body: Data("{}".utf8))).item
        guard ready.id == attachment.id, ready.status == "ready", ready.conversationId == conversation else { throw APIError.invalidResponse }
        return ready
    }
    public func download(_ conversation: UUID, attachment: Attachment, progress: TransferProgress? = nil) async throws -> Data {
        guard attachment.conversationId == conversation, attachment.size > 0, attachment.size <= FilePolicy.maximumBytes
        else { throw ClientError.scopeMismatch }
        try FilePolicy.validateName(attachment.filename)
        let info = try decodeJSON(DownloadDescriptor.self, from: await client.request("GET",
            path: scope(conversation) + ["attachments", sid(attachment.id), "download"]))
        guard info.expiresAt > Date() else { throw APIError.invalidResponse }
        let response: NetworkResponse
        if info.authenticated == true {
            let path = scope(conversation) + ["attachments", sid(attachment.id), "content"]
            guard resolve(info.url) == (try EndpointURL.make(client.account.server, path: path)) else { throw ClientError.scopeMismatch }
            response = try await client.request("GET", path: path, limit: Int(attachment.size), progress: progress)
        } else {
            guard let url = URL(string: info.url), url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil, url.fragment == nil else { throw APIError.tls }
            // Signed object-store URLs never receive API credentials, even on the same host.
            response = try await downloads.send(URLRequest(url: url), limit: Int(attachment.size), uploadFile: nil, progress: progress)
            try requireSuccess(response)
        }
        guard response.data.count == attachment.size else { throw APIError.invalidResponse }
        if let checksum = attachment.checksum, !checksum.isEmpty {
            let actual = SHA256.hash(data: response.data).map { String(format: "%02x", $0) }.joined()
            guard checksum.lowercased() == actual else { throw APIError.invalidResponse }
        }
        return response.data
    }
    public func cancelDownloads() async { await downloads.cancelAll() }
    private func resolve(_ raw: String) -> URL? { URL(string: raw, relativeTo: client.account.server.url)?.absoluteURL }
    private func scope(_ id: UUID) -> [String] { ["conversations", sid(id)] }
    private func sid(_ id: UUID) -> String { id.uuidString.lowercased() }
    private func pageQuery(_ cursor: String?) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "limit", value: "50")]
        if let cursor, !cursor.isEmpty { items.append(URLQueryItem(name: "before", value: cursor)) }
        return items
    }
    private func validateGroup(name: String, description: String) throws {
        guard (1...50).contains(name.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count),
              description.unicodeScalars.count <= 200 else { throw ClientError.invalidInput }
    }
}
