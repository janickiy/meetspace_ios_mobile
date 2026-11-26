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
    /// Формирует карточку записи встречи для тестового ответа.
    /// - Parameters:
    ///   - conference: Идентификатор встречи.
    ///   - status: Состояние записи.
    ///   - url: Ссылка на файл записи.
    static func card(conference: UUID = conference, status: String = "ready", url: String = "https://storage.fixture/media") -> [String: Any] {
        ["id": 42, "uuid": recording.uuidString, "conferenceId": conference.uuidString, "mode": "composite", "status": status,
         "createdAt": "2026-11-06T10:00:00.000Z", "requestedBy": Fixture.userID.uuidString,
         "files": [["uuid": file.uuidString, "recordId": 42, "fileType": "final_mp4", "fileName": "meeting.mp4", "mimeType": "video/mp4",
                    "sizeBytes": bytes.count, "checksumSha256": hash, "url": url]]]
    }
    /// Создаёт активную встречу, которой принадлежит тестовая запись.
    static func meeting() -> Conference { Conference(id: conference, ownerId: Fixture.userID, title: "Встреча", status: "active") }
    /// Формирует строку библиотеки с данными тестовой встречи и её записи.
    static func row() throws -> [String: Any] {
        ["conference": try JSONSerialization.jsonObject(with: WireJSON.encoder().encode(meeting())), "recording": card()]
    }
    /// Создаёт авторизованный клиент для запросов библиотеки записей.
    /// - Parameter transport: Транспорт API.
    static func client(_ transport: any RequestTransport) throws -> AuthenticatedClient {
        AuthenticatedClient(account: try Fixture.account(), credentials: Fixture.credentials(), secureStore: TestSecrets(), transport: transport)
    }
    /// Готовит метаданные файла для проверки загрузки и целостности.
    /// - Parameters:
    ///   - hash: Ожидаемая контрольная сумма.
    ///   - size: Ожидаемый размер в байтах.
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
    /// Регистрирует начало скачивания по адресу для проверки порядка запросов.
    /// - Parameter url: Адрес загружаемого файла.
    func mark(_ url: URL) { lock.withLock { _ = started.insert(url.absoluteString) } }
    /// Проверяет, началась ли загрузка по указанному адресу.
    /// - Parameter url: Адрес файла.
    func contains(_ url: URL) -> Bool { lock.withLock { started.contains(url.absoluteString) } }
}
private final class RecordingProtocol: URLProtocol, @unchecked Sendable {
    static let requests = RecordingRequests()
    /// Определяет, относится ли запрос к домену тестового протокола.
    /// - Parameter request: Входящий сетевой запрос.
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "storage.fixture" }
    /// Возвращает запрос в исходном виде для обработки тестовым URLProtocol.
    /// - Parameter request: Запрос тестовой сессии.
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    /// Проверяет отсутствие учётных данных в запросе хранилища и выдаёт тестовый файл.
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
    /// Завершает обработку команды остановки для тестового URLProtocol без фоновой передачи.
    override func stopLoading() {}
}
private func downloader(base: URL) throws -> URLSessionRecordingDownloader {
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [RecordingProtocol.self]
    return URLSessionRecordingDownloader(account: try Fixture.account(), baseDirectory: base, configuration: configuration)
}
private func temporaryRecordingDirectory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("recording-test-" + UUID().uuidString) }

/// Real ephemeral URLSession/disk/hash cleanup; URLProtocol supplies fixture bytes, not a server.
@Test func stage08ThirtyRecordingDownloadAndCancelCyclesCleanFiles() async throws {
    let base = temporaryRecordingDirectory(); defer { try? FileManager.default.removeItem(at: base) }
    for _ in 0..<30 {
        let downloads = try downloader(base: base)
        let local = try await downloads.download(url: URL(string: "https://storage.fixture/media")!, file: RecordingFixture.metadata(), progress: nil)
        #expect(try Data(contentsOf: local) == RecordingFixture.bytes)
        await downloads.remove(local)
        #expect(!FileManager.default.fileExists(atPath: local.path))
        let url = URL(string: "https://storage.fixture/wait?run=" + UUID().uuidString)!
        let pending = Task { try await downloads.download(url: url, file: RecordingFixture.metadata(), progress: nil) }
        for _ in 0..<200 {
            if RecordingProtocol.requests.contains(url) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(RecordingProtocol.requests.contains(url))
        await downloads.close()
        await #expect(throws: CancellationError.self) { try await pending.value }
        let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? []
        #expect(files.allSatisfy { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) != true })
    }
}

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
    /// Задаёт локальный файл, доступ к которому тест отзовёт после загрузки.
    /// - Parameter url: Локальный URL тестового файла.
    init(url: URL) { self.url = url }
    /// Имитирует завершившуюся загрузку перед повторной проверкой доступа.
    /// - Parameters:
    ///   - url: Адрес источника.
    ///   - file: Метаданные файла.
    ///   - progress: Обработчик обновления прогресса.
    func download(url: URL, file: RecordingFile, progress: TransferProgress?) async throws -> URL { started = true; return self.url }
    /// Фиксирует удаление файла при утрате доступа.
    /// - Parameter url: Адрес локальной копии.
    func remove(_ url: URL) { removed = true }
    /// Фиксирует очистку загрузчика при закрытии.
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

private actor DelayedRecordingCancellation: RecordingDownloading {
    let oldURL = URL(fileURLWithPath: "/tmp/recording-old-operation-fixture.mp4")
    let newURL = URL(fileURLWithPath: "/tmp/recording-new-operation-fixture.mp4")
    private(set) var removed: [URL] = []
    private var requests = 0
    private var cancelled = false
    private var released = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelledWaiters: [CheckedContinuation<Void, Never>] = []
    private var held: CheckedContinuation<Void, Never>?
    /// Удерживает первый запрос до отмены и возвращает отдельный файл для следующей загрузки.
    /// - Parameters:
    ///   - url: Адрес источника.
    ///   - file: Метаданные файла.
    ///   - progress: Обработчик прогресса.
    func download(url: URL, file: RecordingFile, progress: TransferProgress?) async throws -> URL {
        requests += 1
        guard requests == 1 else { return newURL }
        for waiter in startedWaiters { waiter.resume() }; startedWaiters = []
        // Deliberately ignore cancellation until explicitly released: real transport cleanup
        // can take time, and reentrant UI work must remain safe during that interval.
        await withTaskCancellationHandler {
            await waitForRelease()
        } onCancel: {
            Task { await self.markCancelled() }
        }
        return oldURL
    }
    /// Дожидается начала первого скачивания.
    func waitForFirstRequest() async {
        if requests > 0 { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }
    /// Дожидается, когда загрузчик получит отмену первого запроса.
    func waitForCancellation() async {
        if cancelled { return }
        await withCheckedContinuation { cancelledWaiters.append($0) }
    }
    /// Фиксирует отмену и возобновляет ожидающие её задачи.
    private func markCancelled() {
        cancelled = true
        for waiter in cancelledWaiters { waiter.resume() }; cancelledWaiters = []
    }
    /// Приостанавливает завершение старой загрузки до разрешения теста.
    private func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { held = $0 }
    }
    /// Разрешает завершение первого запроса загрузчика.
    func releaseFirst() { released = true; held?.resume(); held = nil }
    /// Запоминает адрес удаляемого файла для проверки очистки.
    /// - Parameter url: Локальный URL файла.
    func remove(_ url: URL) { removed.append(url) }
    /// Снимает блокировку первого запроса при закрытии загрузчика.
    func close() { releaseFirst() }
}

@Test @MainActor func recordingsBackCannotDeleteNewPlaybackWhileOldCancellationDrains() async throws {
    let downloads = DelayedRecordingCancellation()
    let transport = RoutedTransport { request, _ in
        if request.url?.path == "/api/v1/recordings" { throw APIError.offline }
        return try Fixture.response(["item": RecordingFixture.card()])
    }
    let model = RecordingsModel(client: try RecordingFixture.client(transport), downloads: downloads)
    let row = RecordingLibraryItem(conference: RecordingFixture.meeting(), recording: MeetingRecording(id: RecordingFixture.recording,
        conferenceID: RecordingFixture.conference, mode: "composite", status: "ready", createdAt: Date()))
    await model.select(row)
    let oldDownload = Task { await model.download(fileID: RecordingFixture.file, play: true) }
    await downloads.waitForFirstRequest()
    let leaving = Task { await model.back() }
    await downloads.waitForCancellation()
    #expect(model.selected == nil && !model.downloading)

    // Reopen the same recording and complete a fresh authorized transfer before the old one exits.
    await model.select(row)
    await model.download(fileID: RecordingFixture.file, play: true)
    let currentURL = downloads.newURL
    #expect(model.playbackURL == currentURL)
    await model.load() // A new, unrelated error must also survive completion of the old back().
    let currentError = try #require(model.error)
    await downloads.releaseFirst()
    await oldDownload.value; await leaving.value

    #expect(model.selected?.id == row.id && model.playbackURL == currentURL)
    #expect(model.error == currentError)
    #expect(await downloads.removed.contains(downloads.oldURL))
    #expect(await !downloads.removed.contains(currentURL))
    await model.close()
}

@Test @MainActor func recordingDetailDropsPlaybackOnRevokedRefreshAndCanRetry() async throws {
    actor Access {
        private(set) var allowed = true
        /// Меняет результат последующей проверки доступа к файлу.
        /// - Parameter value: Разрешить ли доступ.
        func setAllowed(_ value: Bool) { allowed = value }
    }
    let access = Access()
    let downloads = RevokeAfterDownload(url: URL(fileURLWithPath: "/tmp/recording-refresh-fixture.mp4"))
    let transport = RoutedTransport { _, _ in
        guard await access.allowed else { return NetworkResponse(status: 403) }
        return try Fixture.response(["item": RecordingFixture.card()])
    }
    let model = RecordingsModel(client: try RecordingFixture.client(transport), downloads: downloads)
    let row = RecordingLibraryItem(conference: RecordingFixture.meeting(), recording: MeetingRecording(
        id: RecordingFixture.recording, conferenceID: RecordingFixture.conference,
        mode: "composite", status: "ready", createdAt: Date()))
    await model.select(row)
    await model.download(fileID: RecordingFixture.file, play: true)
    #expect(model.playbackURL != nil)
    await access.setAllowed(false)
    await model.select(row)
    #expect(model.selected == nil && model.playbackURL == nil && model.error != nil)
    #expect(await downloads.removed)
    await access.setAllowed(true)
    await model.select(row)
    #expect(model.selected?.id == row.id && model.playbackURL == nil && model.error == nil)
    await model.close()
}

@Test @MainActor func recordingDetailExportsTrackArchivesWithoutPlayingThem() async throws {
    let archiveURL = URL(fileURLWithPath: "/tmp/recording-tracks-fixture.zip")
    let downloads = RevokeAfterDownload(url: archiveURL)
    let transport = RoutedTransport { _, _ in
        var card = RecordingFixture.card(status: "partial_ready")
        card["mode"] = "individual_tracks"
        card["files"] = [["uuid": RecordingFixture.file.uuidString, "recordId": 42,
                          "fileType": "tracks_archive", "fileName": "tracks.zip",
                          "mimeType": "application/zip", "url": "https://storage.fixture/archive"]]
        return try Fixture.response(["item": card])
    }
    let model = RecordingsModel(client: try RecordingFixture.client(transport), downloads: downloads)
    let row = RecordingLibraryItem(conference: RecordingFixture.meeting(), recording: MeetingRecording(
        id: RecordingFixture.recording, conferenceID: RecordingFixture.conference,
        mode: "individual_tracks", status: "partial_ready", createdAt: Date()))
    await model.select(row)
    #expect(model.selected?.recording.media == nil)
    await model.download(fileID: RecordingFixture.file, play: true)
    #expect(await !downloads.started)
    await model.download(fileID: RecordingFixture.file, play: false)
    #expect(model.exportURL == archiveURL && model.playbackURL == nil)
    await model.dismissExport()
    #expect(model.exportURL == nil)
    #expect(await downloads.removed)
    await model.close()
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

@Test @MainActor func recordingLibraryDeleteChecksOwnershipStatusAndServerResult() async throws {
    for status in [403, 200] {
        let transport = RoutedTransport { request, _ in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/v1/recordings"):
                return try Fixture.response(["items": [RecordingFixture.row()]])
            case ("DELETE", RecordingFixture.path + "/" + RecordingFixture.recording.uuidString.lowercased()):
                return NetworkResponse(status: status)
            default: throw APIError.invalidResponse
            }
        }
        let model = RecordingsModel(client: try RecordingFixture.client(transport))
        await model.load()
        let row = try #require(model.items.first)
        #expect(model.selected == nil)
        #expect(!RecordingPermissions.canDelete(row, accountID: UUID()))
        let inProgress = MeetingRecording(id: row.id, conferenceID: row.conference.id, mode: "composite", status: "processing", createdAt: Date())
        #expect(!RecordingPermissions.canDelete(RecordingLibraryItem(conference: row.conference, recording: inProgress), accountID: model.account.user.id))
        await model.delete(row)
        #expect(model.items.isEmpty == (status == 200))
        #expect((model.error != nil) == (status == 403))
        if status == 200 { await model.delete(row) }
        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["GET", "DELETE"])
    }
}

@Test func recordingLibraryPreviewDistinguishesActiveMeetingFromOngoingRecording() throws {
    let account = try Fixture.account()
    let activeMeeting = RecordingFixture.meeting()
    func entry(status: String, duration: Int? = nil) -> RecordingLibraryEntry {
        let record = MeetingRecording(id: RecordingFixture.recording, conferenceID: activeMeeting.id, mode: "composite",
                                      status: status, createdAt: Date(), durationSec: duration)
        return RecordingLibraryEntry(row: RecordingLibraryItem(conference: activeMeeting, recording: record), account: account)
    }
    let completed = entry(status: "ready", duration: 120)
    #expect(completed.isLive && !completed.isCapturing && completed.durationText == "02:00")
    let missingDuration = entry(status: "ready")
    #expect(!missingDuration.isCapturing && missingDuration.durationText == nil)
    #expect(entry(status: "recording").isCapturing)
    #expect(!entry(status: "processing").isCapturing)
}
