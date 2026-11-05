import Foundation
import Observation
import MeetSpaceCore
import MeetSpaceAPI
import MeetSpaceRealtime
import MeetSpaceMedia

public enum ConferencePhase: String, Sendable {
    case prejoin, waiting, connecting, connected, reconnecting, suspended, ended, failed
}

/// One session is permanently scoped to one identity and room; each connection has its own generation.
@MainActor @Observable public final class ConferenceSession: Identifiable {
    public let id = UUID()
    public let conferenceID: UUID
    public let title: String
    public let repository: ConferenceRepository
    public private(set) var phase: ConferencePhase
    public private(set) var participant: ConferenceParticipant
    public private(set) var participants: [ConferenceParticipant] = []
    public private(set) var messages: [ConferenceMessage] = []
    public private(set) var microphone = false
    public private(set) var camera = false
    public private(set) var frontCamera = true
    public private(set) var speaker = true
    public private(set) var audioRoute = ""
    public private(set) var microphoneBlocked = false
    public private(set) var cameraBlocked = false
    public private(set) var media: (any ConferenceMediaEngine)?
    public private(set) var videoTracks: [ConferenceVideoTrack] = []
    public private(set) var tracks: [ConferenceSignalTrack] = []
    public private(set) var lastReaction: String?
    public private(set) var busy = false
    public private(set) var departureUncertain = false
    public var error: String?
    public var wantsMicrophone = false
    public var wantsCamera = false
    public var chatText = ""
    public var chatVisible = false
    @ObservationIgnored private let sockets: any ConferenceSocketFactory
    @ObservationIgnored private let makeMedia: @MainActor @Sendable () -> any ConferenceMediaEngine
    @ObservationIgnored private let sleep: @Sendable (Double) async throws -> Void
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var foreground = true
    @ObservationIgnored private var attemptTask: Task<Void, Never>?
    @ObservationIgnored private var receiveTask: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var deviceTask: Task<Void, Never>?
    @ObservationIgnored private var initialDevicesTask: Task<Void, Never>?
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored private var connectionDeadlineTask: Task<Void, Never>?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?
    @ObservationIgnored private var leaveTask: Task<Void, Never>?
    @ObservationIgnored private var leaveDeadlineTask: Task<Void, Never>?
    @ObservationIgnored private var departureResult: Bool?
    @ObservationIgnored private var departureWaiters: [CheckedContinuation<Bool, Never>] = []
    @ObservationIgnored private var presenceTask: Task<Void, Never>?
    @ObservationIgnored private var pendingPresence: ConferenceMediaState?
    @ObservationIgnored private var lobbyTask: Task<Void, Never>?
    @ObservationIgnored private var socket: (any ConferenceSocket)?
    @ObservationIgnored private var connectionID: UUID?
    @ObservationIgnored private var peerID: UUID?
    @ObservationIgnored private var joinRequest: UUID?
    @ObservationIgnored private var offerRequest: UUID?
    @ObservationIgnored private var readyRequest: UUID?
    @ObservationIgnored private var negotiationID: UUID?
    @ObservationIgnored private var offerBusy = false
    @ObservationIgnored private var needsOffer = false
    @ObservationIgnored private var answerApplied = false
    @ObservationIgnored private var hasSentOffer = false
    @ObservationIgnored private var readyAcknowledged = false
    @ObservationIgnored private var rtcConnected = false
    @ObservationIgnored private var gatheringComplete = false
    @ObservationIgnored private var rawVideoTracks: [ConferenceVideoTrack] = []
    @ObservationIgnored private var answerTracks: [String: AnswerTrack] = [:]
    @ObservationIgnored private var videoParticipants: [String: UUID] = [:]
    @ObservationIgnored private var screenVideoIDs: Set<String> = []
    @ObservationIgnored private var localICE: [MeetSpaceMedia.ConferenceICECandidate] = []
    @ObservationIgnored private var remoteICE: [MeetSpaceMedia.ConferenceICECandidate] = []
    @ObservationIgnored private var seenRemoteICE: [MeetSpaceMedia.ConferenceICECandidate] = []
    @ObservationIgnored private var sequence: Int64 = 0
    @ObservationIgnored private var policyVersion: Int64 = -1
    @ObservationIgnored private var revision: Int64 = -1
    @ObservationIgnored private var reconnectCount = 0
    @ObservationIgnored private var connectedAt: Date?
    @ObservationIgnored private var iceConfiguration: ICEConfiguration?
    @ObservationIgnored private var pendingMessage: MessageDraft?
    @ObservationIgnored private var messageLoading = false
    @ObservationIgnored private var messageRefreshPending = false
    @ObservationIgnored private var messageEpoch = UUID()

    public init(repository: ConferenceRepository, title: String, participant: ConferenceParticipant,
                sockets: any ConferenceSocketFactory = URLSessionConferenceSocketFactory(),
                makeMedia: @escaping @MainActor @Sendable () -> any ConferenceMediaEngine = { ConferenceMediaFactory.make() },
                sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.repository = repository; self.title = title; self.participant = participant
        conferenceID = participant.conferenceId; self.sockets = sockets; self.makeMedia = makeMedia; self.sleep = sleep
        phase = participant.isWaiting ? .waiting : .prejoin
        microphoneBlocked = participant.microphoneBlocked; cameraBlocked = participant.cameraBlocked
    }

    public func participantID(for video: ConferenceVideoTrack) -> UUID? {
        video.isLocal ? participant.id : videoParticipants[video.id]
    }
    public func isScreenTrack(_ video: ConferenceVideoTrack) -> Bool { screenVideoIDs.contains(video.id) }

    public func observeLobby() {
        guard phase == .waiting, lobbyTask == nil, !closed, foreground else { return }
        let epoch = generation
        lobbyTask = Task { [weak self] in
            defer { if let self, self.generation == epoch { self.lobbyTask = nil } }
            while let self, !self.closed, self.phase == .waiting, !Task.isCancelled {
                do {
                    let conference = try await self.repository.read(self.conferenceID)
                    guard self.isCurrent(epoch), self.foreground else { return }
                    if conference.isClosed { self.phase = .ended; return }
                    if conference.status != "active" { self.phase = .prejoin; return }
                    let current = try await self.repository.selfParticipant(self.conferenceID)
                    guard self.isCurrent(epoch), self.foreground else { return }
                    self.participant = current
                    if current.canParticipate { self.phase = .prejoin; return }
                    if current.isRejectedOrKicked { self.phase = .ended; self.error = "Вход во встречу отклонён."; return }
                } catch {
                    guard self.isCurrent(epoch) else { return }
                    self.error = userMessage(error)
                    if !Self.isRetryable(error) { self.phase = .failed; return }
                }
                do { try await self.sleep(3) } catch { return }
            }
        }
    }

    public func start() {
        guard !closed, foreground, recoveryTask == nil, [.prejoin, .suspended, .failed].contains(phase) else { return }
        reconnectCount = 0; error = nil; phase = .connecting
        launchAttempt()
    }

    private func launchAttempt() {
        let epoch = generation, cleanup = cleanupTask
        attemptTask = Task { [weak self] in
            guard let self else { return }
            do {
                await cleanup?.value; try ensure(epoch)
                let conference = try await repository.read(conferenceID); try ensure(epoch)
                guard conference.status == "active" else { phase = conference.isClosed ? .ended : .prejoin; return }
                var membership = try await repository.selfParticipant(conferenceID)
                try ensure(epoch)
                // Scheduled invitations may create an admitted but left membership before the room starts.
                if membership.status == "left", membership.isAdmitted {
                    membership = try await repository.join(conferenceID); try ensure(epoch)
                }
                participant = membership
                guard membership.canParticipate else {
                    if membership.isWaiting { phase = .waiting; observeLobby() }
                    else { phase = .ended; error = "Участие во встрече завершено." }
                    return
                }
                microphoneBlocked = membership.microphoneBlocked; cameraBlocked = membership.cameraBlocked
                policyVersion = membership.mediaPolicyVersion
                let config = try await repository.ice()
                try ensure(epoch)
                if let expiry = config.expiresAt, expiry > 0, expiry <= Date().timeIntervalSince1970 + 30 {
                    throw ConferenceMediaError.invalidConfiguration
                }
                iceConfiguration = config
                let ticket = try await repository.ticket(conferenceID, clientID: id)
                try ensure(epoch)
                let opened = try await sockets.connect(origin: repository.origin, conferenceID: conferenceID, ticket: ticket.ticket)
                guard isCurrent(epoch) else { await opened.close(); return }
                socket = opened
                let (events, continuation) = AsyncThrowingStream<ConferenceEnvelope, Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
                // Keep receive pumping even while permission dialogs or SDP operations are suspended.
                receiveTask = Task {
                    do {
                        while !Task.isCancelled {
                            let bytes = try await opened.receive()
                            try Task.checkCancellation()
                            let event = try ConferenceEnvelope.decode(bytes, conferenceID: self.conferenceID)
                            if case .dropped = continuation.yield(event) { throw RealtimeError.disconnected }
                        }
                    } catch { continuation.finish(throwing: error) }
                }
                eventTask = Task { [weak self] in
                    do {
                        for try await event in events {
                            guard let self, self.isCurrent(epoch) else { return }
                            try await self.handle(event, epoch: epoch)
                        }
                    } catch {
                        guard let self, self.isCurrent(epoch) else { return }
                        self.recover(error)
                    }
                }
                armDeadline(seconds: 20, epoch: epoch)
                if let expiry = config.expiresAt, expiry > 0 {
                    expiryTask = Task { [weak self] in
                        guard let self else { return }
                        do { try await self.sleep(max(1, expiry - Date().timeIntervalSince1970 - 30)) } catch { return }
                        guard self.isCurrent(epoch), !Task.isCancelled else { return }
                        self.recover(RealtimeError.disconnected)
                    }
                }
                await refreshChat()
            } catch {
                if isCurrent(epoch) { recover(error) }
            }
        }
    }

    private struct Roster: Decodable {
        let connectionId: UUID; let participantId: UUID; let status: String
        let participants: [ConferenceParticipant]
    }
    private struct PeerCommand: Encodable { let mediaPeerId: String; let negotiationId: String }
    private struct OfferCommand: Encodable {
        let mediaPeerId: String; let negotiationId: String; let sdp: String
        let publications: [ConferenceMediaPublication]
    }
    private struct ICECommand: Encodable { let mediaPeerId: String; let candidate: MeetSpaceMedia.ConferenceICECandidate }
    private struct Reaction: Decodable { let participantId: UUID; let emoji: String }
    private struct MemberChange: Decodable { let participant: ConferenceParticipant }

    private func handle(_ event: ConferenceEnvelope, epoch: UUID) async throws {
        try ensure(epoch)
        switch event.type {
        case "conference.state", "participant.connected", "participant.disconnected":
            _ = try event.payload(ConferenceSignalState.self)
            let state = try event.payload(Roster.self)
            guard state.participantId == participant.id else { throw ClientError.accountMismatch }
            guard state.status == "active" else {
                if ["finished", "cancelled"].contains(state.status) { await leave() }
                else {
                    phase = .prejoin; wantsMicrophone = false; wantsCamera = false
                    await detachAttempt().value
                }
                return
            }
            guard connectionID == nil || connectionID == state.connectionId else { throw RealtimeError.invalidEvent }
            participants = state.participants
            if let own = participants.first(where: { $0.id == participant.id }) {
                participant = own
                if !own.canParticipate { await leave(); return }
                await applyParticipantPolicy(own)
            }
            try ensure(epoch)
            if connectionID == nil {
                connectionID = state.connectionId
                let request = UUID(); joinRequest = request
                try await send("media.join", data: [String: String](), request: request)
                armDeadline(seconds: 20, epoch: epoch)
            } else if connectionID != state.connectionId { throw RealtimeError.invalidEvent }
        case "media.joined":
            guard event.replyTo == joinRequest, joinRequest != nil, peerID == nil else { return }
            let joined = try event.payload(ConferenceSignalJoined.self)
            guard let config = iceConfiguration else { throw RealtimeError.invalidEvent }
            peerID = joined.mediaPeerId; joinRequest = nil
            tracks = joined.tracks
            if let policy = joined.policy { try await applyPolicy(policy); try ensure(epoch) }
            let engine = makeMedia(); media = engine
            deviceTask = Task { [weak self] in
                for await update in engine.events {
                    guard let self, self.isCurrent(epoch) else { return }
                    await self.handleDevice(update, epoch: epoch)
                }
            }
            let capture = joined.videoCapture
            let workerConfig = try ICEConfiguration(iceServers: joined.iceServers ?? config.iceServers,
                iceTransportPolicy: config.iceTransportPolicy, expiresAt: config.expiresAt).validated()
            try await engine.configure(ConferenceMediaConfiguration(
                iceServers: workerConfig.iceServers, iceTransportPolicy: workerConfig.iceTransportPolicy,
                maxPeers: joined.maxPeers, mediaPeerID: joined.mediaPeerId,
                maxWidth: capture.maxWidth, maxHeight: capture.maxHeight, maxFrameRate: capture.maxFrameRate,
                microphoneAllowed: !microphoneBlocked, cameraAllowed: !cameraBlocked))
            try ensure(epoch)
            needsOffer = true
            try await negotiate(epoch)
            // Permission dialogs must not block processing of policy/kick/ICE events.
            initialDevicesTask = Task { [weak self] in
                guard let self else { return }
                if isCurrent(epoch), wantsMicrophone, !microphoneBlocked {
                    do { try await engine.setMicrophoneEnabled(true) }
                    catch { if isCurrent(epoch) { self.error = mediaMessage(error) } }
                }
                guard isCurrent(epoch) else { await engine.close(); return }
                if wantsCamera, !cameraBlocked {
                    do { try await engine.setCameraEnabled(true) }
                    catch { if isCurrent(epoch) { self.error = mediaMessage(error) } }
                }
                guard isCurrent(epoch) else { await engine.close(); return }
            }
        case "media.answer":
            let answer = try event.payload(ConferenceSignalAnswer.self)
            guard answer.mediaPeerId == peerID, answer.negotiationId == negotiationID,
                  event.replyTo == offerRequest, offerRequest != nil, readyRequest == nil, let engine = media else { return }
            let bindings = try Self.answerBindings(answer.sdp)
            videoTracks.removeAll { !$0.isLocal }
            try await engine.applyAnswer(answer.sdp); try ensure(epoch)
            answerTracks = bindings; syncVideos()
            answerApplied = true
            for candidate in remoteICE { try await engine.addRemoteCandidate(candidate); try ensure(epoch) }
            remoteICE.removeAll()
            let request = UUID(); readyRequest = request
            try await send("media.ready", data: PeerCommand(mediaPeerId: answer.mediaPeerId.uuidString.lowercased(),
                negotiationId: answer.negotiationId.uuidString.lowercased()), request: request)
            armDeadline(seconds: 15, epoch: epoch)
        case "ack":
            let ack = try event.payload(ConferenceSignalAck.self)
            if ack.type == "media.ready", event.replyTo == readyRequest, readyRequest != nil {
                deadlineTask?.cancel(); readyRequest = nil; offerRequest = nil; negotiationID = nil; offerBusy = false
                readyAcknowledged = true
                if rtcConnected { markConnected(epoch) } else { armConnectionDeadline(seconds: 30, epoch: epoch) }
                try await negotiate(epoch)
            }
        case "media.ice":
            let ice = try event.payload(ConferenceSignalICE.self)
            guard ice.mediaPeerId == peerID, let value = ice.candidate else { return }
            let candidate = MeetSpaceMedia.ConferenceICECandidate(candidate: value.candidate, sdpMid: value.sdpMid,
                                                                    sdpMLineIndex: value.sdpMLineIndex ?? 0)
            guard !seenRemoteICE.contains(candidate) else { return }
            seenRemoteICE.append(candidate)
            if seenRemoteICE.count > 256 { seenRemoteICE.removeFirst() }
            if answerApplied { try await media?.addRemoteCandidate(candidate) }
            else { guard remoteICE.count < 128 else { throw RealtimeError.invalidEvent }; remoteICE.append(candidate) }
        case "media.tracks":
            let update = try event.payload(ConferenceSignalTracks.self)
            guard update.mediaPeerId == peerID, update.revision >= revision else { return }
            tracks = update.tracks; syncVideos()
            if update.revision > revision { revision = update.revision; needsOffer = true; try await negotiate(epoch) }
        case "media.renegotiate":
            let update = try event.payload(ConferenceSignalRenegotiate.self)
            guard update.mediaPeerId == peerID, update.revision > revision else { return }
            revision = update.revision; needsOffer = true; try await negotiate(epoch)
        case "media.policy":
            let update = try event.payload(ConferenceSignalPolicyUpdate.self)
            guard update.mediaPeerId == peerID else { return }
            try await applyPolicy(update.policy)
        case "participant.media.updated", "participant.role.updated":
            let changed = try event.payload(MemberChange.self).participant
            guard changed.conferenceId == conferenceID else { throw ClientError.scopeMismatch }
            if let index = participants.firstIndex(where: { $0.id == changed.id }) { participants[index] = changed }
            if changed.id == participant.id {
                participant = changed
                if !changed.canParticipate { await leave(); return }
                await applyParticipantPolicy(changed)
            }
        case "participant.kicked", "participant.waiting", "participant.admitted", "participant.rejected":
            let changed = try event.payload(MemberChange.self).participant
            guard changed.conferenceId == conferenceID else { throw ClientError.scopeMismatch }
            if let index = participants.firstIndex(where: { $0.id == changed.id }) { participants[index] = changed }
            else if participants.count < 500 { participants.append(changed) }
            if changed.id == participant.id {
                participant = changed
                if !changed.canParticipate { await leave(); return }
                await applyParticipantPolicy(changed)
            }
        case "chat.message.created", "chat.message.updated", "chat.message.deleted":
            Task { [weak self] in if let self, self.isCurrent(epoch) { await self.refreshChat() } }
        case "reaction.created":
            let reaction = try event.payload(Reaction.self)
            guard ["👍", "👏", "❤️", "😂"].contains(reaction.emoji),
                  participants.contains(where: { $0.id == reaction.participantId }) else { return }
            lastReaction = reaction.emoji
        case "error":
            let failure = try event.payload(ConferenceSignalErrorPayload.self)
            guard let reply = event.replyTo, [joinRequest, offerRequest, readyRequest].contains(reply) else { return }
            // Server rejection invalidates the pending transaction. A fresh peer avoids a stale local offer.
            if ["media_policy_blocked", "screen_sharing_conflict"].contains(failure.code) {
                wantsMicrophone = false; wantsCamera = false
            }
            throw ConferenceSignalError.disconnected(retryable: ["media_unavailable", "media_limit_exceeded", "media_ownership_lost", "media_peer_not_found", "media_policy_blocked", "screen_sharing_conflict"].contains(failure.code))
        case "media.error":
            let failure = try event.payload(ConferenceSignalMediaErrorPayload.self)
            guard failure.mediaPeerId == peerID else { return }
            // Worker codec/simulcast rejection cannot be repaired by replaying the same offer.
            throw ConferenceSignalError.disconnected(retryable: false)
        case "media.state":
            let update = try event.payload(ConferenceSignalMediaState.self)
            if update.mediaPeerId == peerID, ["failed", "closed"].contains(update.state) { throw RealtimeError.disconnected }
        case "media.left":
            struct Left: Decodable { let mediaPeerId: UUID }
            if try event.payload(Left.self).mediaPeerId == peerID { throw RealtimeError.disconnected }
        default: break
        }
    }

    private func negotiate(_ epoch: UUID) async throws {
        try ensure(epoch)
        guard needsOffer, !offerBusy, let peerID, let media else { return }
        offerBusy = true; needsOffer = false
        armDeadline(seconds: 20, epoch: epoch)
        let transaction = UUID(); negotiationID = transaction
        let offer = try await media.makeOffer(iceRestart: false); try ensure(epoch)
        let request = UUID(); offerRequest = request
        try await send("media.offer", data: OfferCommand(mediaPeerId: peerID.uuidString.lowercased(),
            negotiationId: transaction.uuidString.lowercased(), sdp: offer.sdp, publications: offer.publications), request: request)
        hasSentOffer = true
        for candidate in localICE {
            try await send("media.ice", data: ICECommand(mediaPeerId: peerID.uuidString.lowercased(), candidate: candidate))
        }
        localICE.removeAll()
        if gatheringComplete {
            gatheringComplete = false
            try await send("media.ice", data: ConferenceSignalICE(mediaPeerId: peerID, candidate: nil))
        }
        armDeadline(seconds: 20, epoch: epoch)
    }

    private func handleDevice(_ update: ConferenceMediaEvent, epoch: UUID) async {
        guard isCurrent(epoch) else { return }
        do {
            switch update {
            case .candidate(let candidate):
                guard let peerID else { return }
                if hasSentOffer {
                    try await send("media.ice", data: ICECommand(mediaPeerId: peerID.uuidString.lowercased(), candidate: candidate))
                } else {
                    guard localICE.count < 128 else { throw RealtimeError.invalidEvent }
                    localICE.append(candidate)
                }
            case .iceGatheringComplete:
                if let peerID, hasSentOffer { try await send("media.ice", data: ConferenceSignalICE(mediaPeerId: peerID, candidate: nil)) }
                else { gatheringComplete = true }
            case .negotiationNeeded:
                needsOffer = true
                // configure/permission actions coalesce into the initial offer.
                if hasSentOffer { try await negotiate(epoch) }
            case .connectionState(let state):
                if state == .connected {
                    rtcConnected = true; connectionDeadlineTask?.cancel()
                    if readyAcknowledged { markConnected(epoch) }
                } else if state == .failed || state == .closed { recover(RealtimeError.disconnected) }
                else if state == .disconnected {
                    rtcConnected = false; phase = .reconnecting
                    armConnectionDeadline(seconds: 8, epoch: epoch)
                }
            case .videoTrackAdded(let track):
                rawVideoTracks.removeAll { $0.id == track.id }; rawVideoTracks.append(track); syncVideos()
            case .videoTrackRemoved(let id): rawVideoTracks.removeAll { $0.id == id }; syncVideos()
            case .captureState(let mic, let cam, let front):
                microphone = mic; camera = cam; frontCamera = front
                publishPresence(epoch)
            case .audioRoute(let route): audioRoute = route
            case .networkPathChanged: recover(RealtimeError.disconnected)
            case .interrupted(let began):
                if began {
                    wantsMicrophone = false; wantsCamera = false; error = "Медиа остановлено из-за аудиопрерывания."
                    await media?.suspend(); try ensure(epoch)
                }
            case .failure(let failure):
                error = mediaMessage(failure)
                if failure == .negotiation { recover(failure) }
            }
        } catch { if isCurrent(epoch) { recover(error) } }
    }

    private func markConnected(_ epoch: UUID) {
        guard isCurrent(epoch), rtcConnected, readyAcknowledged else { return }
        phase = .connected
        if connectedAt == nil { connectedAt = Date() }
        publishPresence(epoch)
    }

    private func applyPolicy(_ policy: ConferenceSignalPolicy) async throws {
        guard policy.version > policyVersion else { return }
        policyVersion = policy.version
        if policy.kicked { await leave(); return }
        microphoneBlocked = policy.microphoneBlocked; cameraBlocked = policy.cameraBlocked
        if microphoneBlocked { wantsMicrophone = false }
        if cameraBlocked { wantsCamera = false }
        let epoch = generation
        try await media?.setPublicationPermissions(microphone: !microphoneBlocked, camera: !cameraBlocked)
        try ensure(epoch)
    }
    private func applyParticipantPolicy(_ participant: ConferenceParticipant) async {
        guard participant.mediaPolicyVersion > policyVersion else { return }
        policyVersion = participant.mediaPolicyVersion
        microphoneBlocked = participant.microphoneBlocked; cameraBlocked = participant.cameraBlocked
        if microphoneBlocked { wantsMicrophone = false }
        if cameraBlocked { wantsCamera = false }
        let epoch = generation
        do { try await media?.setPublicationPermissions(microphone: !microphoneBlocked, camera: !cameraBlocked) }
        catch { if isCurrent(epoch) { recover(error) } }
    }

    private func publishPresence(_ epoch: UUID) {
        guard let connectionID, sequence < 9_007_199_254_740_991 else { return }
        sequence += 1
        pendingPresence = ConferenceMediaState(connectionID: connectionID, sequence: sequence,
                                        microphoneEnabled: microphone, cameraEnabled: camera)
        guard presenceTask == nil else { return }
        presenceTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == epoch { presenceTask = nil } }
            while isCurrent(epoch), let state = pendingPresence {
                pendingPresence = nil
                do { _ = try await repository.updateMedia(conferenceID, state: state) }
                catch { if isCurrent(epoch), !Self.isRetryable(error) { recover(error); return } }
            }
        }
    }

    public func toggleMicrophone() async {
        guard !busy, foreground, !microphoneBlocked, phase == .connected, let media else { return }
        busy = true; let epoch = generation; defer { if isCurrent(epoch) { busy = false } }
        do { try await media.setMicrophoneEnabled(!microphone) }
        catch { if isCurrent(epoch) { self.error = mediaMessage(error) } }
    }
    public func toggleCamera() async {
        guard !busy, foreground, !cameraBlocked, phase == .connected, let media else { return }
        busy = true; let epoch = generation; defer { if isCurrent(epoch) { busy = false } }
        do { try await media.setCameraEnabled(!camera) }
        catch { if isCurrent(epoch) { self.error = mediaMessage(error) } }
    }
    public func switchCamera() async {
        guard !busy, foreground, camera, phase == .connected, let media else { return }
        busy = true; let epoch = generation; defer { if isCurrent(epoch) { busy = false } }
        do { try await media.switchCamera() } catch { if isCurrent(epoch) { self.error = mediaMessage(error) } }
    }
    public func toggleSpeaker() {
        guard foreground, phase == .connected else { return }
        do { try media?.setSpeakerEnabled(!speaker); speaker.toggle() } catch { self.error = mediaMessage(error) }
    }
    public func react(_ emoji: String) async {
        guard !closed, foreground, phase == .connected else { return }
        let epoch = generation
        do { try await repository.reaction(conferenceID, emoji: emoji) } catch { if isCurrent(epoch) { self.error = userMessage(error) } }
    }
    public func refreshParticipants() async {
        let epoch = generation
        do {
            let list = try await repository.participants(conferenceID)
            guard isCurrent(epoch) else { return }; participants = list
            if let own = list.first(where: { $0.id == participant.id }) {
                participant = own
                if !own.canParticipate { await leave(); return }
                await applyParticipantPolicy(own)
            }
        } catch { if isCurrent(epoch) { self.error = userMessage(error) } }
    }
    public func admit(_ target: ConferenceParticipant, decision: String) async {
        guard !closed, !busy, participant.canAdmit, target.conferenceId == conferenceID else { return }
        busy = true; let epoch = generation; defer { if isCurrent(epoch) { busy = false } }
        do { _ = try await repository.admission(conferenceID, participant: target.id, decision: decision); try ensure(epoch); await refreshParticipants() }
        catch { if isCurrent(epoch) { self.error = userMessage(error) } }
    }
    public func moderate(_ target: ConferenceParticipant, action: String, blocked: Bool? = nil, role: String? = nil) async {
        guard !closed, !busy, participant.canModerate(target, action: action) else { return }
        busy = true; let epoch = generation; defer { if isCurrent(epoch) { busy = false } }
        do {
            let request = try ConferenceModeration(action: action, blocked: blocked, role: role)
            _ = try await repository.moderate(conferenceID, participant: target.id, request: request)
            try ensure(epoch)
            await refreshParticipants()
        } catch { if isCurrent(epoch) { self.error = userMessage(error) } }
    }
    public func refreshChat() async {
        guard !closed else { return }
        if messageLoading { messageRefreshPending = true; return }
        messageLoading = true; let epoch = messageEpoch
        defer { if messageEpoch == epoch { messageLoading = false } }
        repeat {
        messageRefreshPending = false
        do {
            let page = try await repository.messages(conferenceID)
            guard !closed, messageEpoch == epoch else { return }
            for item in page.items {
                if let index = messages.firstIndex(where: { $0.id == item.id }) {
                    if messages[index].version <= item.version { messages[index] = item }
                } else { messages.append(item) }
            }
            messages.sort { $0.sequence < $1.sequence }
            if chatVisible, foreground, let last = messages.last { _ = try? await repository.markRead(conferenceID, through: last.id) }
        } catch { if !closed, messageEpoch == epoch { self.error = userMessage(error) } }
        } while messageRefreshPending && !closed && messageEpoch == epoch && !Task.isCancelled
    }
    public func sendMessage() async {
        guard !busy, !closed else { return }
        busy = true; let epoch = generation; defer { if isCurrent(epoch) { busy = false } }
        do {
            if pendingMessage == nil { pendingMessage = try MessageDraft(text: chatText) }
            guard let draft = pendingMessage else { return }
            _ = try await repository.send(conferenceID, draft: draft)
            guard !closed else { return }
            pendingMessage = nil; chatText = ""; await refreshChat()
        } catch { if !closed { self.error = userMessage(error) } }
    }

    public func setForeground(_ active: Bool) async {
        guard foreground != active else { return }
        foreground = active
        guard !closed else { return }
        if !active {
            lobbyTask?.cancel(); lobbyTask = nil
            if [.connecting, .connected, .reconnecting].contains(phase) {
                wantsMicrophone = false; wantsCamera = false; phase = .suspended
                recoveryTask?.cancel(); recoveryTask = nil
                await detachAttempt().value
            }
        } else if active, phase == .suspended { start() }
        else if active, phase == .waiting { observeLobby() }
    }

    private static func isRetryable(_ failure: any Error) -> Bool {
        switch failure {
        case is CancellationError, ClientError.sessionExpired, ClientError.accountMismatch, ClientError.scopeMismatch: false
        case APIError.httpStatus(let status): ![400, 401, 403, 404, 422].contains(status)
        case APIError.tls: false
        case ConferenceSignalError.disconnected(let retryable): retryable
        case ConferenceSignalError.invalidEnvelope, ConferenceSignalError.invalidPayload,
             ConferenceSignalError.invalidTicket, ConferenceSignalError.unsupportedProtocol: false
        case ConferenceMediaError.invalidConfiguration, ConferenceMediaError.unavailable: false
        default: true
        }
    }
    private func recover(_ failure: any Error) {
        guard !closed, foreground, recoveryTask == nil, !(failure is CancellationError) else { return }
        if let connectedAt, Date().timeIntervalSince(connectedAt) > 30 { reconnectCount = 0 }
        wantsMicrophone = false; wantsCamera = false
        let retryable = Self.isRetryable(failure)
        phase = retryable ? .reconnecting : .failed
        error = retryable ? "Соединение прервано. Камера и микрофон выключены." : userMessage(failure)
        let cleanup = detachAttempt(), epoch = generation
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            await cleanup.value
            guard isCurrent(epoch), foreground else { return }
            if !retryable { recoveryTask = nil; return }
            reconnectCount += 1
            guard reconnectCount <= 3 else { phase = .failed; recoveryTask = nil; return }
            do { try await sleep(Double(reconnectCount * 2)) } catch { return }
            guard isCurrent(epoch), foreground else { return }
            recoveryTask = nil
            launchAttempt()
        }
    }

    private func armDeadline(seconds: Double, epoch: UUID) {
        deadlineTask?.cancel()
        deadlineTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.sleep(seconds) } catch { return }
            guard self.isCurrent(epoch), !Task.isCancelled else { return }
            self.recover(APIError.timeout)
        }
    }
    private func armConnectionDeadline(seconds: Double, epoch: UUID) {
        connectionDeadlineTask?.cancel()
        connectionDeadlineTask = Task { [weak self] in
            guard let self else { return }
            do { try await sleep(seconds) } catch { return }
            if isCurrent(epoch), !rtcConnected { recover(APIError.timeout) }
        }
    }
    private func send<T: Encodable>(_ type: String, data: T, request: UUID = UUID()) async throws {
        let epoch = generation; try ensure(epoch)
        guard let socket else { throw RealtimeError.disconnected }
        try await socket.send(ConferenceEnvelope.command(type: type, conferenceID: conferenceID, data: data, id: request))
        try ensure(epoch)
    }
    private func isCurrent(_ epoch: UUID) -> Bool { !closed && epoch == generation && !Task.isCancelled }
    private func ensure(_ epoch: UUID) throws { if !isCurrent(epoch) { throw CancellationError() } }

    /// Reset state before awaiting resource disposal so an old cleanup cannot erase a newer attempt.
    private func detachAttempt() -> Task<Void, Never> {
        generation = UUID()
        attemptTask?.cancel(); receiveTask?.cancel(); eventTask?.cancel(); deviceTask?.cancel()
        initialDevicesTask?.cancel(); deadlineTask?.cancel(); connectionDeadlineTask?.cancel(); expiryTask?.cancel(); presenceTask?.cancel()
        attemptTask = nil; receiveTask = nil; eventTask = nil; deviceTask = nil; initialDevicesTask = nil
        deadlineTask = nil; connectionDeadlineTask = nil; expiryTask = nil; presenceTask = nil; pendingPresence = nil
        let previousMedia = media, previousSocket = socket, previousCleanup = cleanupTask
        media = nil; socket = nil
        microphone = false; camera = false; busy = false
        tracks = []; videoTracks = []; localICE = []; remoteICE = []; seenRemoteICE = []
        rawVideoTracks = []; answerTracks = [:]; videoParticipants = [:]; screenVideoIDs = []
        connectionID = nil; peerID = nil; joinRequest = nil; negotiationID = nil
        readyRequest = nil; offerRequest = nil; offerBusy = false; needsOffer = false
        answerApplied = false; sequence = 0; policyVersion = -1; revision = -1; connectedAt = nil
        hasSentOffer = false; readyAcknowledged = false; rtcConnected = false; gatheringComplete = false; iceConfiguration = nil
        let task = Task {
            await previousCleanup?.value
            await previousMedia?.close()
            await previousSocket?.close()
        }
        cleanupTask = task
        return task
    }
    private struct AnswerTrack { let trackID: UUID; let streamID: String }
    private static func answerBindings(_ sdp: String) throws -> [String: AnswerTrack] {
        guard sdp.utf8.count <= 131_072 else { throw RealtimeError.invalidEvent }
        let lines = sdp.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard lines.count <= 4096 else { throw RealtimeError.invalidEvent }
        var result: [String: AnswerTrack] = [:], seenMIDs: Set<String> = []
        var section: [String] = []
        func parse(_ lines: [String]) throws {
            guard let first = lines.first, first.hasPrefix("m=video ") else { return }
            let parts = first.split(separator: " ")
            guard parts.count >= 3, parts[1] != "0", !lines.contains("a=recvonly"), !lines.contains("a=inactive") else { return }
            let mids = lines.filter { $0.hasPrefix("a=mid:") }.map { String($0.dropFirst(6)) }
            guard mids.count == 1, !mids[0].isEmpty, mids[0].utf8.count <= 16, seenMIDs.insert(mids[0]).inserted else { throw RealtimeError.invalidEvent }
            var associations = lines.filter { $0.hasPrefix("a=msid:") }.map { String($0.dropFirst(7)) }
            if associations.isEmpty {
                associations = lines.compactMap { line in
                    guard line.hasPrefix("a=ssrc:"), let range = line.range(of: " msid:") else { return nil }
                    return String(line[range.upperBound...])
                }
            }
            let unique = Set(associations)
            guard unique.count <= 1 else { throw RealtimeError.invalidEvent }
            guard let value = unique.first else { return }
            let association = value.split(separator: " ")
            guard association.count == 2, let track = UUID(uuidString: String(association[1])) else { return }
            result[mids[0]] = AnswerTrack(trackID: track, streamID: String(association[0]))
        }
        for line in lines {
            if line.hasPrefix("m=") { try parse(section); section = [line] } else { section.append(line) }
        }
        try parse(section)
        return result
    }
    private func syncVideos() {
        videoParticipants = [:]; screenVideoIDs = []
        videoTracks = rawVideoTracks.filter { video in
            if video.isLocal { return true }
            guard let mid = video.mid, let binding = answerTracks[mid],
                  let track = tracks.first(where: { $0.id == binding.trackID && $0.streamId == binding.streamID && $0.kind == "video" }) else { return false }
            videoParticipants[video.id] = track.participantId
            if track.source == "video/screen" { screenVideoIDs.insert(video.id) }
            return true
        }
    }

    public func leave() async {
        guard !closed else { return }
        closed = true; phase = .ended; recoveryTask?.cancel(); recoveryTask = nil; lobbyTask?.cancel(); lobbyTask = nil
        messageEpoch = UUID(); pendingMessage = nil; chatText = ""; messages = []
        participants = []; messageLoading = false; messageRefreshPending = false
        await detachAttempt().value
        // Capture closes immediately; the workspace keeps this session until awaitDeparture resolves.
        leaveTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await repository.leave(conferenceID)
                completeDeparture(!departureUncertain && !Task.isCancelled)
            } catch { completeDeparture(false) }
            leaveDeadlineTask?.cancel(); leaveDeadlineTask = nil; leaveTask = nil
        }
        let operation = leaveTask
        leaveDeadlineTask = Task { [weak self] in
            guard let self else { return }
            do { try await sleep(10) } catch { return }
            guard departureResult == nil else { return }
            departureUncertain = true; operation?.cancel()
            // URLSession cancellation normally completes promptly. A transport ignoring cancellation
            // must never allow a new join while its old leave could still reach the server.
            do { try await sleep(2) } catch { return }
            completeDeparture(false)
        }
    }

    /// False blocks reuse of the workspace: an unacknowledged leave may still affect a later join.
    public func awaitDeparture() async -> Bool {
        await leave()
        if let departureResult { return departureResult }
        return await withCheckedContinuation { departureWaiters.append($0) }
    }
    private func completeDeparture(_ confirmed: Bool) {
        guard departureResult == nil else { return }
        departureResult = confirmed; departureUncertain = !confirmed
        if !confirmed { error = "Медиа закрыто. Сервер не подтвердил выход из встречи." }
        let waiters = departureWaiters; departureWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: confirmed) }
    }
}

public func mediaMessage(_ error: any Error) -> String {
    switch error {
    case ConferenceMediaError.microphonePermissionDenied: "Разрешите доступ к микрофону в настройках устройства."
    case ConferenceMediaError.cameraPermissionDenied: "Разрешите доступ к камере в настройках устройства."
    case ConferenceMediaError.cameraUnavailable: "Камера недоступна на этом устройстве."
    case ConferenceMediaError.unavailable: "Медиа доступно в приложении для iPhone и iPad."
    case ConferenceMediaError.audioSession, ConferenceMediaError.interrupted: "Аудиоустройство временно недоступно."
    default: "Не удалось подключить медиа. Повторите вход во встречу."
    }
}
