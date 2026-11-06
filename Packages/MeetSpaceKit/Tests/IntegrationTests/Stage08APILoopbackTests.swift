import Foundation
import Testing
import MeetSpaceCore
import MeetSpaceAPI

/// Opt-in fixture transport only. Host, random port and HTTPS input are validated
/// before adapting to the disposable container's HTTP listener on loopback.
private final class Stage08LoopbackHTTP: NSObject, RequestTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private let port: Int
    private var session: URLSession!
    private let lock = NSLock()
    private var requests = 0
    private var deletionStatuses: [Int] = []
    var requestCount: Int { lock.withLock { requests } }
    var deletes: [Int] { lock.withLock { deletionStatuses } }
    init(port: Int) {
        self.port = port; super.init()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 25
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    func send(_ request: URLRequest, limit: Int, uploadFile: URL?, progress: TransferProgress?) async throws -> NetworkResponse {
        guard let url = request.url, url.host == "127.0.0.1", url.scheme == "https", url.port == port,
              url.user == nil, url.password == nil, uploadFile == nil else { throw ClientError.scopeMismatch }
        lock.withLock { requests += 1 }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!; parts.scheme = "http"
        var local = request; local.url = parts.url
        let (bytes, incoming) = try await session.bytes(for: local)
        defer { bytes.task.cancel() }
        guard let response = incoming as? HTTPURLResponse, incoming.expectedContentLength <= Int64(limit) else { throw APIError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw APIError.responseTooLarge }; data.append(byte)
        }
        if request.httpMethod == "DELETE", url.path == "/api/v1/auth/me" {
            lock.withLock { deletionStatuses.append(response.statusCode) }
            #expect(response.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        }
        return NetworkResponse(status: response.statusCode, headers: response.allHeaderFields.reduce(into: [:]) {
            $0[String(describing: $1.key).lowercased()] = String(describing: $1.value)
        }, data: data)
    }
    func cancelAll() async { for task in await session.allTasks { task.cancel() } }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MEETSPACE_STAGE08_API_PORT"] != nil))
func stage08ActualBackendAccountDeletion() async throws {
    let port = try #require(Int(ProcessInfo.processInfo.environment["MEETSPACE_STAGE08_API_PORT"] ?? ""))
    try #require((1025...65535).contains(port))
    let origin = try ServerOrigin("https://127.0.0.1:\(port)"), transport = Stage08LoopbackHTTP(port: port)
    let auth = AuthenticationGateway(origin: origin, transport: transport), store = TestSecrets()
    let password = UUID().uuidString, otherPassword = UUID().uuidString, suffix = UUID().uuidString.lowercased()
    let email = "delete-\(suffix)@example.test", otherEmail = "survivor-\(suffix)@example.test"
    _ = try await auth.register(email: email, password: password, name: "Disposable deletion account")
    _ = try await auth.register(email: otherEmail, password: otherPassword, name: "Unaffected account")
    let firstLogin = try await auth.login(email: email, password: password)
    let secondLogin = try await auth.login(email: email, password: password)
    let otherLogin = try await auth.login(email: otherEmail, password: otherPassword)
    let first = AuthenticatedClient(account: firstLogin.account, credentials: firstLogin.credentials, secureStore: store, transport: transport)
    let second = AuthenticatedClient(account: secondLogin.account, credentials: secondLogin.credentials, secureStore: store, transport: transport)
    let other = AuthenticatedClient(account: otherLogin.account, credentials: otherLogin.credentials, secureStore: store, transport: transport)
    do {
        let otherFolders = FoldersRepository(client: other)
        let retainedFolder = try await otherFolders.create(name: "Survives other account deletion")
        let oldPreference = try await SettingsRepository(client: other).preferences()
        await #expect(throws: AccountDeletionError.passwordRejected) { try await first.deleteAccount(password: "wrong-" + password) }
        try #require(transport.deletes == [422])
        try #require(try await first.currentUser().id == firstLogin.account.user.id)
        try #require(try await second.currentUser().id == firstLogin.account.user.id)
        print("PASS real Stage8 deletion password rejection: HTTP422; both existing sessions remain authorized; no automatic DELETE retry")

        let ownCalendar = CalendarRepository(client: first)
        let ownedMeeting = try await ownCalendar.create(title: "Deletion ownership guard", at: Date().addingTimeInterval(86400), duration: 30, waitingRoom: false)
        await #expect(throws: AccountDeletionError.conflict) { try await first.deleteAccount(password: password) }
        try #require(transport.deletes == [422, 409])
        try #require(try await first.currentUser().id == firstLogin.account.user.id)
        _ = try await ownCalendar.cancel(ownedMeeting.id)
        print("PASS real Stage8 deletion ownership guard: scheduled meeting owner receives409; session remains valid; meeting cancelled through API before deletion")

        try await first.deleteAccount(password: password)
        try #require(transport.deletes == [422, 409, 200])
        // Probe both original bearer tokens directly: no client refresh hides the status.
        for login in [firstLogin, secondLogin] {
            var request = URLRequest(url: try EndpointURL.make(origin, path: ["auth", "me"]))
            request.setValue("Bearer \(login.credentials.accessToken)", forHTTPHeaderField: "Authorization")
            let denied = try await transport.send(request, limit: 65_536, uploadFile: nil, progress: nil)
            try #require(denied.status == 401)
            let cookie = try #require(login.credentials.sessionCookie)
            await #expect(throws: APIError.httpStatus(401)) { try await auth.refresh(userID: login.account.user.id, cookie: cookie) }
        }
        await #expect(throws: APIError.httpStatus(401)) { try await auth.login(email: email, password: password) }
        print("PASS real Stage8 deletion confirmation: HTTP200 success/no-store; two bearer tokens, two refresh cookies and fresh password login rejected with401")

        #expect(try await other.currentUser().id == otherLogin.account.user.id)
        #expect(try await otherFolders.list().contains { $0.id == retainedFolder.id })
        #expect(try await SettingsRepository(client: other).preferences() == oldPreference)
        let freshOther = try await auth.login(email: otherEmail, password: otherPassword)
        #expect(freshOther.account.user.id == otherLogin.account.user.id)
        try await auth.logout(userID: freshOther.account.user.id, credentials: freshOther.credentials)
        #expect(try await other.close(logout: true))
        _ = try await first.close(); _ = try await second.close()
        print("PASS real Stage8 account isolation: other account/folder/preferences and fresh login survive; remaining sessions logged out; HTTP requests=\(transport.requestCount)")
    } catch {
        _ = try? await first.close(logout: true); _ = try? await second.close(logout: true); _ = try? await other.close(logout: true)
        throw error
    }
}
