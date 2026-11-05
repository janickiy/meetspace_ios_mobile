#if DEBUG
import Foundation
import MeetSpaceCore
import MeetSpaceAPI
import MeetSpaceFeatures
import MeetSpaceRealtime

/// Only explicit DEBUG UI-test launches use doubles. No network or persistent test credentials.
enum UITestDependencies {
    static func make() -> AppDependencies {
        let server = Server()
        return AppDependencies(serverProbe: Probe(), configuration: Preferences(), credentials: Secrets(),
                               transport: { server }, sockets: QuietSockets())
    }
    private struct Probe: ServerProbing {
        func check(_ origin: ServerOrigin) async throws -> ServerVersion {
            guard origin.displayName == "fixture.example" else { throw APIError.offline }
            return ServerVersion(version: "test", commit: "fixture", buildTime: "fixture")
        }
    }
    private actor Preferences: ConfigurationStore {
        private var value = AppConfiguration()
        func load() -> AppConfiguration { value }
        func save(_ configuration: AppConfiguration) { value = configuration }
    }
    private actor Secrets: SecureStore {
        private var values: [CredentialKey: Data] = [:]
        func read(_ key: CredentialKey) -> Data? { values[key] }
        func write(_ value: Data, for key: CredentialKey) { values[key] = value }
        func delete(_ key: CredentialKey) { values[key] = nil }
    }
    private struct QuietSockets: RealtimeSocketFactory {
        func connect(_ url: URL) async throws -> any RealtimeSocket {
            try await Task.sleep(for: .seconds(3600)); throw CancellationError()
        }
    }
    private actor Server: RequestTransport {
        private let first = "11111111-1111-4111-8111-111111111111"
        private let second = "11111111-1111-4111-8111-111111111112"
        private let peer = "11111111-1111-4111-8111-111111111113"
        private let direct = "22222222-2222-4222-8222-222222222222"
        private let groupID = "22222222-2222-4222-8222-222222222223"
        private var messages: [String: [[String: Any]]] = [:]
        private var groups: [String: [String: Any]] = [:]
        private func user(_ id: String) -> [String: Any] {
            ["id": id, "email": id == second ? "second@fixture.example" : "first@fixture.example",
             "displayName": id == second ? "Второй аккаунт" : "Первый аккаунт", "isAdmin": false,
             "createdAt": "2026-11-05T10:00:00Z", "updatedAt": "2026-11-05T10:00:00Z"]
        }
        private func conversation(_ id: String) -> [String: Any] {
            if let group = groups[id] { return group }
            return ["id": direct, "type": "direct", "peer": ["id": peer, "displayName": "Тестовый собеседник"],
                    "description": "", "updatedAt": "2026-11-05T10:00:00Z", "preview": "Проверка интерфейса чата",
                    "unreadCount": 0, "notificationsEnabled": true]
        }
        private func response(_ data: [String: Any], status: Int = 200, headers: [String: String] = [:]) throws -> NetworkResponse {
            var headers = headers; headers["content-type"] = "application/json"
            return NetworkResponse(status: status, headers: headers, data: try JSONSerialization.data(withJSONObject: data))
        }
        func send(_ request: URLRequest, limit: Int, uploadFile: URL?, progress: TransferProgress?) async throws -> NetworkResponse {
            guard request.url?.host == "fixture.example" else { throw APIError.offline }
            let path = request.url!.path.lowercased()
            let parts = path.split(separator: "/").map(String.init)
            let body = (try? request.httpBody.map { try JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? nil
            let selected = request.value(forHTTPHeaderField: "Authorization")?.hasSuffix(second) == true ? second : first
            if path.hasSuffix("/auth/register") { return try response(["status": "ok", "user": user(first)], status: 201) }
            if path.hasSuffix("/auth/login") || path.hasSuffix("/auth/refresh") {
                if ProcessInfo.processInfo.arguments.contains("-auth-error") { return NetworkResponse(status: 401) }
                let id = (body?["email"] as? String)?.hasPrefix("second") == true ? second : first
                return try response(["accessToken": "ui-fixture-\(id)", "tokenType": "Bearer", "expiresIn": 3600, "user": user(id)],
                    headers: ["set-cookie": "meetrix_session=ui-fixture-cookie; Path=/api/v1/auth; HttpOnly; Secure"])
            }
            if path.hasSuffix("/auth/me") { return try response(["status": "ok", "user": user(selected)]) }
            if path.hasSuffix("/auth/logout") { return try response(["status": "ok"]) }
            if path.hasSuffix("/ws-ticket") {
                return try response(["ticket": String(repeating: "x", count: 43), "expiresAt": "2099-01-01T00:00:00Z"], status: 201)
            }
            if path.hasSuffix("/users") {
                return try response(["status": "ok", "items": [["id": peer, "displayName": "Тестовый собеседник"]]])
            }
            if path == "/api/v1/conversations" {
                return try response(["items": [conversation(direct)] + Array(groups.values), "unreadCount": 0])
            }
            if path.hasSuffix("/conversations/direct") { return try response(["status": "ok", "item": conversation(direct)], status: 201) }
            if path.hasSuffix("/conversations/group"), request.httpMethod == "POST" {
                let group: [String: Any] = ["id": groupID, "type": "group", "name": body?["name"] ?? "Группа",
                    "description": body?["description"] ?? "", "memberCount": 2, "myRole": "owner",
                    "updatedAt": "2026-11-05T10:00:00Z", "preview": "", "unreadCount": 0, "notificationsEnabled": true]
                groups[groupID] = group
                return try response(["status": "ok", "item": group], status: 201)
            }
            if parts.count >= 4, parts[2] == "conversations" {
                let id = parts[3]
                if parts.count == 4 { return try response(["status": "ok", "item": conversation(id)]) }
                if path.hasSuffix("/members") {
                    return try response(["status": "ok", "items": [
                        ["id": selected, "displayName": user(selected)["displayName"]!, "role": "owner"],
                        ["id": peer, "displayName": "Тестовый собеседник", "role": "member"]]])
                }
                if path.hasSuffix("/chat/read") { return try response(["status": "ok", "item": ["unreadCount": 0, "lastReadMessageId": body?["messageId"] ?? NSNull()]]) }
                if path.hasSuffix("/messages"), request.httpMethod == "POST" {
                    let message: [String: Any] = ["id": UUID().uuidString, "sequence": String((messages[id]?.count ?? 0) + 1),
                        "conversationId": id, "senderId": selected, "senderName": user(selected)["displayName"]!,
                        "clientRequestId": body?["clientRequestId"] ?? UUID().uuidString, "text": body?["text"] ?? "",
                        "version": 1, "createdAt": "2026-11-05T10:00:00Z", "updatedAt": "2026-11-05T10:00:00Z", "attachments": []]
                    messages[id, default: []].append(message)
                    return try response(["status": "ok", "item": message], status: 201)
                }
                if path.hasSuffix("/messages") || path.hasSuffix("/messages/search") {
                    return try response(["status": "ok", "items": messages[id] ?? [], "unreadCount": 0])
                }
            }
            return NetworkResponse(status: 404)
        }
    }
}
#endif
