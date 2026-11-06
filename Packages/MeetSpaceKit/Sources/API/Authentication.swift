import Foundation
import MeetSpaceCore

private struct LoginResponse: Decodable {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int
    let user: AccountUser
}
public struct SignedInAccount: Sendable {
    public let account: AccountRecord
    public let credentials: SessionCredentials
}

public enum SessionCookie {
    public static func extract(headers: [String: String], origin: ServerOrigin, userID: UUID, fallback: String?) throws -> String? {
        guard let raw = headers["set-cookie"] else { return fallback }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": raw], for: origin.url)
        let accountName = "meetrix_account_" + userID.uuidString.lowercased()
        let cookie = cookies.first { $0.name == accountName } ?? cookies.first { $0.name == "meetrix_session" }
        guard let cookie else { return fallback }
        guard cookie.path == "/api/v1/auth", cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == origin.url.host?.lowercased(),
              cookie.expiresDate.map({ $0 > Date() }) ?? true,
              valid(cookie.value) else { throw APIError.invalidResponse }
        return cookie.value
    }
    public static func valid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4096 &&
        value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }
    static func header(_ value: String, userID: UUID?) throws -> String {
        guard valid(value) else { throw ClientError.missingSession }
        if let userID {
            return "meetrix_session=\(value); meetrix_account_\(userID.uuidString.lowercased())=\(value)"
        }
        return "meetrix_session=\(value)"
    }
}

public struct AuthenticationGateway: Sendable {
    public let origin: ServerOrigin
    private let transport: any RequestTransport
    public init(origin: ServerOrigin, transport: any RequestTransport = URLSessionRequestTransport()) {
        self.origin = origin; self.transport = transport
    }
    public func register(email: String, password: String, name: String) async throws -> AccountUser {
        try AccountValidation.registration(email: email, password: password, name: name)
        struct Body: Encodable { let email: String; let password: String; let displayName: String? }
        let body = Body(email: try AccountValidation.email(email), password: password,
                        displayName: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : name.trimmingCharacters(in: .whitespacesAndNewlines))
        let response = try await send("register", body: WireJSON.encoder().encode(body))
        return try decodeJSON(UserResponse.self, from: response).user
    }
    public func login(email: String, password: String, previousCookie: String? = nil) async throws -> SignedInAccount {
        struct Body: Encodable { let email: String; let password: String }
        guard !password.isEmpty, password.unicodeScalars.count <= 128 else { throw ClientError.invalidInput }
        let body = Body(email: try AccountValidation.email(email), password: password)
        let response = try await send("login", body: WireJSON.encoder().encode(body), cookie: previousCookie)
        return try signedIn(response, expectedID: nil, previousCookie: nil)
    }
    public func refresh(userID: UUID, cookie: String) async throws -> SignedInAccount {
        struct Body: Encodable { let userId: String }
        let response = try await send("refresh", body: WireJSON.encoder().encode(Body(userId: userID.uuidString.lowercased())), cookie: cookie, userID: userID)
        return try signedIn(response, expectedID: userID, previousCookie: cookie)
    }
    public func logout(userID: UUID, credentials: SessionCredentials) async throws {
        struct Body: Encodable { let userId: String }
        let response = try await send("logout", body: WireJSON.encoder().encode(Body(userId: userID.uuidString.lowercased())),
                                      cookie: credentials.sessionCookie, userID: userID, bearer: credentials.accessToken)
        try requireSuccess(response)
    }
    private func send(_ action: String, body: Data, cookie: String? = nil, userID: UUID? = nil, bearer: String? = nil) async throws -> NetworkResponse {
        var request = URLRequest(url: try EndpointURL.make(origin, path: ["auth", action]))
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let cookie { request.setValue(try SessionCookie.header(cookie, userID: userID), forHTTPHeaderField: "Cookie") }
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        return try await transport.send(request, limit: 131_072, uploadFile: nil, progress: nil)
    }
    private func signedIn(_ response: NetworkResponse, expectedID: UUID?, previousCookie: String?) throws -> SignedInAccount {
        let value = try decodeJSON(LoginResponse.self, from: response)
        guard value.tokenType.lowercased() == "bearer", value.expiresIn > 0,
              !value.accessToken.isEmpty, value.accessToken.utf8.count <= 16_384,
              !value.accessToken.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              value.user.guestConferenceId == nil else { throw APIError.invalidResponse }
        guard expectedID == nil || value.user.id == expectedID else { throw ClientError.accountMismatch }
        guard let cookie = try SessionCookie.extract(headers: response.headers, origin: origin, userID: value.user.id, fallback: previousCookie)
        else { throw APIError.invalidResponse }
        return SignedInAccount(account: AccountRecord(server: origin, user: value.user),
            credentials: SessionCredentials(accessToken: value.accessToken, sessionCookie: cookie,
                expiresAt: Date().addingTimeInterval(TimeInterval(value.expiresIn))))
    }
}

public enum SessionEvent: Sendable { case expired }

public enum AccountDeletionError: Error, Equatable, Sendable {
    case passwordRejected, notAuthorized, conflict, unavailable, unconfirmed
}

/// One client owns one immutable origin/account scope and one single-flight refresh operation.
public actor AuthenticatedClient {
    public nonisolated let account: AccountRecord
    public nonisolated let events: AsyncStream<SessionEvent>
    private let continuation: AsyncStream<SessionEvent>.Continuation
    private let transport: any RequestTransport
    private let secureStore: any SecureStore
    private var credentials: SessionCredentials
    private var refreshTask: Task<SignedInAccount, Error>?
    private var closed = false
    private var expired = false

    public init(account: AccountRecord, credentials: SessionCredentials, secureStore: any SecureStore,
                transport: any RequestTransport = URLSessionRequestTransport()) {
        self.account = account; self.credentials = credentials; self.secureStore = secureStore; self.transport = transport
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }
    public func currentUser() async throws -> AccountUser {
        let user = try decodeJSON(UserResponse.self, from: await request("GET", path: ["auth", "me"])).user
        guard user.id == account.user.id else { expire(); throw ClientError.accountMismatch }
        return user
    }
    /// DELETE has no idempotency key. Reauthenticate before sending, never retry this mutation
    /// automatically, and do not interpret its password rejection as expiry of a valid session.
    public func deleteAccount(password: String) async throws {
        guard !password.isEmpty, password.unicodeScalars.count <= 128 else { throw ClientError.invalidInput }
        try ensureOpen()
        if credentials.expiresAt <= Date().addingTimeInterval(30) { try await refresh() }
        try ensureOpen()
        struct Body: Encodable { let password: String }
        var request = URLRequest(url: try EndpointURL.make(account.server, path: ["auth", "me"]))
        request.httpMethod = "DELETE"; request.httpBody = try WireJSON.encoder().encode(Body(password: password))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        let response: NetworkResponse
        do { response = try await transport.send(request, limit: 16_384, uploadFile: nil, progress: nil) }
        catch { throw AccountDeletionError.unconfirmed }
        switch response.status {
        case 400, 422: throw AccountDeletionError.passwordRejected
        case 401, 403: throw AccountDeletionError.notAuthorized
        case 409: throw AccountDeletionError.conflict
        case 404, 405, 501: throw AccountDeletionError.unavailable
        case 200:
            struct Confirmation: Decodable { let status: String }
            guard let confirmation = try? decodeJSON(Confirmation.self, from: response), confirmation.status == "success" else {
                throw AccountDeletionError.unconfirmed
            }
            // A concurrent read can observe server-side revocation before this 200 arrives.
            // Preserve the affirmative deletion result even if the old session has expired.
        default: throw AccountDeletionError.unconfirmed
        }
    }
    public func request(_ method: String, path: [String], query: [URLQueryItem] = [], body: Data? = nil,
                        uploadFile: URL? = nil, contentType: String = "application/json",
                        limit: Int = 2_097_152, progress: TransferProgress? = nil) async throws -> NetworkResponse {
        try ensureOpen()
        if credentials.expiresAt <= Date().addingTimeInterval(30) { try await refresh() }
        try ensureOpen()
        var request = URLRequest(url: try EndpointURL.make(account.server, path: path, query: query))
        request.httpMethod = method; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil || uploadFile != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let usedToken = credentials.accessToken
        request.setValue("Bearer \(usedToken)", forHTTPHeaderField: "Authorization")
        var response = try await transport.send(request, limit: limit, uploadFile: uploadFile, progress: progress)
        try ensureOpen()
        if response.status == 401 {
            // Another request may already have renewed the same rejected token.
            if credentials.accessToken == usedToken { try await refresh() }
            try ensureOpen()
            request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
            response = try await transport.send(request, limit: limit, uploadFile: uploadFile, progress: progress)
            try ensureOpen()
            if response.status == 401 { expire(); throw ClientError.sessionExpired }
        }
        try requireSuccess(response)
        return response
    }
    public func refresh() async throws {
        try ensureOpen()
        if let refreshTask {
            let result = try await refreshTask.value
            try ensureOpen(); credentials = result.credentials
            return
        }
        guard let cookie = credentials.sessionCookie else { expire(); throw ClientError.sessionExpired }
        let task = Task { [account, secureStore, transport] in
            let result = try await AuthenticationGateway(origin: account.server, transport: transport)
                .refresh(userID: account.user.id, cookie: cookie)
            try Task.checkCancellation()
            try await secureStore.write(WireJSON.encoder().encode(result.credentials), for: account.key)
            try Task.checkCancellation()
            return result
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let result = try await task.value
            try ensureOpen(); credentials = result.credentials
        } catch APIError.httpStatus(let status) where status == 401 || status == 403 {
            expire(); throw ClientError.sessionExpired
        } catch ClientError.accountMismatch {
            expire(); throw ClientError.accountMismatch
        }
    }
    /// Drain refresh persistence before deleting a credential; cancellation cannot resurrect it later.
    public func close(logout: Bool = false) async throws -> Bool {
        guard !closed else { return false }
        closed = true
        refreshTask?.cancel()
        await transport.cancelAll()
        if let refreshTask { _ = try? await refreshTask.value }
        refreshTask = nil
        continuation.finish()
        guard logout else { return false }
        var revoked = false
        do {
            try await AuthenticationGateway(origin: account.server, transport: transport)
                .logout(userID: account.user.id, credentials: credentials)
            revoked = true
        } catch { /* Local removal remains mandatory even when the server is offline. */ }
        try await secureStore.delete(account.key)
        return revoked
    }
    private func ensureOpen() throws {
        try Task.checkCancellation()
        if closed { throw CancellationError() }
        if expired { throw ClientError.sessionExpired }
    }
    private func expire() {
        guard !expired else { return }
        expired = true; continuation.yield(.expired)
    }
}
