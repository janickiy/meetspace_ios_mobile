import Foundation
import MeetSpaceCore

/// Folders contain references only. No content-deletion endpoint is exposed here.
public struct FoldersRepository: Sendable {
    private let client: AuthenticatedClient
    public init(client: AuthenticatedClient) { self.client = client }
    public func list() async throws -> [PersonalFolder] {
        try validatedList(decodeJSON(ItemsResponse<PersonalFolder>.self, from: await request("GET", path: ["folders"])).items)
    }
    public func create(name: String) async throws -> PersonalFolder {
        struct Body: Encodable { let name: String }
        return try validated(decodeJSON(ItemResponse<PersonalFolder>.self, from: await request("POST", path: ["folders"],
            body: WireJSON.encoder().encode(Body(name: FolderValidation.text(name, maximum: 50, required: true))))).item)
    }
    public func rename(_ id: UUID, name: String) async throws -> PersonalFolder {
        struct Body: Encodable { let name: String }
        return try scoped(id, response: await request("PATCH", path: scope(id),
            body: WireJSON.encoder().encode(Body(name: FolderValidation.text(name, maximum: 50, required: true)))))
    }
    public func delete(_ id: UUID) async throws { _ = try await request("DELETE", path: scope(id)) }
    public func order(_ ids: [UUID]) async throws -> [PersonalFolder] {
        guard ids.count <= 100, Set(ids).count == ids.count else { throw ClientError.invalidInput }
        struct Body: Encodable { let ids: [String] }
        let items = try decodeJSON(ItemsResponse<PersonalFolder>.self, from: await request("PUT", path: ["folders", "order"],
            body: WireJSON.encoder().encode(Body(ids: ids.map { $0.uuidString.lowercased() })))).items
        guard Set(items.map(\.id)) == Set(ids), items.count == ids.count else { throw ClientError.scopeMismatch }
        return try validatedList(items)
    }
    public func items(_ id: UUID, candidates: Bool = false, filter: FolderFilter = .all,
                      search: String = "", before: String? = nil) async throws -> PersonalFolderPage {
        let search = try FolderValidation.text(search, maximum: 100, required: false)
        guard before.map({ $0.utf8.count <= 4096 }) ?? true else { throw ClientError.invalidInput }
        var query = [URLQueryItem(name: "limit", value: "50"), URLQueryItem(name: "type", value: filter.rawValue),
                     URLQueryItem(name: "search", value: search)]
        if let before, !before.isEmpty { query.append(URLQueryItem(name: "before", value: before)) }
        if candidates { query.append(URLQueryItem(name: "folderId", value: id.uuidString.lowercased())) }
        let page = try decodeJSON(PersonalFolderPage.self, from: await request("GET",
            path: candidates ? ["folder-items"] : scope(id) + ["items"], query: query))
        guard page.items.count <= 50, Set(page.items.map(\.id)).count == page.items.count,
              page.nextCursor.map({ $0.utf8.count <= 4096 && $0 != before }) ?? true else { throw APIError.invalidResponse }
        return page
    }
    public func setItem(_ folder: UUID, kind: FolderItemKind, id: UUID, included: Bool) async throws -> PersonalFolder {
        try scoped(folder, response: await request(included ? "PUT" : "DELETE",
            path: scope(folder) + ["items", kind.rawValue, id.uuidString.lowercased()]))
    }
    private func request(_ method: String, path: [String], query: [URLQueryItem] = [], body: Data? = nil) async throws -> NetworkResponse {
        guard client.account.user.guestConferenceId == nil else { throw ClientError.scopeMismatch }
        return try await client.request(method, path: path, query: query, body: body)
    }
    private func validated(_ folder: PersonalFolder) throws -> PersonalFolder {
        guard (0..<100).contains(folder.position), folder.itemCount >= 0, folder.conversationCount >= 0,
              folder.conferenceCount >= 0, folder.itemCount >= folder.conferenceCount,
              folder.itemCount - folder.conferenceCount == folder.conversationCount,
              (try? FolderValidation.text(folder.name, maximum: 50, required: true)) == folder.name else { throw APIError.invalidResponse }
        return folder
    }
    private func validatedList(_ folders: [PersonalFolder]) throws -> [PersonalFolder] {
        guard folders.count <= 100, Set(folders.map(\.id)).count == folders.count else { throw APIError.invalidResponse }
        return try folders.map(validated)
    }
    private func scope(_ id: UUID) -> [String] { ["folders", id.uuidString.lowercased()] }
    private func scoped(_ id: UUID, response: NetworkResponse) throws -> PersonalFolder {
        let item = try decodeJSON(ItemResponse<PersonalFolder>.self, from: response).item
        guard item.id == id else { throw ClientError.scopeMismatch }; return try validated(item)
    }
}
