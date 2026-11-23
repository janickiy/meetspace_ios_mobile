#if DEBUG
import Foundation
import MeetSpaceCore
import MeetSpaceAPI
import MeetSpaceFeatures
import MeetSpaceRealtime
import MeetSpaceMedia
import MeetSpaceBroadcast
import MeetSpaceCalling
import SwiftUI

/// Only explicit DEBUG UI-test launches use doubles. No network or persistent test credentials.
enum UITestDependencies {
    @MainActor static func make() -> AppDependencies {
        let server = Server()
        let calling = Calling(), notifications = Notifications()
        return AppDependencies(serverProbe: Probe(), configuration: Preferences(), credentials: Secrets(),
                               transport: { server }, sockets: QuietSockets(),
                               conferenceSockets: ConferenceSockets(server: server), media: { Media() }, broadcast: { Broadcast() },
                               calling: { calling }, notifications: { notifications },
                               recordingDownloads: { _ in UITestRecordingDownloads() })
    }
    /// Broadcast subscriptions model the process-wide native provider across account replacement.
    @MainActor private final class Calling: SystemCalling {
        private var listeners: [UUID: AsyncStream<SystemCallEvent>.Continuation] = [:]
        private var pending: [UUID: SystemCallAction] = [:]
        private var audioActive = false
        let isAvailable = true
        var events: AsyncStream<SystemCallEvent> {
            let id = UUID(), pair = AsyncStream<SystemCallEvent>.makeStream()
            listeners[id] = pair.continuation; pair.continuation.yield(.audioActivationChanged(audioActive))
            pair.continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.listeners[id] = nil } }
            return pair.stream
        }
        func reportIncoming(_ descriptor: SystemCallDescriptor, completion: @escaping @Sendable (Result<Void, SystemCallingError>) -> Void) { completion(.success(())) }
        func requestStart(_ descriptor: SystemCallDescriptor) { action(.start, callID: descriptor.id) }
        func requestAnswer(callID: UUID) { action(.answer, callID: callID) }
        func requestEnd(callID: UUID) { action(.end, callID: callID) }
        func requestMuted(_ muted: Bool, callID: UUID) { action(.setMuted(muted), callID: callID) }
        func completeAction(id: UUID, succeeded: Bool) {
            guard let action = pending.removeValue(forKey: id), succeeded else { return }
            if action.kind == .start || action.kind == .answer { audioActive = true; emit(.audioActivationChanged(true)) }
            if action.kind == .end { audioActive = false; emit(.audioActivationChanged(false)) }
        }
        func reportConnecting(callID: UUID, at date: Date?) {}
        func reportConnected(callID: UUID, at date: Date?) {}
        func reportEnded(callID: UUID, reason: SystemCallEndReason, at date: Date?) { audioActive = false; emit(.audioActivationChanged(false)) }
        func updateCall(_ descriptor: SystemCallDescriptor) {}
        func invalidate() { for listener in listeners.values { listener.finish() }; listeners.removeAll() }
        private func action(_ kind: SystemCallAction.Kind, callID: UUID) {
            let action = SystemCallAction(id: UUID(), callID: callID, kind: kind, deadline: Date().addingTimeInterval(30))
            pending[action.id] = action; emit(.action(action))
        }
        private func emit(_ event: SystemCallEvent) { for listener in listeners.values { listener.yield(event) } }
    }
    @MainActor private final class Notifications: NormalPushNotifications {
        private var listeners: [UUID: AsyncStream<NormalPushNotificationEvent>.Continuation] = [:]
        private(set) var authorization = NormalPushAuthorization.notDetermined
        var events: AsyncStream<NormalPushNotificationEvent> {
            let id = UUID(), pair = AsyncStream<NormalPushNotificationEvent>.makeStream()
            listeners[id] = pair.continuation
            pair.continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.listeners[id] = nil } }
            return pair.stream
        }
        func requestAuthorization() -> NormalPushAuthorization { authorization = .authorized; emit(.authorization(authorization)); return authorization }
        func refreshAuthorization() { emit(.authorization(authorization)) }
        func register() { emit(.token(Data(repeating: 0x45, count: 32))) }
        func unregister() {}
        func didRegister(deviceToken: Data) { emit(.token(deviceToken)) }
        func didFailRegistration() { emit(.failure(.registrationFailed)) }
        private func emit(_ event: NormalPushNotificationEvent) { for listener in listeners.values { listener.yield(event) } }
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
                struct Offer: Decodable { let negotiationId: String; let publications: [ConferenceMediaPublication] }
                let offer = try command.payload(Offer.self)
                if ProcessInfo.processInfo.arguments.contains("-screen-conflict"), offer.publications.contains(where: { $0.source == "video/screen" }) {
                    try event("error", ["code": "screen_sharing_conflict", "message": "Screen busy"], reply: command.id)
                    return
                }
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
    /// Explicit DEBUG fixture: lifecycle/frame delivery is simulated; no system picker is exercised.
    @MainActor private final class Broadcast: ScreenBroadcastController {
        let events: AsyncStream<ScreenBroadcastEvent>
        let frames: AsyncStream<ScreenBroadcastFrame>
        private let event: AsyncStream<ScreenBroadcastEvent>.Continuation
        private let frame: AsyncStream<ScreenBroadcastFrame>.Continuation
        let isAvailable = true
        let extensionBundleID: String? = "fixture.broadcast"
        private(set) var sessionID: UUID?
        private var task: Task<Void, Never>?
        init() { (events, event) = AsyncStream.makeStream(); (frames, frame) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1)) }
        func prepare(configuration: ScreenBroadcastConfiguration) {
            let id = UUID(); sessionID = id
            task = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, self.sessionID == id else { return }
                self.event.yield(.started(id))
                var stamp: Int64 = 0
                while !Task.isCancelled, self.sessionID == id {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    stamp += 100_000_000
                    self.frame.yield(ScreenBroadcastFrame(sessionID: id, width: 2, height: 2, rowBytes: 8,
                        timestampNs: stamp, pixels: Data(repeating: 0, count: 16)))
                }
            }
        }
        func stop() { task?.cancel(); task = nil; sessionID = nil }
    }
    /// Explicit UI-test media double: never requests OS permissions or creates a native capture session.
    @MainActor private final class Media: ConferenceMediaEngine {
        let events: AsyncStream<ConferenceMediaEvent>
        let continuation: AsyncStream<ConferenceMediaEvent>.Continuation
        let localVideoTrackID = "fixture-local-camera"
        private var microphone = false, camera = false, closed = false, front = true
        private var microphoneAllowed = true, cameraAllowed = true, screenAllowed = false, screen = false
        init() { (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(128)) }
        var localScreenVideoTrackID: String { "fixture-screen" }
        func rollbackLocalOffer() async throws {}
        func setScreenEnabled(_ enabled: Bool) async throws {
            guard !enabled || (screenAllowed && cameraAllowed) else { throw ConferenceMediaError.publicationBlocked }
            screen = enabled; continuation.yield(.screenCaptureState(enabled)); continuation.yield(.negotiationNeeded)
        }
        func pushScreenFrame(_ frame: ScreenBroadcastFrame) throws {}
        func configure(_ configuration: ConferenceMediaConfiguration) {
            microphoneAllowed = configuration.microphoneAllowed; cameraAllowed = configuration.cameraAllowed
            continuation.yield(.audioRoute("Динамик"))
        }
        func makeOffer(iceRestart: Bool) throws -> ConferenceMediaOffer {
            guard !closed else { throw CancellationError() }
            return ConferenceMediaOffer(sdp: "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:0\r\na=recvonly\r\n", publications: screen ? [.init(mid: "2", source: "video/screen", trackId: localScreenVideoTrackID)] : [])
        }
        func applyAnswer(_ sdp: String) { if !closed { continuation.yield(.connectionState(.connected)) } }
        func addRemoteCandidate(_ candidate: MeetSpaceMedia.ConferenceICECandidate) {}
        func setPublicationPermissions(microphone: Bool, camera: Bool, screen: Bool) throws {
            microphoneAllowed = microphone; cameraAllowed = camera; screenAllowed = screen && camera
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
        private var lastCallRequestID: String?
        private let callRoomID = "33333333-3333-4333-8333-333333333334"
        private var call: [String: Any]?
        private var incomingCreated = false
        private var pushPreferences: [String: Any] = ["invitation": true, "reminder": true, "recording": true, "email": false, "push": false]
        private var pushDevice: [String: Any]?
        private var conference: [String: Any]?
        private var conferenceJoined = false
        private var conferenceMicrophone = false, conferenceCamera = false
        private var conferenceMessages: [[String: Any]] = []
        private var roomRecording: [String: Any]?
        private var messages: [String: [[String: Any]]] = [:]
        private var groups: [String: [String: Any]] = [:]
        private var directNotifications: [String: Bool] = [:]
        private var clearedDirectCount: [String: Int] = [:]
        private var directHidden: Set<String> = []
        private var profileNames: [String: String] = [:]
        private var deletedAccounts: Set<String> = []
        private var folders: [[String: Any]] = []
        private struct FolderMember: Hashable {
            let kind: String
            let id: String
        }
        private var folderMembers: [String: Set<FolderMember>] = [:]
        init() {
            if ProcessInfo.processInfo.arguments.contains("-meeting-actions-fixture") {
                let code = String(repeating: "a", count: 32)
                conference = ["id": conferenceID, "ownerId": first, "title": "Проверка действий со встречей",
                              "inviteCode": code, "inviteUrl": "https://fixture.example/i/" + code,
                              "status": "active", "waitingRoomEnabled": false, "scheduledAt": "2026-11-05T10:00:00Z",
                              "startedAt": "2026-11-05T10:00:00Z", "createdAt": "2026-11-05T09:00:00Z",
                              "updatedAt": "2026-11-05T10:00:00Z"]
            }
            if ProcessInfo.processInfo.arguments.contains("-chat-header-fixture") {
                messages[direct] = [[
                    "id": "88888888-8888-4888-8888-888888888888", "sequence": "1", "conversationId": direct,
                    "senderId": peer, "senderName": "Тестовый собеседник", "clientRequestId": UUID().uuidString,
                    "text": "Сообщение для проверки истории", "version": 1, "createdAt": "2026-11-05T10:00:00Z",
                    "updatedAt": "2026-11-05T10:00:00Z", "attachments": []
                ]]
                folders = [["id": "77777777-7777-4777-8777-777777777777", "name": "Проверка", "position": 0,
                            "createdAt": "2026-11-06T10:00:00Z", "updatedAt": "2026-11-06T10:00:00Z",
                            "itemCount": 0, "conversationCount": 0, "conferenceCount": 0]]
            }
        }
        private func user(_ id: String) -> [String: Any] {
            ["id": id, "email": id == second ? "second@fixture.example" : "first@fixture.example",
             "displayName": profileNames[id] ?? (id == second ? "Второй аккаунт" : "Первый аккаунт"), "isAdmin": false,
             "createdAt": "2026-11-05T10:00:00Z", "updatedAt": "2026-11-05T10:00:00Z"]
        }
        private func conversation(_ id: String, account: String? = nil) -> [String: Any] {
            if let group = groups[id] { return group }
            let user = account ?? first
            let preview: String
            if let messages = messages[direct] {
                preview = messages.dropFirst(clearedDirectCount[user] ?? 0).last?["text"] as? String ?? ""
            } else { preview = "Проверка интерфейса чата" }
            return ["id": direct, "type": "direct", "peer": ["id": peer, "displayName": "Тестовый собеседник"],
                    "description": "", "updatedAt": "2026-11-05T10:00:00Z", "preview": preview,
                    "unreadCount": 0, "notificationsEnabled": directNotifications[user] ?? true]
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
        private func conferenceMembers() -> [[String: Any]] {
            let remote = member(remote: true)
            var members = [member(), remote]
            if ProcessInfo.processInfo.arguments.contains("-conference-three-participants") {
                var guest = remote
                guest["id"] = "44444444-4444-4444-8444-444444444446"
                guest["userId"] = second
                guest["displayName"] = "Гость"
                members.append(guest)
            }
            return members
        }
        private func callMember(remote: Bool = false) -> [String: Any] {
            var result = member(remote: remote)
            result["conferenceId"] = callRoomID; result["status"] = "joined"; result["role"] = "participant"
            return result
        }
        private func newCall(incoming: Bool, clientID: String) -> [String: Any] {
            ["id": UUID().uuidString.lowercased(), "conversationId": direct, "callerUserId": incoming ? peer : first,
             "calleeUserId": incoming ? first : peer, "callerClientId": clientID,
             "caller": ["id": incoming ? peer : first, "displayName": incoming ? "Тестовый собеседник" : "Первый аккаунт"],
             "callee": ["id": incoming ? first : peer, "displayName": incoming ? "Первый аккаунт" : "Тестовый собеседник"],
             "status": "ringing", "version": 1, "createdAt": ISO8601DateFormatter().string(from: Date()),
             "expiresAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(90)), "durationSec": 0]
        }
        func conferenceState(_ id: UUID) throws -> Data {
            if id.uuidString.lowercased() == callRoomID, call?["status"] as? String == "accepted" {
                var own = callMember(), remote = callMember(remote: true); own["online"] = true; remote["online"] = true
                return try JSONSerialization.data(withJSONObject: ["version": 1, "id": UUID().uuidString.lowercased(),
                    "type": "conference.state", "conferenceId": callRoomID, "timestamp": "2026-11-06T10:00:00Z",
                    "data": ["connectionId": UUID().uuidString.lowercased(), "participantId": participantID,
                             "status": "active", "participants": [own, remote]]])
            }
            guard id.uuidString.lowercased() == conferenceID, conferenceJoined else { throw APIError.httpStatus(403) }
            let participants = conferenceMembers().map { member in
                var online = member
                online["online"] = true
                return online
            }
            return try JSONSerialization.data(withJSONObject: ["version": 1, "id": UUID().uuidString.lowercased(),
                "type": "conference.state", "conferenceId": conferenceID, "timestamp": "2026-11-05T10:00:00Z",
                "data": ["connectionId": UUID().uuidString.lowercased(), "participantId": participantID,
                         "status": "active", "participants": participants]])
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
                if path.hasSuffix("/auth/login"), ProcessInfo.processInfo.arguments.contains("-auth-retry"),
                   body?["password"] as? String != "48291607" {
                    return NetworkResponse(status: 401)
                }
                let id = (body?["email"] as? String)?.hasPrefix("second") == true || body?["userId"] as? String == second ? second : first
                if deletedAccounts.contains(id) { return NetworkResponse(status: 401) }
                return try response(["accessToken": "ui-fixture-\(id)", "tokenType": "Bearer", "expiresIn": 3600, "user": user(id)],
                    headers: ["set-cookie": "meetrix_session=ui-fixture-cookie; Path=/api/v1/auth; HttpOnly; Secure"])
            }
            if path.hasSuffix("/auth/me") {
                if deletedAccounts.contains(selected) { return NetworkResponse(status: 401) }
                if request.httpMethod == "DELETE" {
                    guard body?["password"] as? String == "fixture-password" else { return NetworkResponse(status: 422) }
                    if ProcessInfo.processInfo.arguments.contains("-delete-account-unconfirmed") { throw APIError.timeout }
                    if ProcessInfo.processInfo.arguments.contains("-delete-account-conflict") { return NetworkResponse(status: 409) }
                    deletedAccounts.insert(selected)
                    return try response(["status": "success"])
                }
                if request.httpMethod == "PATCH", let name = body?["displayName"] as? String { profileNames[selected] = name }
                return try response(["status": "ok", "user": user(selected)])
            }
            if path.hasSuffix("/auth/logout") { return try response(["status": "ok"]) }
            if path.hasSuffix("/ws-ticket") {
                return try response(["ticket": String(repeating: "x", count: 43), "expiresAt": "2099-01-01T00:00:00Z"], status: 201)
            }
            if path.hasSuffix("/users") {
                return try response(["status": "ok", "items": [["id": peer, "displayName": "Тестовый собеседник"]]])
            }
            if path == "/api/v1/integrations/capabilities" {
                return try response(["push": "http", "email": "noop", "calendar": "noop", "calendarOAuthConfigured": false, "mockConnectAllowed": false])
            }
            if let feature = try featureResponse(request, parts: parts, body: body) { return feature }
            if path == "/api/v1/notifications" { return try response(["items": [], "unreadCount": 0]) }
            if path == "/api/v1/notifications/preferences" {
                if request.httpMethod == "PUT", let body { pushPreferences = body }
                return try response(pushPreferences)
            }
            if path == "/api/v1/notifications/devices", request.httpMethod == "POST" {
                pushDevice = ["id": "66666666-6666-4666-8666-666666666666", "platform": "ios", "provider": "http",
                    "createdAt": "2026-11-06T10:00:00Z", "updatedAt": "2026-11-06T10:00:00Z"]
                return try response(["item": pushDevice!], status: 201)
            }
            if path == "/api/v1/notifications/devices" { return try response(["items": pushDevice.map { [$0] } ?? []]) }
            if path.hasPrefix("/api/v1/notifications/devices/"), request.httpMethod == "DELETE" {
                pushDevice = nil; return NetworkResponse(status: 204)
            }
            if path == "/api/v1/calls", request.httpMethod == "POST" {
                let requestID = body?["clientRequestId"] as? String
                if let requestID, requestID == lastCallRequestID, let call { return try response(["item": call]) }
                lastCallRequestID = requestID
                call = newCall(incoming: false, clientID: body?["clientId"] as? String ?? UUID().uuidString.lowercased())
                return try response(["item": call!], status: 201)
            }
            if path == "/api/v1/calls/active" {
                if !incomingCreated, ProcessInfo.processInfo.arguments.contains("-call-incoming") {
                    lastCallRequestID = nil
                    incomingCreated = true; call = newCall(incoming: true, clientID: "77777777-7777-4777-8777-777777777777")
                }
                let active = ["ringing", "accepted"].contains(call?["status"] as? String ?? "")
                return try response(["item": active ? call! : NSNull()])
            }
            if parts.count >= 4, parts[2] == "calls", parts[3] == call?["id"] as? String {
                if path.hasSuffix("/accept") {
                    call?["status"] = "accepted"; call?["version"] = 2; call?["conferenceId"] = callRoomID
                    call?["acceptedAt"] = ISO8601DateFormatter().string(from: Date())
                    call?["acceptedByClientId"] = ProcessInfo.processInfo.arguments.contains("-call-other-device")
                        ? "88888888-8888-4888-8888-888888888888" : body?["clientId"]
                } else if ["decline", "cancel", "end"].contains(parts.last ?? "") {
                    call?["status"] = parts.last == "decline" ? "declined" : parts.last == "cancel" ? "cancelled" : "ended"
                    call?["version"] = 3; call?["endedAt"] = ISO8601DateFormatter().string(from: Date())
                }
                return try response(["item": call!])
            }
            if parts.count >= 4, parts[2] == "conferences", parts[3] == callRoomID {
                if path.hasSuffix("/participants/me") || path.hasSuffix("/participants/me/media") {
                    return try response(["item": callMember()])
                }
                return NetworkResponse(status: 404)
            }
            if path == "/api/v1/webrtc/config" { return try response(["iceServers": [], "iceTransportPolicy": "all"]) }
            if path == "/api/v1/conferences" {
                if request.httpMethod == "POST" {
                    conference = ["id": conferenceID, "ownerId": first, "title": body?["title"] ?? "Тестовая встреча",
                        "inviteCode": String(repeating: "a", count: 32), "inviteUrl": "https://fixture.example/i/" + String(repeating: "a", count: 32),
                        "status": "created", "createdAt": "2026-11-05T10:00:00Z", "updatedAt": "2026-11-05T10:00:00Z",
                        "waitingRoomEnabled": body?["waitingRoomEnabled"] ?? false]
                    if let at = body?["scheduledAt"] {
                        conference?["scheduledAt"] = at; conference?["status"] = "scheduled"
                        conference?["plannedDurationMin"] = body?["plannedDurationMin"]
                    }
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
                if path.hasSuffix("/participants") { return try response(["status": "success", "items": conferenceMembers()]) }
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
                let personal = directHidden.contains(selected) ? [] : [conversation(direct, account: selected)]
                return try response(["items": personal + Array(groups.values), "unreadCount": 0])
            }
            if path.hasSuffix("/conversations/direct") {
                directHidden.remove(selected)
                return try response(["status": "ok", "item": conversation(direct, account: selected)], status: 201)
            }
            if path.hasSuffix("/conversations/group"), request.httpMethod == "POST" {
                let group: [String: Any] = ["id": groupID, "type": "group", "name": body?["name"] ?? "Группа",
                    "description": body?["description"] ?? "", "memberCount": 2, "myRole": "owner",
                    "updatedAt": "2026-11-05T10:00:00Z", "preview": "", "unreadCount": 0, "notificationsEnabled": true]
                groups[groupID] = group
                return try response(["status": "ok", "item": group], status: 201)
            }
            if parts.count >= 4, parts[2] == "conversations" {
                let id = parts[3]
                if parts.count == 4 { return try response(["status": "ok", "item": conversation(id, account: selected)]) }
                if id == direct, request.httpMethod == "GET" {
                    if parts.count == 5, parts[4] == "peer-presence" {
                        return try response(["status": "success", "item": ["conversationId": direct, "peerId": peer, "online": true]])
                    }
                    if parts.count == 6, parts[4] == "profiles", parts[5] == peer {
                        return try response(["item": ["id": peer, "displayName": "Тестовый собеседник",
                                                       "email": "peer@example.org", "bio": "Команда проекта."]])
                    }
                }
                if id == direct, path.hasSuffix("/preferences"), request.httpMethod == "PATCH" {
                    guard let enabled = body?["notificationsEnabled"] as? Bool else { return NetworkResponse(status: 400) }
                    directNotifications[selected] = enabled
                    return try response(["status": "success", "item": conversation(id, account: selected)])
                }
                if id == direct, request.httpMethod == "POST", path.hasSuffix("/clear-history") || path.hasSuffix("/hide") {
                    let cutoff = messages[id]?.count ?? 0
                    clearedDirectCount[selected] = cutoff
                    if path.hasSuffix("/hide") {
                        directHidden.insert(selected)
                        return try response(["status": "success", "hidden": true, "historyClearedThrough": cutoff])
                    }
                    return try response(["status": "success", "item": conversation(id, account: selected)])
                }
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
                    let visible = (messages[id] ?? []).dropFirst(id == direct ? clearedDirectCount[selected] ?? 0 : 0)
                    return try response(["status": "ok", "items": Array(visible), "unreadCount": 0])
                }
            }
            return NetworkResponse(status: 404)
        }
        private func featureResponse(_ request: URLRequest, parts: [String], body: [String: Any]?) throws -> NetworkResponse? {
            let path = request.url!.path.lowercased(), method = request.httpMethod ?? "GET"
            let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            if path == "/api/v1/capabilities" {
                return try response(["capabilities": ["recordingModes": ["composite", "audio_only"]], "buildVersion": "ui-fixture"])
            }
            if path == "/api/v1/recordings" {
                let rows: [[String: Any]] = [UITestRecordingFixture.recordingID, UITestRecordingFixture.processingID, UITestRecordingFixture.failedID, UITestRecordingFixture.audioID].map { id in
                    ["conference": recordingConference(), "recording": recordingFixture(id)]
                }
                return try response(["items": rows])
            }
            if parts.count >= 5, parts[2] == "conferences", parts[4] == "recordings" {
                if ProcessInfo.processInfo.arguments.contains("-recording-access-denied") { return NetworkResponse(status: 403) }
                if parts[3] == conferenceID {
                    if parts.count == 5, method == "GET" { return try response(["items": roomRecording.map { [$0] } ?? []]) }
                    guard method == "POST", conferenceJoined else { return NetworkResponse(status: 403) }
                    if parts.count == 5, roomRecording == nil,
                       let mode = body?["mode"] as? String, ["composite", "audio_only"].contains(mode) {
                        let item: [String: Any] = ["id": 5, "uuid": UUID().uuidString.lowercased(), "conferenceId": conferenceID,
                            "mode": mode, "status": "recording", "requestedBy": first,
                            "createdAt": ISO8601DateFormatter().string(from: Date()), "files": []]
                        roomRecording = item
                        return try response(["item": item], status: 202)
                    }
                    if parts.count == 7, parts[6] == "stop", var item = roomRecording,
                       item["uuid"] as? String == parts[5], item["status"] as? String == "recording" {
                        item["status"] = "processing"
                        roomRecording = item
                        return try response(["item": item], status: 202)
                    }
                    return NetworkResponse(status: 409)
                }
                if parts.count == 5 { return try response(["items": []]) }
                return try response(["item": recordingFixture(parts[5])])
            }
            if path == "/api/v1/me/conferences" {
                let matches = conference.map { meeting in
                    let status = meeting["status"] as? String ?? ""
                    return query["view"] == "upcoming" ? status == "scheduled" || status == "created"
                        : query["view"] == "active" ? status == "active" : status == "cancelled" || status == "finished"
                } ?? false
                return try response(["items": matches ? [conference!] : []])
            }
            if path == "/api/v1/conferences/\(conferenceID)/schedule", conference != nil {
                conference?["scheduledAt"] = body?["scheduledAt"]
                conference?["plannedDurationMin"] = body?["plannedDurationMin"]
                return try response(["item": conference!])
            }
            if path == "/api/v1/conferences/\(conferenceID)/cancel", conference != nil {
                conference?["status"] = "cancelled"; return try response(["item": conference!])
            }
            if path == "/api/v1/folders" {
                if method == "POST" {
                    let id = UUID().uuidString.lowercased()
                    let folder: [String: Any] = ["id": id, "name": body?["name"] ?? "Папка", "position": folders.count,
                        "createdAt": "2026-11-06T10:00:00Z", "updatedAt": "2026-11-06T10:00:00Z",
                        "itemCount": 0, "conversationCount": 0, "conferenceCount": 0]
                    folders.append(folder); return try response(["item": folder], status: 201)
                }
                if let itemID = query["itemId"], let kind = query["itemKind"] {
                    let member = FolderMember(kind: kind, id: itemID)
                    return try response(["items": folders.map { folder in
                        var result = folder
                        result["contains"] = folderMembers[folder["id"] as? String ?? ""]?.contains(member) == true
                        return result
                    }])
                }
                return try response(["items": folders])
            }
            if path == "/api/v1/folders/order", let ids = body?["ids"] as? [String] {
                folders = ids.enumerated().compactMap { index, id in
                    guard var folder = folders.first(where: { $0["id"] as? String == id }) else { return nil }
                    folder["position"] = index; return folder
                }
                return try response(["items": folders])
            }
            if path == "/api/v1/folder-items" {
                let included = folderMembers[query["folderId"] ?? ""]?.contains(FolderMember(kind: "conversation", id: direct)) == true
                return try response(["items": [["type": "conversation", "item": conversation(direct), "inFolder": included]]])
            }
            if parts.count >= 4, parts[2] == "folders", let index = folders.firstIndex(where: { $0["id"] as? String == parts[3] }) {
                let id = parts[3]
                if parts.count == 4 {
                    if method == "DELETE" { folders.remove(at: index); folderMembers[id] = nil; return try response(["status": "success"]) }
                    if method == "PATCH" { folders[index]["name"] = body?["name"] }
                } else if parts.count == 5 {
                    let items: [[String: Any]] = (folderMembers[id] ?? []).sorted { $0.id < $1.id }.compactMap { member in
                        if member.kind == "conversation" { return ["type": member.kind, "item": conversation(member.id)] }
                        guard let conference, conference["id"] as? String == member.id else { return nil }
                        return ["type": member.kind, "item": conference]
                    }
                    return try response(["items": items])
                } else if parts.count == 7 {
                    let member = FolderMember(kind: parts[5], id: parts[6])
                    if method == "PUT" { folderMembers[id, default: []].insert(member) }
                    else { folderMembers[id]?.remove(member) }
                    let members = folderMembers[id] ?? []
                    folders[index]["itemCount"] = members.count
                    folders[index]["conversationCount"] = members.filter { $0.kind == "conversation" }.count
                    folders[index]["conferenceCount"] = members.filter { $0.kind == "conference" }.count
                }
                return try response(["item": folders[index]])
            }
            return nil
        }
        private func recordingConference() -> [String: Any] {
            ["id": UITestRecordingFixture.conferenceID, "ownerId": first, "title": "Обсуждение проекта",
             "inviteCode": "", "inviteUrl": "", "status": "finished", "createdAt": "2026-11-06T08:00:00Z",
             "updatedAt": "2026-11-06T08:02:00Z", "waitingRoomEnabled": false]
        }
        private func recordingFixture(_ id: String) -> [String: Any] {
            let audio = id == UITestRecordingFixture.audioID
            let ready = id == UITestRecordingFixture.recordingID || audio
            let file: [String: Any] = ["uuid": UITestRecordingFixture.fileID, "recordId": audio ? 4 : 1,
                "fileType": audio ? "final_audio" : "final_mp4", "fileName": audio ? "meeting.m4a" : "meeting.mp4", "mimeType": audio ? "audio/mp4" : "video/mp4",
                "sizeBytes": audio ? UITestRecordingFixture.audioData.count : UITestRecordingFixture.data.count,
                "checksumSha256": audio ? UITestRecordingFixture.audioSHA256 : UITestRecordingFixture.sha256,
                "url": audio ? "https://recording.fixture/meeting.m4a" : "https://recording.fixture/meeting.mp4"]
            return ["id": audio ? 4 : ready ? 1 : id == UITestRecordingFixture.processingID ? 2 : 3, "uuid": id,
                "conferenceId": UITestRecordingFixture.conferenceID, "mode": audio ? "audio_only" : "composite",
                "status": ready ? "ready" : id == UITestRecordingFixture.processingID ? "processing" : "failed",
                "createdAt": "2026-11-06T08:00:00Z", "requestedBy": first, "durationSec": audio ? 8 : ready ? 2 : 0,
                "files": ready ? [file] : []]
        }
    }
}
#endif
