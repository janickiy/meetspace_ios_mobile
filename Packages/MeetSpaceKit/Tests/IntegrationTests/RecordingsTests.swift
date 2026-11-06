import Foundation
import Testing
import CryptoKit
import MeetSpaceCore
@testable import MeetSpaceAPI
@testable import MeetSpaceFeatures

private enum RecordingFixture {
    static let conference = UUID(uuidString: "a1111111-1111-4111-8111-111111111111")!
    static let recording = UUID(uuidString: "a2222222-2222-4222-8222-222222222222")!
    static let file = UUID(uuidString: "a3333333-3333-4333-8333-333333333333")!
    static var path: String { "/api/v1/conferences/\(conference.uuidString.lowercased())/recordings" }
    static let bytes = Data(repeating: 42, count: 131_072)
    static var hash: String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    static func card(conference: UUID = conference, status: String = "ready", url: String = "https://storage.fixture/media") -> [String: Any] {
        ["id": 42, "uuid": recording.uuidString, "conferenceId": conference.uuidString, "mode": "composite", "status": status,
         "createdAt": "2026-11-06T10:00:00.000Z", "requestedBy": Fixture.userID.uuidString,
         "files": [["uuid": file.uuidString, "recordId": 42, "fileType": "final_mp4", "fileName": "meeting.mp4", "mimeType": "video/mp4",
                    "sizeBytes": bytes.count, "checksumSha256": hash, "url": url]]]
    }
    static func meeting() -> Conference { Conference(id: conference, ownerId: Fixture.userID, title: "Встреча", status: "active") }
    static func row() throws -> [String: Any] {
        ["conference": try JSONSerialization.jsonObject(with: WireJSON.encoder().encode(meeting())), "recording": card()]
    }
    static func client(_ transport: any RequestTransport) throws -> AuthenticatedClient {
        AuthenticatedClient(account: try Fixture.account(), credentials: Fixture.credentials(), secureStore: TestSecrets(), transport: transport)
    }
    static func metadata(hash: String? = hash, size: Int64 = Int64(bytes.count)) -> RecordingFile {
        RecordingFile(id: file, type: "final_mp4", filename: "meeting.mp4", mimeType: "video/mp4", sizeBytes: size, checksumSHA256: hash)
    }
}

@Test func recordingsActualRoutesCapabilitiesScopeAndCursor() async throws {
    let transport = RoutedTransport { request, _ in
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
        switch (request.httpMethod, request.url!.path) {
        case ("GET", "/api/v1/capabilities"):
            return try Fixture.response(["capabilities": ["recordingModes": ["composite", "future_mode"]], "buildVersion": "fixture"])
        case ("GET", "/api/v1/recordings"):
            #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "limit", value: "30")) == true)
            return try Fixture.response(["items": [RecordingFixture.row()], "nextCursor": NSNull()])
        case ("POST", RecordingFixture.path):
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            #expect(body["mode"] as? String == "composite" && body.count == 1)
            return try Fixture.response(["item": RecordingFixture.card(status: "starting")])
        case ("POST", RecordingFixture.path + "/" + RecordingFixture.recording.uuidString.lowercased() + "/stop"):
            #expect(request.httpBody == Data("{}".utf8))
            return try Fixture.response(["item": RecordingFixture.card(status: "processing")])
        case ("DELETE", RecordingFixture.path + "/" + RecordingFixture.recording.uuidString.lowercased()):
            return try Fixture.response(["status": "success"])
        default: throw APIError.invalidResponse
        }
    }
    let repo = RecordingsRepository(client: try RecordingFixture.client(transport))
    #expect(try await repo.capabilities() == [.composite])
    let rows = try await repo.library()
    #expect(rows.items.count == 1 && rows.items.first?.recording.media != nil && rows.nextCursor == nil)
    #expect(try await repo.start(conferenceID: RecordingFixture.conference, mode: .composite).status == "starting")
    #expect(try await repo.stop(conferenceID: RecordingFixture.conference, recordingID: RecordingFixture.recording).status == "processing")
    try await repo.delete(conferenceID: RecordingFixture.conference, recordingID: RecordingFixture.recording)
    await #expect(throws: ClientError.invalidInput) { try await repo.library(cursor: "bad cursor") }
}

@Test func recordingMetadataRejectsCrossConferenceAndUnsafeSignedURLs() async throws {
    for card in [RecordingFixture.card(conference: UUID()), RecordingFixture.card(url: "http://storage.fixture/media"), RecordingFixture.card(url: "https://bearer@storage.fixture/media")] {
        let data = try Fixture.data(["item": card])
        let transport = RoutedTransport { _, _ in NetworkResponse(status: 200, headers: ["content-type": "application/json"], data: data) }
        let repo = RecordingsRepository(client: try RecordingFixture.client(transport))
        await #expect(throws: (any Error).self) { try await repo.read(conferenceID: RecordingFixture.conference, recordingID: RecordingFixture.recording) }
    }
    #expect(try RecordingURLPolicy.validate("/objects/signed?signature=fixture", origin: Fixture.origin).host == "fixture.example")
    #expect(try RecordingURLPolicy.validate("https://storage.fixture/media?signature=fixture", origin: Fixture.origin).host == "storage.fixture")
    for url in ["//other.example/a", "file:///tmp/a", "https://storage.fixture/media#fragment", "https://storage.fixture/a\\b", "https://storage.fixture/a\n"] {
        #expect(throws: APIError.invalidResponse) { try RecordingURLPolicy.validate(url, origin: Fixture.origin) }
    }
}

private final class RecordingRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var started: Set<String> = []
    func mark(_ url: URL) { lock.withLock { _ = started.insert(url.absoluteString) } }
    func contains(_ url: URL) -> Bool { lock.withLock { started.contains(url.absoluteString) } }
}
private final class RecordingProtocol: URLProtocol, @unchecked Sendable {
    static let requests = RecordingRequests()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "storage.fixture" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        Self.requests.mark(request.url!)
        let path = request.url!.path
        if path == "/wait" { return }
        let status = path == "/denied" ? 403 : path == "/redirect" ? 302 : 200
        let headers = ["Content-Type": path == "/html" ? "text/html" : "video/mp4", "Content-Length": String(RecordingFixture.bytes.count)]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: RecordingFixture.bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private func downloader(base: URL) throws -> URLSessionRecordingDownloader {
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [RecordingProtocol.self]
    return URLSessionRecordingDownloader(account: try Fixture.account(), baseDirectory: base, configuration: configuration)
}
private func temporaryRecordingDirectory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("recording-test-" + UUID().uuidString) }

@Test func recordingDownloadStreamsChecksHashAndCleansAccountFiles() async throws {
    let base = temporaryRecordingDirectory(); defer { try? FileManager.default.removeItem(at: base) }
    let downloads = try downloader(base: base)
    let local = try await downloads.download(url: URL(string: "https://storage.fixture/media")!, file: RecordingFixture.metadata(), progress: nil)
    #expect(try Data(contentsOf: local) == RecordingFixture.bytes)
    #expect(local.isFileURL && local.lastPathComponent == "meeting.mp4")
    await downloads.close()
    #expect(!FileManager.default.fileExists(atPath: local.path))
    await #expect(throws: CancellationError.self) {
        try await downloads.download(url: URL(string: "https://storage.fixture/media")!, file: RecordingFixture.metadata(), progress: nil)
    }
}

@Test func recordingDownloadRejectsRedirectDenialWrongMIMEChecksumAndSize() async throws {
    let base = temporaryRecordingDirectory(); defer { try? FileManager.default.removeItem(at: base) }
    let downloads = try downloader(base: base)
    for path in ["redirect", "denied", "html"] {
        await #expect(throws: (any Error).self) {
            try await downloads.download(url: URL(string: "https://storage.fixture/" + path)!, file: RecordingFixture.metadata(), progress: nil)
        }
    }
    await #expect(throws: RecordingAccessError.invalidArtifact) {
        try await downloads.download(url: URL(string: "https://storage.fixture/media")!, file: RecordingFixture.metadata(hash: String(repeating: "0", count: 64)), progress: nil)
    }
    await #expect(throws: RecordingAccessError.invalidArtifact) {
        try await downloads.download(url: URL(string: "https://storage.fixture/media")!, file: RecordingFixture.metadata(size: 10), progress: nil)
    }
    await #expect(throws: RecordingAccessError.tooLarge) {
        try await downloads.download(url: URL(string: "https://storage.fixture/media")!, file: RecordingFixture.metadata(size: URLSessionRecordingDownloader.maximumBytes + 1), progress: nil)
    }
    let existing = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? []
    #expect(existing.allSatisfy { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) != true })
    await downloads.close()
}

@Test func recordingDownloadCloseCancelsAnActualPendingURLSessionRequest() async throws {
    let base = temporaryRecordingDirectory(); defer { try? FileManager.default.removeItem(at: base) }
    let downloads = try downloader(base: base)
    let url = URL(string: "https://storage.fixture/wait?run=" + UUID().uuidString)!
    let pending = Task { try await downloads.download(url: url, file: RecordingFixture.metadata(), progress: nil) }
    for _ in 0..<200 {
        if RecordingProtocol.requests.contains(url) { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(RecordingProtocol.requests.contains(url))
    await downloads.close()
    await #expect(throws: CancellationError.self) { try await pending.value }
    let existing = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? []
    #expect(existing.allSatisfy { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) != true })
}

private actor RevokeAfterDownload: RecordingDownloading {
    let url: URL
    private(set) var started = false
    private(set) var removed = false
    init(url: URL) { self.url = url }
    func download(url: URL, file: RecordingFile, progress: TransferProgress?) async throws -> URL { started = true; return self.url }
    func remove(_ url: URL) { removed = true }
    func close() { removed = true }
}
@Test func recordingRechecksAuthorizationAfterDownloadAndDoesNotLeakRevokedFile() async throws {
    let downloads = RevokeAfterDownload(url: URL(fileURLWithPath: "/tmp/recording-fixture-only.mp4"))
    let transport = RoutedTransport { _, _ in
        if await downloads.started { return NetworkResponse(status: 403) }
        return try Fixture.response(["item": RecordingFixture.card()])
    }
    let repo = RecordingsRepository(client: try RecordingFixture.client(transport))
    await #expect(throws: APIError.httpStatus(403)) {
        try await repo.download(conferenceID: RecordingFixture.conference, recordingID: RecordingFixture.recording, fileID: RecordingFixture.file, using: downloads)
    }
    #expect(await downloads.removed)
}

@Test @MainActor func recordingsModelCancellationCannotRestorePlaybackAfterAccountClose() async throws {
    let base = temporaryRecordingDirectory(); defer { try? FileManager.default.removeItem(at: base) }
    let downloads = try downloader(base: base)
    let transport = RoutedTransport { _, _ in try Fixture.response(["item": RecordingFixture.card(url: "https://storage.fixture/wait")]) }
    let model = RecordingsModel(client: try RecordingFixture.client(transport), downloads: downloads)
    let row = RecordingLibraryItem(conference: RecordingFixture.meeting(), recording: MeetingRecording(id: RecordingFixture.recording, conferenceID: RecordingFixture.conference, mode: "composite", status: "ready", createdAt: Date()))
    await model.select(row)
    let pending = Task { await model.download(fileID: RecordingFixture.file, play: true) }
    for _ in 0..<100 where !model.downloading { await Task.yield() }
    await model.close(); await pending.value
    #expect(model.selected == nil && model.playbackURL == nil && model.exportURL == nil && !model.downloading)
    await model.load()
    #expect(model.items.isEmpty)
}

@Test func recordingPermissionsFollowActualParticipantAndRequesterPolicy() {
    let conference = RecordingFixture.meeting()
    let memberID = UUID()
    let member = ConferenceParticipant(id: UUID(), conferenceId: conference.id, userId: memberID, displayName: "Member")
    let recording = MeetingRecording(id: RecordingFixture.recording, conferenceID: conference.id, mode: "composite", status: "recording", createdAt: Date(), requestedBy: memberID)
    #expect(RecordingPermissions.canStart(conference: conference, participant: member, accountID: memberID))
    #expect(RecordingPermissions.canStop(recording, conference: conference, participant: member, accountID: memberID))
    let other = ConferenceParticipant(id: UUID(), conferenceId: conference.id, userId: UUID(), displayName: "Other", role: "co_host")
    #expect(!RecordingPermissions.canStop(recording, conference: conference, participant: other, accountID: other.userId!))
    let guest = ConferenceParticipant(id: UUID(), conferenceId: conference.id, userId: memberID, displayName: "Guest", role: "guest")
    #expect(!RecordingPermissions.canStart(conference: conference, participant: guest, accountID: memberID))
    #expect(!RecordingPermissions.canStop(recording, conference: conference, participant: guest, accountID: memberID))
    let unknown = MeetingRecording(id: UUID(), conferenceID: conference.id, mode: "future", status: "future", createdAt: Date())
    #expect(!unknown.ready && !unknown.active && unknown.media == nil)
}
