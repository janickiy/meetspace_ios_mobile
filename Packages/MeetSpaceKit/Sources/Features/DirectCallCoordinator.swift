import Foundation
import Observation
import MeetSpaceCore
import MeetSpaceAPI
import MeetSpaceRealtime
import MeetSpaceMedia
import MeetSpaceCalling

/// Account-scoped durable call state. Socket notifications only invalidate REST state;
/// the transient clientID authorizes exactly one device's SFU endpoint.
@MainActor @Observable public final class DirectCallCoordinator {
    public let clientID: UUID
    public private(set) var currentCall: DirectCall?
    public private(set) var mediaSession: ConferenceSession?
    public private(set) var pendingPeer: DirectCallPeer?
    public private(set) var minimized = false
    public private(set) var busy = false
    public private(set) var uncertain = false
    public private(set) var ending = false
    public private(set) var elapsedSeconds = 0
    public private(set) var microphoneWanted = true
    public private(set) var cameraWanted = false
    public var error: String?
    public var isActive: Bool { currentCall?.isActive == true || pendingPeer != nil }
    public var isIncoming: Bool { currentCall?.status == .ringing && currentCall?.calleeUserId == repository.userID }
    public var ownsMedia: Bool { currentCall?.ownsMedia(userID: repository.userID, clientID: clientID) == true }
    public var otherDevice: Bool { currentCall?.isActive == true && !isIncoming && !ownsMedia }
    public var peer: DirectCallPeer? { currentCall?.peer(for: repository.userID) ?? pendingPeer }
    public var systemAvailable: Bool { system.isAvailable }

    @ObservationIgnored private let repository: any DirectCallsServing
    @ObservationIgnored private let conferenceRepository: ConferenceRepository
    @ObservationIgnored private let system: any SystemCalling
    @ObservationIgnored private let sockets: any ConferenceSocketFactory
    @ObservationIgnored private let makeMedia: @MainActor @Sendable () -> any ConferenceMediaEngine
    @ObservationIgnored private let canUseMedia: @MainActor () -> Bool
    @ObservationIgnored private let sleep: @Sendable (Double) async throws -> Void
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var applicationEpoch = UUID()
    @ObservationIgnored private var applicationTask: Task<Void, Never>?
    @ObservationIgnored private var applicationCallID: UUID?
    @ObservationIgnored private var applicationVersion: Int64 = -1
    @ObservationIgnored private var mediaCleanup: Task<Void, Never>?
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var foreground = true
    @ObservationIgnored private var systemAudioActive = false
    @ObservationIgnored private var createRequestID: UUID?
    @ObservationIgnored private var commandRevision = 0
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var heartbeatCallID: UUID?
    @ObservationIgnored private var lastHeartbeat: Date?
    @ObservationIgnored private var lastHeartbeatAttempt: Date?
    @ObservationIgnored private var lastRefresh = Date.distantPast
    @ObservationIgnored private var reported: Set<UUID> = []
    @ObservationIgnored private var reportedConnected: Set<UUID> = []
    @ObservationIgnored private var failedReports: Set<UUID> = []
    @ObservationIgnored private var pendingAnswer: SystemCallAction?
    @ObservationIgnored private var actionTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var actionDeadlines: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var actions: [UUID: SystemCallAction] = [:]
    @ObservationIgnored private var completedActions: Set<UUID> = []

    public init(repository: any DirectCallsServing, conferenceRepository: ConferenceRepository,
                system: any SystemCalling, sockets: any ConferenceSocketFactory = URLSessionConferenceSocketFactory(),
                makeMedia: @escaping @MainActor @Sendable () -> any ConferenceMediaEngine = { ConferenceMediaFactory.make() },
                canUseMedia: @escaping @MainActor () -> Bool = { true }, clientID: UUID = UUID(),
                sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.repository = repository; self.conferenceRepository = conferenceRepository; self.system = system
        self.sockets = sockets; self.makeMedia = makeMedia; self.canUseMedia = canUseMedia; self.clientID = clientID
        self.sleep = sleep; self.now = now
        let events = system.events
        eventsTask = Task { [weak self] in
            for await event in events {
                guard let self, !self.closed, !Task.isCancelled else { return }
                await self.receiveSystem(event)
            }
        }
        pollTask = Task { [weak self] in
            while let self, !self.closed, !Task.isCancelled {
                await self.tick()
                do { try await self.sleep(1) } catch { return }
            }
        }
    }

    public func startOutgoing(peer: DirectCallPeer, isVideo: Bool = false) async {
        guard !closed, !busy, peer.id != repository.userID else { return }
        if currentCall?.isActive == true {
            minimized = false
            if self.peer?.id != peer.id { error = "Сначала завершите текущий личный звонок." }
            return
        }
        guard canUseMedia() else { error = "Сначала выйдите из текущей встречи."; return }
        if let pendingPeer, pendingPeer.id != peer.id { error = "Сначала проверьте результат предыдущего вызова."; return }
        if createRequestID == nil { createRequestID = UUID(); microphoneWanted = true; cameraWanted = isVideo }
        guard let requestID = createRequestID else { return }
        pendingPeer = peer; minimized = false; busy = true; error = nil; ending = false
        commandRevision += 1
        let current = epoch
        defer { if valid(current) { busy = false } }
        do {
            let call = try await repository.create(targetUserID: peer.id, clientRequestID: requestID, clientID: clientID)
            guard valid(current) else { await compensate(call); return }
            guard call.callerUserId == repository.userID, call.calleeUserId == peer.id,
                  call.callerClientId == clientID.uuidString.lowercased() else { throw ClientError.scopeMismatch }
            await apply(call)
        } catch {
            guard valid(current) else { return }
            // REST reconciliation may already have recovered this request while POST was suspended.
            if createRequestID == nil, pendingPeer == nil { return }
            uncertain = Self.uncertainResult(error)
            if !uncertain { pendingPeer = nil; createRequestID = nil }
            self.error = uncertain ? "Результат вызова неизвестен. Повторите проверку — новый звонок не создаётся." : userMessage(error)
        }
    }

    public func answer() async {
        guard !closed, !busy, isIncoming, let call = currentCall else { return }
        guard canUseMedia() else { error = "Сначала выйдите из текущей встречи."; return }
        if system.isAvailable {
            guard reported.contains(call.id) else { error = "Не удалось открыть системный звонок. Завершите вызов и попробуйте снова."; return }
            do { try await system.requestAnswer(callID: call.id) }
            catch { self.error = "Не удалось принять системный звонок." }
        } else { await accept(call.id, action: nil) }
    }

    public func end() async {
        guard !closed else { return }
        if let pendingPeer, currentCall == nil || currentCall?.isTerminal == true {
            // A lost create response is resolved with its original key, never replaced by a new call.
            await startOutgoing(peer: pendingPeer, isVideo: cameraWanted)
        }
        guard let call = currentCall else { return }
        if call.isTerminal || otherDevice { minimized = true; return }
        // Local capture stops before the system transaction or any network operation.
        let current = epoch
        ending = true; await stopMedia()
        guard valid(current), currentCall?.id == call.id else { return }
        if system.isAvailable, reported.contains(call.id) {
            do { try await system.requestEnd(callID: call.id) }
            catch { await terminate(reportReason: .failed) }
        } else { await terminate(reportReason: .remoteEnded) }
    }

    public func setMuted(_ muted: Bool) async {
        guard !closed, !ending, ownsMedia, currentCall?.status == .accepted, let call = currentCall else { return }
        if system.isAvailable, reported.contains(call.id) {
            do { try await system.requestMuted(muted, callID: call.id) }
            catch { self.error = "Не удалось изменить микрофон системного звонка." }
        } else { await applyMute(muted, action: nil) }
    }
    public func toggleCamera() async {
        guard !closed, !busy, !ending, foreground, ownsMedia, currentCall?.status == .accepted, let session = mediaSession else { return }
        guard !system.isAvailable || systemAudioActive else { error = "Ожидаем активацию системного звонка."; return }
        let current = epoch, callID = currentCall?.id
        busy = true; defer { if valid(current) { busy = false } }
        do {
            let enabled = !session.camera
            try await session.setDirectCamera(enabled)
            guard valid(current), currentCall?.id == callID, !ending else { return }
            cameraWanted = enabled
            if let call = currentCall { system.updateCall(descriptor(call)) }
        } catch { self.error = mediaMessage(error) }
    }
    public func minimize() { minimized = true }
    public func resume() { minimized = false; Task { [weak self] in await self?.reconcile() } }

    /// Even a validated WS DTO is only a hint; media authorization always comes from REST.
    public func receive(_ call: DirectCall) async {
        guard !closed, call.peer(for: repository.userID) != nil else { return }
        await reconcile()
    }
    public func reconcile() async {
        guard !closed else { return }
        if let refreshTask { refreshAgain = true; await refreshTask.value; return }
        let current = epoch
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { if valid(current) { refreshTask = nil } }
            repeat {
                refreshAgain = false
                let revision = commandRevision, previous = currentCall
                do {
                    var latest = try await repository.active()
                    if latest == nil, let previous, previous.isActive { latest = try await repository.read(previous.id) }
                    guard valid(current) else { return }
                    if revision != commandRevision { refreshAgain = true; continue }
                    lastRefresh = now()
                    if let latest { await apply(latest) }
                } catch {
                    guard valid(current) else { return }
                    if isActive { self.error = userMessage(error) }
                }
            } while refreshAgain && valid(current)
        }
        await refreshTask?.value
    }

    public func setForeground(_ active: Bool) async {
        guard !closed else { return }
        foreground = active
        if !active { cameraWanted = false }
        await mediaSession?.setForeground(active)
        if active { await reconcile() }
    }

    private func apply(_ incoming: DirectCall) async {
        guard !closed, repository.origin == conferenceRepository.origin,
              repository.userID == conferenceRepository.userID else { return }
        do { _ = try incoming.validated(for: repository.userID) }
        catch { self.error = userMessage(error); return }
        // Polling, POST responses and heartbeat can deliver the same version concurrently.
        // They must await the same CallKit/media work instead of invalidating one another.
        if let applicationTask, applicationCallID == incoming.id, applicationVersion >= incoming.version {
            await applicationTask.value; return
        }
        if let currentCall, currentCall.id == incoming.id, currentCall.version > incoming.version { return }
        let current = epoch, application = UUID(); applicationEpoch = application
        applicationCallID = incoming.id; applicationVersion = incoming.version
        let task = Task { [weak self] in
            guard let self else { return }
            await self.applyState(incoming, current: current, application: application)
        }
        applicationTask = task
        await task.value
        if applicationEpoch == application { applicationTask = nil }
    }

    private func applyState(_ incoming: DirectCall, current: UUID, application: UUID) async {
        guard valid(current), applicationEpoch == application else { return }
        let previous = currentCall
        currentCall = incoming
        if previous?.id != incoming.id {
            let localIntent = createRequestID != nil && pendingPeer?.id == incoming.calleeUserId && incoming.callerClientId == clientID.uuidString.lowercased()
            failPendingAnswer(); await stopMedia()
            guard valid(current), applicationEpoch == application else { return }
            if let previous { reportEnd(previous, reason: .remoteEnded) }
            ending = false; minimized = false; microphoneWanted = true
            if !localIntent { cameraWanted = false }
            lastHeartbeat = nil; lastHeartbeatAttempt = nil
        }
        if pendingPeer?.id == incoming.calleeUserId, incoming.callerUserId == repository.userID,
           incoming.callerClientId == clientID.uuidString.lowercased() {
            pendingPeer = nil; createRequestID = nil; uncertain = false
        }
        if incoming.isTerminal {
            ending = false; uncertain = false
            failPendingAnswer(); await stopMedia()
            guard valid(current), applicationEpoch == application else { return }
            reportEnd(incoming, reason: incoming.status == .missed ? .unanswered : (incoming.status == .declined ? .declinedElsewhere : .remoteEnded))
            return
        }
        if incoming.callerUserId == repository.userID, ownsMedia, !ending,
           system.isAvailable, !reported.contains(incoming.id), !failedReports.contains(incoming.id) {
            // A create response can be lost while the peer accepts. The same owned REST call
            // must still enter CallKit before its SFU audio waits for system activation.
            reported.insert(incoming.id)
            do { try await system.requestStart(descriptor(incoming)) }
            catch {
                guard valid(current), currentCall?.id == incoming.id else { return }
                failedReports.insert(incoming.id)
                self.error = "Системный звонок не запущен. Вызов отменяется."
                await terminate(reportReason: .failed); return
            }
            guard valid(current), applicationEpoch == application else { return }
            if mediaSession?.phase == .connected { system.reportConnected(callID: incoming.id, at: now()) }
        }
        if incoming.status == .ringing {
            guard !ending else { return }
            if isIncoming, system.isAvailable, !reported.contains(incoming.id), !failedReports.contains(incoming.id) {
                reported.insert(incoming.id)
                let current = epoch
                do { try await system.reportIncoming(descriptor(incoming)) }
                catch {
                    guard valid(current) else { return }
                    failedReports.insert(incoming.id); reported.remove(incoming.id)
                    self.error = "Системный экран входящего звонка недоступен. Завершите вызов и попробуйте снова."
                }
            }
            return
        }
        if !ownsMedia {
            ending = false; uncertain = false
            failPendingAnswer(); await stopMedia()
            guard valid(current), applicationEpoch == application else { return }
            reportEnd(incoming, reason: .answeredElsewhere)
            return
        }
        guard !ending else { return }
        if lastHeartbeat == nil { lastHeartbeat = now(); lastHeartbeatAttempt = now() }
        guard mediaSession == nil else { return }
        await mediaCleanup?.value
        guard valid(current), applicationEpoch == application, !ending, mediaSession == nil else { return }
        guard canUseMedia() else { error = "Звонок принят, но медиа занято текущей встречей."; return }
        guard let room = incoming.conferenceId else { return }
        let service = repository, device = clientID, user = repository.userID, callID = incoming.id
        let context = DirectConferenceContext(callID: callID, clientID: device, usesSystemAudio: system.isAvailable) {
            let authoritative = try await service.read(callID)
            guard authoritative.status == .accepted, authoritative.conferenceId == room,
                  authoritative.ownsMedia(userID: user, clientID: device) else { throw ClientError.scopeMismatch }
        }
        // This placeholder is replaced by scoped REST membership before opening the socket.
        let member = ConferenceParticipant(id: UUID(), conferenceId: room, userId: user, displayName: "Вы")
        let session = ConferenceSession(repository: conferenceRepository, title: incoming.peer(for: user)?.displayName ?? "Личный звонок",
            participant: member, directContext: context, sockets: sockets, makeMedia: makeMedia, sleep: sleep)
        mediaSession = session
        session.wantsMicrophone = microphoneWanted
        session.wantsCamera = cameraWanted && (!system.isAvailable || systemAudioActive) && foreground
        session.onPhaseChanged = { [weak self, weak session] phase in
            Task { [weak self, weak session] in
                guard let self, let session, self.mediaSession === session, self.currentCall?.id == callID else { return }
                await self.mediaChanged(phase, callID: callID)
            }
        }
        await session.setForeground(foreground)
        guard valid(current), applicationEpoch == application, mediaSession === session else { return }
        system.reportConnecting(callID: callID)
        session.start()
    }

    private func accept(_ id: UUID, action: SystemCallAction?) async {
        guard !closed, !busy, isIncoming, currentCall?.id == id, canUseMedia() else {
            if let action { finish(action, succeeded: false) }; error = "Не удалось принять звонок: медиа занято или вызов уже завершён."; return
        }
        busy = true; ending = false; microphoneWanted = true; commandRevision += 1
        if let action { pendingAnswer = action }
        let current = epoch
        defer { if valid(current) { busy = false } }
        do {
            let call = try await repository.accept(id, clientID: clientID)
            guard valid(current), !Task.isCancelled, !ending else { await compensate(call); return }
            await apply(call)
            guard call.status == .accepted, call.ownsMedia(userID: repository.userID, clientID: clientID) else {
                if let action { finish(action, succeeded: false) }; pendingAnswer = nil; return
            }
        } catch {
            guard valid(current) else { return }
            self.error = userMessage(error); uncertain = Self.uncertainResult(error)
            if let action { finish(action, succeeded: false); pendingAnswer = nil }
            // A timed-out accept can have committed. Keep capture off until REST establishes ownership.
            if uncertain { ending = true; await stopMedia() }
            await reconcile()
        }
    }

    private func terminate(reportReason: SystemCallEndReason) async {
        guard !closed, let call = currentCall, call.isActive else { return }
        let current = epoch
        ending = true; commandRevision += 1
        await stopMedia()
        guard valid(current), currentCall?.id == call.id else { return }
        failPendingAnswer(); reportEnd(call, reason: reportReason)
        do {
            let result: DirectCall
            if call.status == .ringing, call.calleeUserId == repository.userID { result = try await repository.decline(call.id, clientID: clientID) }
            else if call.status == .ringing, call.ownsMedia(userID: repository.userID, clientID: clientID) { result = try await repository.cancel(call.id, clientID: clientID) }
            else if call.status == .accepted, call.ownsMedia(userID: repository.userID, clientID: clientID) { result = try await repository.end(call.id, clientID: clientID) }
            else { return }
            guard valid(current), currentCall?.id == call.id else { return }
            guard result.isTerminal else {
                uncertain = true; error = "Сервер пока не подтвердил завершение звонка."
                return
            }
            await apply(result)
        } catch {
            guard valid(current), currentCall?.id == call.id else { return }
            uncertain = true; self.error = "Звук и камера выключены. Завершение звонка на сервере пока не подтверждено."
        }
    }

    private func applyMute(_ muted: Bool, action: SystemCallAction?) async {
        guard !closed, !ending, ownsMedia, currentCall?.status == .accepted else {
            if let action { finish(action, succeeded: false) }; return
        }
        let current = epoch, callID = currentCall?.id
        do {
            try await mediaSession?.setDirectMicrophone(!muted)
            guard valid(current), currentCall?.id == callID, !ending else { if let action { finish(action, succeeded: false) }; return }
            microphoneWanted = !muted
            if let action { finish(action, succeeded: true) }
        } catch {
            self.error = mediaMessage(error)
            if let action { finish(action, succeeded: false) }
        }
    }

    private func receiveSystem(_ event: SystemCallEvent) async {
        switch event {
        case .action(let action):
            guard !completedActions.contains(action.id), actions[action.id] == nil else { return }
            guard currentCall?.id == action.callID, action.deadline > now() else { finish(action, succeeded: false); return }
            actions[action.id] = action
            let current = epoch
            actionDeadlines[action.id] = Task { [weak self] in
                guard let self else { return }
                do { try await sleep(max(0, action.deadline.timeIntervalSince(now()) - 0.25)) } catch { return }
                guard valid(current), !Task.isCancelled else { return }
                await actionTimedOut(action)
            }
            actionTasks[action.id] = Task { [weak self] in
                guard let self, valid(current) else { return }
                switch action.kind {
                case .start:
                    let allowed = currentCall?.isActive == true && ownsMedia && !ending
                    finish(action, succeeded: allowed)
                    if allowed {
                        system.reportConnecting(callID: action.callID)
                        if mediaSession?.phase == .connected { system.reportConnected(callID: action.callID, at: now()) }
                    }
                case .answer: await accept(action.callID, action: action)
                case .end:
                    ending = true; await stopMedia()
                    finish(action, succeeded: true)
                    await terminate(reportReason: .remoteEnded)
                case .setMuted(let muted): await applyMute(muted, action: action)
                }
            }
        case .timedOut(let action): await actionTimedOut(action)
        case .reset:
            await terminate(reportReason: .failed)
        case .audioActivationChanged(let active):
            let wasActive = systemAudioActive
            systemAudioActive = active
            if !active, wasActive {
                cameraWanted = false; try? await mediaSession?.setDirectCamera(false)
            } else if active, cameraWanted, foreground, ownsMedia, !ending {
                do { try await mediaSession?.setDirectCamera(true) } catch { self.error = mediaMessage(error) }
            }
        }
    }
    private func actionTimedOut(_ action: SystemCallAction) async {
        guard currentCall?.id == action.callID, actions[action.id] != nil else { return }
        actionTasks[action.id]?.cancel(); finish(action, succeeded: false)
        if pendingAnswer?.id == action.id { pendingAnswer = nil }
        switch action.kind {
        case .answer, .start:
            error = "Системный звонок не подключился вовремя."
            ending = true; await stopMedia()
            Task { [weak self] in await self?.terminate(reportReason: .failed) }
        case .end:
            ending = true; await stopMedia()
            Task { [weak self] in await self?.terminate(reportReason: .failed) }
        case .setMuted: break
        }
    }
    private func finish(_ action: SystemCallAction, succeeded: Bool) {
        guard completedActions.insert(action.id).inserted else { return }
        actions.removeValue(forKey: action.id)
        actionDeadlines.removeValue(forKey: action.id)?.cancel()
        actionTasks.removeValue(forKey: action.id)
        system.completeAction(id: action.id, succeeded: succeeded)
    }
    private func failPendingAnswer() {
        if let action = pendingAnswer { finish(action, succeeded: false); pendingAnswer = nil }
    }
    private func mediaChanged(_ phase: ConferencePhase, callID: UUID) async {
        guard !closed, !ending, currentCall?.id == callID else { return }
        if phase == .connected {
            if let action = pendingAnswer { finish(action, succeeded: true); pendingAnswer = nil }
            if reportedConnected.insert(callID).inserted { system.reportConnected(callID: callID, at: now()) }
        } else if phase == .failed || phase == .ended {
            error = mediaSession?.error ?? "Медиа звонка недоступно."
            await terminate(reportReason: .failed)
        }
    }

    func tick() async {
        guard !closed else { return }
        if let call = currentCall, let accepted = call.acceptedAt {
            elapsedSeconds = call.isTerminal ? Int(clamping: call.durationSec) : max(0, Int(now().timeIntervalSince(accepted)))
        } else { elapsedSeconds = 0 }
        if currentCall?.status == .accepted, ownsMedia, !ending {
            if let lastHeartbeat, now().timeIntervalSince(lastHeartbeat) >= 35 {
                ending = true; error = "Связь с сервером потеряна. Звук и камера выключены."
                await stopMedia()
                if let call = currentCall { reportEnd(call, reason: .failed) }
            } else if heartbeatTask == nil, now().timeIntervalSince(lastHeartbeatAttempt ?? .distantPast) >= 10,
                      let id = currentCall?.id {
                lastHeartbeatAttempt = now(); heartbeatCallID = id
                let current = epoch
                heartbeatTask = Task { [weak self] in
                    guard let self else { return }
                    defer { if valid(current), heartbeatCallID == id { heartbeatTask = nil; heartbeatCallID = nil } }
                    do {
                        let call = try await repository.heartbeat(id, clientID: clientID)
                        guard valid(current), currentCall?.id == id, !ending, !Task.isCancelled else { return }
                        lastHeartbeat = now(); await apply(call)
                    } catch {
                        guard valid(current), currentCall?.id == id else { return }
                        self.error = userMessage(error)
                    }
                }
            }
        }
        if (foreground || isActive), now().timeIntervalSince(lastRefresh) >= (isActive ? 3 : 10), refreshTask == nil {
            Task { [weak self] in await self?.reconcile() }
        }
    }
    private func stopMedia() async {
        heartbeatTask?.cancel(); heartbeatTask = nil; heartbeatCallID = nil
        let previous = mediaSession; mediaSession = nil; previous?.onPhaseChanged = nil
        let cleanup = mediaCleanup
        let operation = Task { await cleanup?.value; await previous?.leave() }
        mediaCleanup = operation
        await operation.value
    }
    private func descriptor(_ call: DirectCall) -> SystemCallDescriptor {
        SystemCallDescriptor(id: call.id, displayName: call.peer(for: repository.userID)?.displayName ?? "Личный звонок", isVideo: cameraWanted)
    }
    private func reportEnd(_ call: DirectCall, reason: SystemCallEndReason) {
        if reported.remove(call.id) != nil { system.reportEnded(callID: call.id, reason: reason, at: now()) }
    }
    private func valid(_ current: UUID) -> Bool { !closed && epoch == current }
    private static func uncertainResult(_ error: any Error) -> Bool {
        switch error {
        case APIError.offline, APIError.timeout, APIError.invalidResponse, is CancellationError: true
        case APIError.httpStatus(let status): status >= 500
        default: false
        }
    }
    private func compensate(_ call: DirectCall) async {
        guard call.isActive, call.ownsMedia(userID: repository.userID, clientID: clientID) else { return }
        if call.status == .ringing { _ = try? await repository.cancel(call.id, clientID: clientID) }
        else { _ = try? await repository.end(call.id, clientID: clientID) }
    }

    public func close() async {
        guard !closed else { return }
        closed = true; epoch = UUID(); ending = true
        eventsTask?.cancel(); pollTask?.cancel(); refreshTask?.cancel()
        eventsTask = nil; pollTask = nil; refreshTask = nil
        for task in actionTasks.values { task.cancel() }; actionTasks.removeAll()
        for task in actionDeadlines.values { task.cancel() }; actionDeadlines.removeAll()
        for action in Array(actions.values) { finish(action, succeeded: false) }
        failPendingAnswer()
        await stopMedia()
        if let call = currentCall { reportEnd(call, reason: .remoteEnded) }
        // Credential teardown follows close(). A request already in flight is scoped to this
        // old call ID; a cancelled create/accept compensates once its server outcome arrives.
        if let call = currentCall, call.isActive, call.ownsMedia(userID: repository.userID, clientID: clientID) {
            let operation = Task { [weak self] in await self?.compensate(call) }
            await withCheckedContinuation { continuation in
                let completion = CallCloseCompletion(continuation)
                Task { await operation.value; completion.finish() }
                Task { [sleep] in
                    try? await sleep(2)
                    operation.cancel(); completion.finish()
                }
            }
        }
    }
}

@MainActor private final class CallCloseCompletion {
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
    func finish() { continuation?.resume(); continuation = nil }
}
