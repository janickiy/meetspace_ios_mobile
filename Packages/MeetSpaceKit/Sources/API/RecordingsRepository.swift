import Foundation
import MeetSpaceCore

public struct RecordingsRepository: Sendable {
    public let account: AccountRecord
    private let client: AuthenticatedClient
    public init(client: AuthenticatedClient) { self.client = client; account = client.account }

    public func capabilities() async throws -> [RecordingMode] {
        let value = try decodeJSON(ServerCapabilities.self, from: await client.request("GET", path: ["capabilities"]))
        return RecordingMode.allCases.filter { value.recordingModes.contains($0.rawValue) }
    }
    public func library(cursor: String? = nil, limit: Int = 30) async throws -> RecordingLibraryPage {
        guard (1...100).contains(limit), cursor.map({ !$0.isEmpty && $0.utf8.count <= 256 && $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 } }) ?? true else { throw ClientError.invalidInput }
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        struct Row: Decodable { let conference: Conference; let recording: RecordingCardDTO }
        struct Page: Decodable { let items: [Row]?; let nextCursor: String? }
        let page: Page
        do { page = try decodeJSON(Page.self, from: await client.request("GET", path: ["recordings"], query: query)) }
        catch APIError.httpStatus(let status) where status == 404 || status == 501 { throw RecordingAccessError.incompatibleServer }
        guard (page.items?.count ?? 0) <= limit, page.nextCursor.map({ !$0.isEmpty && $0.utf8.count <= 256 && $0 != cursor }) ?? true else { throw APIError.invalidResponse }
        let rows = try (page.items ?? []).map { row in
            RecordingLibraryItem(conference: row.conference, recording: try row.recording.validated(origin: account.server, conferenceID: row.conference.id).recording)
        }
        guard Set(rows.map(\.id)).count == rows.count else { throw APIError.invalidResponse }
        return RecordingLibraryPage(items: rows, nextCursor: page.nextCursor)
    }
    public func list(conferenceID: UUID, limit: Int = 100, offset: Int = 0) async throws -> [MeetingRecording] {
        guard (1...100).contains(limit), (0...1_000_000).contains(offset) else { throw ClientError.invalidInput }
        struct Response: Decodable { let items: [RecordingCardDTO]? }
        let response = try decodeJSON(Response.self, from: await client.request("GET", path: path(conferenceID), query: [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "offset", value: String(offset))]))
        let items = try (response.items ?? []).map { try $0.validated(origin: account.server, conferenceID: conferenceID).recording }
        guard items.count <= limit, Set(items.map(\.id)).count == items.count else { throw APIError.invalidResponse }
        return items
    }
    public func read(conferenceID: UUID, recordingID: UUID) async throws -> MeetingRecording {
        try await card(conferenceID: conferenceID, recordingID: recordingID).recording
    }
    public func start(conferenceID: UUID, mode: RecordingMode) async throws -> MeetingRecording {
        guard try await capabilities().contains(mode) else { throw RecordingAccessError.unavailable }
        struct Body: Encodable { let mode: String }
        let value = try decodeJSON(ItemResponse<RecordingCardDTO>.self, from: await client.request("POST", path: path(conferenceID), body: WireJSON.encoder().encode(Body(mode: mode.rawValue)))).item.validated(origin: account.server, conferenceID: conferenceID).recording
        guard value.mode == mode.rawValue else { throw APIError.invalidResponse }; return value
    }
    public func stop(conferenceID: UUID, recordingID: UUID) async throws -> MeetingRecording {
        let value = try decodeJSON(ItemResponse<RecordingCardDTO>.self, from: await client.request("POST", path: path(conferenceID, recordingID) + ["stop"], body: Data("{}".utf8))).item.validated(origin: account.server, conferenceID: conferenceID).recording
        guard value.id == recordingID else { throw ClientError.scopeMismatch }; return value
    }
    public func delete(conferenceID: UUID, recordingID: UUID) async throws {
        _ = try await client.request("DELETE", path: path(conferenceID, recordingID))
    }
    /// Always reauthorize through the account API. Signed URLs are ephemeral capabilities and
    /// must be fetched without account bearer/cookies, including on a different storage origin.
    public func download(conferenceID: UUID, recordingID: UUID, fileID: UUID,
                         using downloader: any RecordingDownloading, progress: TransferProgress? = nil) async throws -> URL {
        let card = try await card(conferenceID: conferenceID, recordingID: recordingID)
        guard card.recording.ready, let file = card.recording.files.first(where: { $0.id == fileID }),
              let url = card.urls[fileID] else { throw RecordingAccessError.unavailable }
        let local = try await downloader.download(url: url, file: file, progress: progress)
        do {
            // Long transfers can outlive membership or artifact changes. Reauthorize again
            // before handing a local file to playback/export; never resurrect a closed account.
            let current = try await self.card(conferenceID: conferenceID, recordingID: recordingID)
            guard current.recording.ready, current.recording.files.contains(file) else { throw RecordingAccessError.noPermission }
            try Task.checkCancellation(); return local
        } catch { await downloader.remove(local); throw error }
    }
    private func card(conferenceID: UUID, recordingID: UUID) async throws -> RecordingCard {
        let result = try decodeJSON(ItemResponse<RecordingCardDTO>.self, from: await client.request("GET", path: path(conferenceID, recordingID))).item.validated(origin: account.server, conferenceID: conferenceID)
        guard result.recording.id == recordingID else { throw ClientError.scopeMismatch }; return result
    }
    private func path(_ conferenceID: UUID, _ recordingID: UUID? = nil) -> [String] {
        ["conferences", conferenceID.uuidString.lowercased(), "recordings"] + (recordingID.map { [$0.uuidString.lowercased()] } ?? [])
    }
}

private struct RecordingCard { let recording: MeetingRecording; let urls: [UUID: URL] }
private struct RecordingCardDTO: Decodable {
    let id: Int64; let uuid: UUID; let conferenceId: UUID; let mode: String; let status: String
    let createdAt: Date; let startedAt: Date?; let requestedBy: UUID?; let durationSec: Int?
    let files: [RecordingFileDTO]?
    func validated(origin: ServerOrigin, conferenceID: UUID) throws -> RecordingCard {
        guard id > 0, conferenceId == conferenceID, uuid != UUID.zeroRecording, mode.utf8.count <= 64, status.utf8.count <= 64,
              durationSec.map({ $0 >= 0 }) ?? true, (files?.count ?? 0) <= 32 else { throw APIError.invalidResponse }
        var urls: [UUID: URL] = [:]; var metadata: [RecordingFile] = []
        for file in files ?? [] {
            guard let mime = ["final_mp4": "video/mp4", "final_audio": "audio/mp4", "tracks_archive": "application/zip", "preview_jpg": "image/jpeg"][file.fileType] else { continue }
            guard file.recordId == id, file.uuid != UUID.zeroRecording, mime == file.mimeType,
                  file.sizeBytes.map({ $0 > 0 }) ?? true, file.durationSec.map({ $0 >= 0 }) ?? true,
                  file.checksumSha256.map({ $0.isEmpty || ($0.utf8.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) }) ?? true else { throw APIError.invalidResponse }
            try FilePolicy.validateName(file.fileName)
            let url = try file.url.flatMap { $0.isEmpty ? nil : try RecordingURLPolicy.validate($0, origin: origin) }
            if let url { urls[file.uuid] = url }
            metadata.append(RecordingFile(id: file.uuid, type: file.fileType, filename: file.fileName, mimeType: mime,
                sizeBytes: file.sizeBytes, checksumSHA256: file.checksumSha256.flatMap { $0.isEmpty ? nil : $0.lowercased() }, durationSec: file.durationSec, available: url != nil))
        }
        guard Set(metadata.map(\.id)).count == metadata.count else { throw APIError.invalidResponse }
        return RecordingCard(recording: MeetingRecording(id: uuid, conferenceID: conferenceId, mode: mode, status: status, createdAt: createdAt,
            startedAt: startedAt, requestedBy: requestedBy, durationSec: durationSec, files: metadata), urls: urls)
    }
}
private struct RecordingFileDTO: Decodable {
    let uuid: UUID; let recordId: Int64; let fileType: String; let fileName: String; let mimeType: String
    let sizeBytes: Int64?; let checksumSha256: String?; let durationSec: Int?; let url: String?
}
private extension UUID { static let zeroRecording = UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)) }

public enum RecordingURLPolicy {
    public static func validate(_ raw: String, origin: ServerOrigin) throws -> URL {
        guard !raw.isEmpty, raw.utf8.count <= 16_384, !raw.hasPrefix("//"), !raw.contains("\\"),
              !raw.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else { throw APIError.invalidResponse }
        let value = raw.hasPrefix("/") ? origin.url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + raw : raw
        guard let parts = URLComponents(string: value), parts.scheme == "https", parts.host?.isEmpty == false,
              parts.user == nil, parts.password == nil, parts.fragment == nil, let url = parts.url else { throw APIError.invalidResponse }
        return url
    }
}
