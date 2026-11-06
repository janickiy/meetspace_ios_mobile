import Foundation
import Testing
import MeetSpaceCore
import MeetSpaceAPI

/// Only this explicitly opted-in test translates the configured random loopback port to HTTP.
/// App traffic keeps the production HTTPS/TLS and account-scope policies.
private final class FeaturesLoopbackHTTP: NSObject, RequestTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private let port: Int
    private var session: URLSession!
    private let lock = NSLock()
    private var requests = 0
    var requestCount: Int { lock.withLock { requests } }
    init(port: Int) {
        self.port = port; super.init()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 25
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    func send(_ request: URLRequest, limit: Int, uploadFile: URL?, progress: TransferProgress?) async throws -> NetworkResponse {
        guard let url = request.url, url.host == "127.0.0.1", url.scheme == "https", url.port == port,
              url.user == nil, url.password == nil, uploadFile == nil else { throw ClientError.scopeMismatch }
        lock.withLock { requests += 1 }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!; parts.scheme = "http"
        var local = request; local.url = parts.url
        let (data, response) = try await session.data(for: local)
        guard let response = response as? HTTPURLResponse, data.count <= limit else { throw APIError.invalidResponse }
        return NetworkResponse(status: response.statusCode, headers: response.allHeaderFields.reduce(into: [:]) {
            $0[String(describing: $1.key).lowercased()] = String(describing: $1.value)
        }, data: data)
    }
    func cancelAll() async { for task in await session.allTasks { task.cancel() } }
}

private func requireFeaturesDenied<T>(_ operation: () async throws -> T) async throws {
    do { _ = try await operation(); Issue.record("Server allowed another account to access a private resource") }
    catch APIError.httpStatus(let status) { #expect(status == 403 || status == 404) }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MEETSPACE_FEATURES_API_PORT"] != nil))
func actualBackendCalendarFoldersSettingsAndRecordings() async throws {
    let port = try #require(Int(ProcessInfo.processInfo.environment["MEETSPACE_FEATURES_API_PORT"] ?? ""))
    #expect((1025...65535).contains(port))
    let origin = try ServerOrigin("https://127.0.0.1:\(port)")
    let transport = FeaturesLoopbackHTTP(port: port), secrets = TestSecrets()
    let auth = AuthenticationGateway(origin: origin, transport: transport)
    let password = UUID().uuidString, suffix = UUID().uuidString.lowercased()
    var clients: [AuthenticatedClient] = []
    for index in 0..<3 {
        let email = "features-\(index)-\(suffix)@example.test"
        _ = try await auth.register(email: email, password: password, name: "Features \(index)")
        let login = try await auth.login(email: email, password: password)
        clients.append(AuthenticatedClient(account: login.account, credentials: login.credentials, secureStore: secrets, transport: transport))
    }
    let a = clients[0], b = clients[1], c = clients[2]
    let calendarA = CalendarRepository(client: a), calendarB = CalendarRepository(client: b)
    let conferencesA = ConferenceRepository(client: a), conferencesB = ConferenceRepository(client: b)
    let at = try #require(ISO8601DateFormatter().date(from: "2099-11-01T23:30:00+03:00"))
    let movedAt = try #require(ISO8601DateFormatter().date(from: "2099-11-02T01:15:00+05:45"))
    let planned = try await calendarA.create(title: "iOS Stage 7 calendar", at: at, duration: 45, waitingRoom: false)
    #expect(planned.status == "scheduled" && planned.scheduledAt == at && planned.plannedDurationMin == 45)
    try await requireFeaturesDenied { try await calendarB.reschedule(planned.id, at: movedAt, duration: 60) }
    let moved = try await calendarA.reschedule(planned.id, at: movedAt, duration: 60)
    #expect(moved.scheduledAt == movedAt && moved.plannedDurationMin == 60)
    for zoneID in ["Europe/Moscow", "America/New_York", "Asia/Kathmandu"] {
        let zone = try #require(TimeZone(identifier: zoneID))
        let period = MeetingCalendar.interval(containing: movedAt, mode: .month, in: zone)
        let rows = try await calendarA.timeline(view: .upcoming, scope: .owned, interval: period)
        #expect(rows.items.contains { $0.id == planned.id && $0.scheduledAt == movedAt })
        #expect(try await calendarB.timeline(view: .upcoming, interval: period).items.isEmpty)
    }
    let cancelled = try await calendarA.cancel(planned.id)
    #expect(cancelled.status == "cancelled")
    #expect(try await conferencesA.read(planned.id).status == "cancelled")
    await #expect(throws: APIError.httpStatus(409)) { try await calendarA.reschedule(planned.id, at: at, duration: 30) }
    let nowRange = DateInterval(start: Date().addingTimeInterval(-3600), end: Date().addingTimeInterval(3600))
    #expect(try await calendarA.timeline(view: .past, interval: nowRange).items.contains { $0.id == planned.id })
    print("PASS real Stage7 calendar: create/reschedule/cancel, exact UTC instants in 3 IANA zones, owner-only mutation, cancelled status conflict and actual finishedAt timeline")

    let foldersA = FoldersRepository(client: a), foldersB = FoldersRepository(client: b)
    let chatA = MessagingRepository(client: a), chatB = MessagingRepository(client: b)
    let room = try await conferencesA.create(title: "Folder content survives deletion")
    let chat = try await chatA.direct(userID: b.account.user.id)
    let message = try await chatA.send(chat.id, draft: MessageDraft(text: "Folder references do not own this content"))
    let folder1 = try await foldersA.create(name: "Проект"), folder2 = try await foldersA.create(name: "Личное")
    let foreignFolder = try await foldersB.create(name: "Личное")
    #expect(try await foldersA.rename(folder1.id, name: "Обновлённый проект").name == "Обновлённый проект")
    #expect(try await foldersA.order([folder2.id, folder1.id]).map(\.id) == [folder2.id, folder1.id])
    #expect(try await foldersA.list().map(\.id) == [folder2.id, folder1.id])
    let candidates = try await foldersA.items(folder1.id, candidates: true)
    #expect(candidates.items.contains { $0.kind == .conference && $0.itemID == room.id })
    #expect(candidates.items.contains { $0.kind == .conversation && $0.itemID == chat.id })
    _ = try await foldersA.setItem(folder1.id, kind: .conference, id: room.id, included: true)
    _ = try await foldersA.setItem(folder1.id, kind: .conversation, id: chat.id, included: true)
    let contents = try await foldersA.items(folder1.id)
    #expect(contents.items.count == 2)
    try await requireFeaturesDenied { try await foldersB.items(folder1.id) }
    try await requireFeaturesDenied { try await foldersB.rename(folder1.id, name: "Forbidden") }
    try await requireFeaturesDenied { try await foldersB.delete(folder1.id) }
    try await requireFeaturesDenied { try await foldersB.setItem(foreignFolder.id, kind: .conference, id: room.id, included: true) }
    _ = try await foldersA.setItem(folder1.id, kind: .conversation, id: chat.id, included: false)
    #expect(try await chatA.messages(chat.id).items.contains { $0.id == message.id })
    _ = try await foldersA.setItem(folder1.id, kind: .conversation, id: chat.id, included: true)
    try await foldersA.delete(folder1.id)
    #expect(try await foldersA.list().map(\.id) == [folder2.id])
    #expect(try await conferencesA.read(room.id).id == room.id)
    #expect(try await chatA.conversation(chat.id).id == chat.id)
    #expect(try await chatB.messages(chat.id).items.contains { $0.id == message.id })
    #expect(try await foldersB.list().map(\.id) == [foreignFolder.id])
    print("PASS real Stage7 folders: create/rename/order/candidates/add/remove, 4 cross-account denials, delete leaves meeting/chat/message and other account folders intact")

    let settingsA = SettingsRepository(client: a), settingsB = SettingsRepository(client: b)
    let baselineB = try await settingsB.preferences()
    #expect(try await settingsA.updateProfile(displayName: "  Новое имя iOS  ").displayName == "Новое имя iOS")
    #expect(try await settingsA.profile().displayName == "Новое имя iOS")
    #expect(try await settingsB.profile().displayName == "Features 1")
    let preferences = NotificationPreferences(invitation: false, reminder: false, recording: true, email: true, push: false)
    #expect(try await settingsA.savePreferences(preferences) == preferences)
    let restoredLogin = try await auth.login(email: "features-0-\(suffix)@example.test", password: password)
    let restored = AuthenticatedClient(account: restoredLogin.account, credentials: restoredLogin.credentials, secureStore: secrets, transport: transport)
    let restoredSettings = SettingsRepository(client: restored)
    #expect(try await restoredSettings.preferences() == preferences)
    #expect(try await restoredSettings.profile().displayName == "Новое имя iOS")
    #expect(try await settingsB.preferences() == baselineB)
    #expect(try await settingsA.devices().isEmpty)
    #expect(try await settingsA.integrations().push == "noop")
    #expect(try await settingsA.capabilities().recordingModes.sorted() == RecordingMode.allCases.map(\.rawValue).sorted())
    print("PASS real Stage7 settings: profile rename, notification preferences survive fresh login, account isolation, devices list and real capabilities (push=noop)")

    let recordingsA = RecordingsRepository(client: a), recordingsB = RecordingsRepository(client: b), recordingsC = RecordingsRepository(client: c)
    #expect(try await recordingsA.library().items.isEmpty)
    _ = try await conferencesA.join(room.id)
    _ = try await conferencesA.transition(room.id, action: "start")
    try await requireFeaturesDenied { try await recordingsB.start(conferenceID: room.id, mode: .composite) }
    _ = try await conferencesB.joinInvite(code: room.inviteCode)
    let record = try await recordingsA.start(conferenceID: room.id, mode: .composite)
    #expect(record.status == "starting" && !record.ready && record.files.isEmpty && record.requestedBy == a.account.user.id)
    #expect(try await recordingsA.list(conferenceID: room.id).contains { $0.id == record.id })
    #expect(try await recordingsB.read(conferenceID: room.id, recordingID: record.id).status == "starting")
    #expect(try await recordingsA.library().items.contains { $0.id == record.id })
    #expect(try await recordingsC.library().items.isEmpty)
    try await requireFeaturesDenied { try await recordingsC.read(conferenceID: room.id, recordingID: record.id) }
    try await requireFeaturesDenied { try await recordingsB.stop(conferenceID: room.id, recordingID: record.id) }
    await #expect(throws: APIError.httpStatus(409)) { try await recordingsA.start(conferenceID: room.id, mode: .audioOnly) }
    let stopping = try await recordingsA.stop(conferenceID: room.id, recordingID: record.id)
    #expect(stopping.status == "stopping" && !stopping.ready && stopping.files.isEmpty)
    #expect(try await recordingsA.read(conferenceID: room.id, recordingID: record.id).status == "stopping")
    _ = try await conferencesA.transition(room.id, action: "finish")
    print("PASS real Stage7 recordings: capabilities, empty/populated catalogue, starting/stopping states, duplicate-start conflict, membership/stop authorization; no recorder worker, no fabricated ready media or playback assertion")
    for client in clients + [restored] { #expect(try await client.close(logout: true)) }
    print("PASS real Stage7 cleanup: all test sessions logged out; HTTP requests=\(transport.requestCount)")
}
