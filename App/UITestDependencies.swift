#if DEBUG
import Foundation
import MeetSpaceCore
import MeetSpaceAPI
import MeetSpaceFeatures
import MeetSpaceRealtime
import MeetSpaceMedia
import SwiftUI

/// Only explicit DEBUG UI-test launches use doubles. No network or persistent test credentials.
enum UITestDependencies {
    static func make() -> AppDependencies {
        let server = Server()
        return AppDependencies(serverProbe: Probe(), configuration: Preferences(), credentials: Secrets(),
                               transport: { server }, sockets: QuietSockets(),
                               conferenceSockets: ConferenceSockets(server: server), media: { Media() })
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
    private struct ConferenceSockets: ConferenceSocketFactory {
        let server: Server
        func connect(origin: ServerOrigin, conferenceID: UUID, ticket: String) async throws -> any ConferenceSocket {
            guard origin.displayName == "fixture.example" else { throw APIError.offline }
            let socket = MeetingSocket(conferenceID: conferenceID)
            await socket.deliver(try await server.conferenceState(conferenceID))
            return socket
        }
    }
    private actor MeetingSocket: ConferenceSocket {
        let conferenceID: UUID
        let mediaPeerID = UUID()
        let stream: AsyncThrowingStream<Data, Error>
        let continuation: AsyncThrowingStream<Data, Error>.Continuation
        init(conferenceID: UUID) {
            self.conferenceID = conferenceID
            (stream, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(128))
        }
        func deliver(_ bytes: Data) { continuation.yield(bytes) }
        private func event(_ type: String, _ data: [String: Any], reply: UUID? = nil) throws {
            var envelope: [String: Any] = ["version": 1, "id": UUID().uuidString.lowercased(), "type": type,
                "conferenceId": conferenceID.uuidString.lowercased(), "timestamp": "2026-11-05T10:00:00Z", "data": data]
            if let reply { envelope["replyTo"] = reply.uuidString.lowercased() }
            continuation.yield(try JSONSerialization.data(withJSONObject: envelope))
        }
        func send(_ data: Data) throws {
            let command = try ConferenceEnvelope.decode(data, conferenceID: conferenceID)
            switch command.type {
            case "media.join":
                try event("media.joined", ["mediaPeerId": mediaPeerID.uuidString.lowercased(), "maxPeers": 8,
                    "tracks": [], "iceServers": [], "videoCapture": ["maxWidth": 1280, "maxHeight": 720, "maxFrameRate": 30],
                    "policy": ["version": 1, "microphoneBlocked": false, "cameraBlocked": false, "screenBlocked": false, "kicked": false]], reply: command.id)
            case "media.offer":
                struct Offer: Decodable { let negotiationId: String }
                let offer = try command.payload(Offer.self)
                try event("media.answer", ["mediaPeerId": mediaPeerID.uuidString.lowercased(), "negotiationId": offer.negotiationId,
                    "sdp": "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:0\r\na=sendrecv\r\n"], reply: command.id)
            case "media.ready": try event("ack", ["type": "media.ready"], reply: command.id)
            case "media.ice": break
            case "media.leave": try event("media.left", ["mediaPeerId": mediaPeerID.uuidString.lowercased()], reply: command.id)
            default: throw ConferenceSignalError.invalidPayload
            }
        }
        func receive() async throws -> Data {
            var iterator = stream.makeAsyncIterator()
            guard let bytes = try await iterator.next() else { throw CancellationError() }
            return bytes
        }
        func close() { continuation.finish() }
    }
    /// Explicit UI-test media double: never requests OS permissions or creates a native capture session.
    @MainActor private final class Media: ConferenceMediaEngine {
        let events: AsyncStream<ConferenceMediaEvent>
        let continuation: AsyncStream<ConferenceMediaEvent>.Continuation
        let localVideoTrackID = "fixture-local-camera"
        private var microphone = false, camera = false, closed = false, front = true
        private var microphoneAllowed = true, cameraAllowed = true
        init() { (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(128)) }
        func configure(_ configuration: ConferenceMediaConfiguration) {
            microphoneAllowed = configuration.microphoneAllowed; cameraAllowed = configuration.cameraAllowed
            continuation.yield(.audioRoute("Динамик"))
        }
        func makeOffer(iceRestart: Bool) throws -> ConferenceMediaOffer {
            guard !closed else { throw CancellationError() }
            return ConferenceMediaOffer(sdp: "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:0\r\na=recvonly\r\n", publications: [])
        }
        func applyAnswer(_ sdp: String) { if !closed { continuation.yield(.connectionState(.connected)) } }
        func addRemoteCandidate(_ candidate: MeetSpaceMedia.ConferenceICECandidate) {}
        func setPublicationPermissions(microphone: Bool, camera: Bool) throws {
            microphoneAllowed = microphone; cameraAllowed = camera
            if !microphone { try setMicrophoneEnabled(false) }; if !camera { try setCameraEnabled(false) }
        }
        func setMicrophoneEnabled(_ enabled: Bool) throws {
            guard !closed else { throw CancellationError() }
            if enabled && ProcessInfo.processInfo.arguments.contains("-media-permission-denied") { throw ConferenceMediaError.microphonePermissionDenied }
            guard !enabled || microphoneAllowed else { throw ConferenceMediaError.publicationBlocked }
            microphone = enabled; captureChanged(); continuation.yield(.negotiationNeeded)
        }
        func setCameraEnabled(_ enabled: Bool) throws {
            guard !closed else { throw CancellationError() }
            if enabled && ProcessInfo.processInfo.arguments.contains("-media-permission-denied") { throw ConferenceMediaError.cameraPermissionDenied }
            guard !enabled || cameraAllowed else { throw ConferenceMediaError.publicationBlocked }
            camera = enabled; captureChanged()
            if enabled { continuation.yield(.videoTrackAdded(ConferenceVideoTrack(id: localVideoTrackID, mid: nil, streamID: nil, isLocal: true))) }
            else { continuation.yield(.videoTrackRemoved(localVideoTrackID)) }
            continuation.yield(.negotiationNeeded)
        }
        func switchCamera() { front.toggle(); captureChanged() }
        func setSpeakerEnabled(_ enabled: Bool) { continuation.yield(.audioRoute(enabled ? "Динамик" : "Телефон")) }
        func suspend() { microphone = false; camera = false; captureChanged(); continuation.yield(.videoTrackRemoved(localVideoTrackID)) }
        func close() { closed = true; microphone = false; camera = false; continuation.finish() }
        func videoView(trackID: String, mirrored: Bool) -> AnyView {
            AnyView(ZStack { Color(red: 0.16, green: 0.22, blue: 0.34); Text("Тестовое видео").foregroundStyle(.white) })
        }
        private func captureChanged() { continuation.yield(.captureState(microphone: microphone, camera: camera, frontCamera: front)) }
    }
    private actor Server: RequestTransport {
        private let first = "11111111-1111-4111-8111-111111111111"
        private let second = "11111111-1111-4111-8111-111111111112"
        private let peer = "11111111-1111-4111-8111-111111111113"
        private let direct = "22222222-2222-4222-8222-222222222222"
        private let groupID = "22222222-2222-4222-8222-222222222223"
        private let conferenceID = "33333333-3333-4333-8333-333333333333"
        private let participantID = "44444444-4444-4444-8444-444444444444"
        private let remoteParticipantID = "44444444-4444-4444-8444-444444444445"
        private var conference: [String: Any]?
        private var conferenceJoined = false
        private var conferenceMicrophone = false, conferenceCamera = false
        private var conferenceMessages: [[String: Any]] = []
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
        private func member(remote: Bool = false) -> [String: Any] {
            ["id": remote ? remoteParticipantID : participantID, "conferenceId": conferenceID,
             "userId": remote ? peer : first, "displayName": remote ? "Тестовый участник" : "Первый аккаунт",
             "role": remote ? "participant" : "owner", "status": remote || conferenceJoined ? "joined" : "left",
             "createdAt": "2026-11-05T10:00:00Z", "updatedAt": "2026-11-05T10:00:00Z",
             "microphoneEnabled": remote ? false : conferenceMicrophone, "cameraEnabled": remote ? false : conferenceCamera,
             "screenSharing": false, "microphoneBlocked": false, "cameraBlocked": false, "screenBlocked": false,
             "mediaPolicyVersion": 1, "admissionState": "admitted", "admissionVersion": 1]
        }
        func conferenceState(_ id: UUID) throws -> Data {
            guard id.uuidString.lowercased() == conferenceID, conferenceJoined else { throw APIError.httpStatus(403) }
            var own = member(), remote = member(remote: true)
            own["online"] = true; remote["online"] = true
            return try JSONSerialization.data(withJSONObject: ["version": 1, "id": UUID().uuidString.lowercased(),
                "type": "conference.state", "conferenceId": conferenceID, "timestamp": "2026-11-05T10:00:00Z",
                "data": ["connectionId": UUID().uuidString.lowercased(), "participantId": participantID,
                         "status": "active", "participants": [own, remote]]])
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
            if path == "/api/v1/webrtc/config" { return try response(["iceServers": [], "iceTransportPolicy": "all"]) }
            if path == "/api/v1/conferences" {
                if request.httpMethod == "POST" {
                    conference = ["id": conferenceID, "ownerId": first, "title": body?["title"] ?? "Тестовая встреча",
                        "inviteCode": String(repeating: "a", count: 32), "inviteUrl": "https://fixture.example/i/" + String(repeating: "a", count: 32),
                        "status": "created", "createdAt": "2026-11-05T10:00:00Z", "updatedAt": "2026-11-05T10:00:00Z",
                        "waitingRoomEnabled": body?["waitingRoomEnabled"] ?? false]
                    return try response(["status": "success", "item": conference!], status: 201)
                }
                return try response(["status": "success", "items": conference.map { [$0] } ?? []])
            }
            if parts.count >= 4, parts[2] == "conferences", parts[3] == conferenceID, conference != nil {
                if parts.count == 4 { return try response(["status": "success", "item": conference!]) }
                if path.hasSuffix("/start") { conference?["status"] = "active"; return try response(["status": "success", "item": conference!]) }
                if path.hasSuffix("/join") { conferenceJoined = true; return try response(["status": "success", "item": member()]) }
                if path.hasSuffix("/leave") { conferenceJoined = false; return try response(["status": "success", "item": member()]) }
                if path.hasSuffix("/participants/me") { return try response(["status": "success", "item": member()]) }
                if path.hasSuffix("/participants/me/media") {
                    conferenceMicrophone = body?["microphoneEnabled"] as? Bool ?? false
                    conferenceCamera = body?["cameraEnabled"] as? Bool ?? false
                    return try response(["status": "success", "item": member()])
                }
                if path.hasSuffix("/participants") { return try response(["status": "success", "items": [member(), member(remote: true)]]) }
                if path.hasSuffix("/reactions") { return try response(["status": "success"]) }
                if path.hasSuffix("/chat/read") { return try response(["status": "success", "item": ["unreadCount": 0]]) }
                if path.hasSuffix("/messages"), request.httpMethod == "POST" {
                    let message: [String: Any] = ["id": UUID().uuidString.lowercased(), "sequence": String(conferenceMessages.count + 1),
                        "conferenceId": conferenceID, "senderId": first, "senderName": "Первый аккаунт",
                        "clientRequestId": body?["clientRequestId"] ?? UUID().uuidString.lowercased(), "text": body?["text"] ?? "",
                        "version": 1, "createdAt": "2026-11-05T10:00:00Z", "updatedAt": "2026-11-05T10:00:00Z", "attachments": []]
                    conferenceMessages.append(message)
                    return try response(["status": "success", "item": message], status: 201)
                }
                if path.hasSuffix("/messages") { return try response(["status": "success", "items": conferenceMessages, "unreadCount": 0]) }
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
