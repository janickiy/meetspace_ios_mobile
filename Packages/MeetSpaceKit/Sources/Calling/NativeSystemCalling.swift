#if os(iOS)
import Foundation
import MeetSpaceMedia
@preconcurrency import CallKit
@preconcurrency import AVFoundation

@MainActor final class NativeSystemCalling: NSObject, SystemCalling {
    private let provider: CXProvider
    private let controller = CXCallController(queue: .main)
    private let hub = SystemCallEventHub()
    private var descriptors: [UUID: SystemCallDescriptor] = [:]
    private var outgoing: Set<UUID> = []
    private var pending: [UUID: (action: CXCallAction, value: SystemCallAction)] = [:]
    private var invalidated = false
    var isAvailable: Bool { !invalidated }
    var events: AsyncStream<SystemCallEvent> {
        hub.subscribe(replay: pending.values.sorted { $0.value.deadline < $1.value.deadline }.map { .action($0.value) }
            + [.audioActivationChanged(CallAudioSessionBridge.isActive)])
    }

    override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = true
        configuration.supportedHandleTypes = [.generic]
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        // Generic handles are call UUIDs, not a verified account-scoped redial destination.
        configuration.includesCallsInRecents = false
        provider = CXProvider(configuration: configuration)
        super.init()
        // An explicit queue also defines reportIncoming's completion queue (nil uses a private one).
        provider.setDelegate(self, queue: .main)
    }

    func reportIncoming(_ descriptor: SystemCallDescriptor,
                        completion: @escaping @Sendable (Result<Void, SystemCallingError>) -> Void) {
        guard !invalidated else { completion(.failure(.invalidated)); return }
        guard valid(descriptor) else { completion(.failure(.invalidDescriptor)); return }
        let existed = descriptors[descriptor.id] != nil
        descriptors[descriptor.id] = descriptor
        // This invocation must remain synchronous: no account restore, network call, or actor hop
        // may precede it on the PushKit path. Even duplicate pushes are reported to the system.
        provider.reportNewIncomingCall(with: descriptor.id, update: update(descriptor)) { @Sendable [weak self] error in
            let duplicate = (error as NSError?)?.domain == CXErrorDomainIncomingCall &&
                (error as NSError?)?.code == CXErrorCodeIncomingCallError.callUUIDAlreadyExists.rawValue
            let accepted = error == nil || (existed && duplicate)
            MainActor.assumeIsolated {
                if !accepted { self?.descriptors[descriptor.id] = nil }
            }
            completion(accepted ? .success(()) : .failure(.incomingRejected))
        }
    }

    func requestStart(_ descriptor: SystemCallDescriptor) async throws {
        guard !invalidated else { throw SystemCallingError.invalidated }
        guard valid(descriptor), descriptors[descriptor.id] == nil else { throw SystemCallingError.invalidDescriptor }
        descriptors[descriptor.id] = descriptor; outgoing.insert(descriptor.id)
        let action = CXStartCallAction(call: descriptor.id, handle: CXHandle(type: .generic, value: descriptor.id.uuidString))
        action.isVideo = descriptor.isVideo
        do {
            try await request(action)
            if !invalidated { provider.reportCall(with: descriptor.id, updated: update(descriptor)) }
        } catch {
            descriptors[descriptor.id] = nil; outgoing.remove(descriptor.id)
            throw error
        }
    }
    func requestAnswer(callID: UUID) async throws { try await request(CXAnswerCallAction(call: callID)) }
    func requestEnd(callID: UUID) async throws { try await request(CXEndCallAction(call: callID)) }
    func requestMuted(_ muted: Bool, callID: UUID) async throws { try await request(CXSetMutedCallAction(call: callID, muted: muted)) }

    private func request(_ action: CXCallAction) async throws {
        guard !invalidated else { throw SystemCallingError.invalidated }
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            controller.request(CXTransaction(action: action)) { @Sendable error in
                if error == nil { continuation.resume() }
                else { continuation.resume(throwing: SystemCallingError.requestRejected) }
            }
        }
    }

    func completeAction(id: UUID, succeeded: Bool) {
        guard let value = pending.removeValue(forKey: id), !value.action.isComplete else { return }
        guard value.value.deadline > Date() else {
            // System timeouts are already failures; never fulfill or fail an expired CXAction.
            hub.yield(.timedOut(value.value)); return
        }
        if succeeded && (value.value.kind == .start || value.value.kind == .answer) {
            do { try CallAudioSessionBridge.prepareForCall() }
            catch {
                value.action.fail()
                reportEnded(callID: value.value.callID, reason: .failed, at: nil)
                hub.yield(.reset) // Coordinator must also end the corresponding server attempt.
                return
            }
        }
        if succeeded { value.action.fulfill() } else { value.action.fail() }
        if value.value.kind == .end && succeeded {
            descriptors[value.value.callID] = nil; outgoing.remove(value.value.callID)
        }
    }
    func reportConnecting(callID: UUID, at date: Date?) {
        guard !invalidated, outgoing.contains(callID) else { return }
        provider.reportOutgoingCall(with: callID, startedConnectingAt: date)
    }
    func reportConnected(callID: UUID, at date: Date?) {
        guard !invalidated, outgoing.contains(callID) else { return }
        provider.reportOutgoingCall(with: callID, connectedAt: date)
    }
    func reportEnded(callID: UUID, reason: SystemCallEndReason, at date: Date?) {
        guard !invalidated else { return }
        let native: CXCallEndedReason
        switch reason {
        case .failed: native = .failed
        case .remoteEnded: native = .remoteEnded
        case .unanswered: native = .unanswered
        case .answeredElsewhere: native = .answeredElsewhere
        case .declinedElsewhere: native = .declinedElsewhere
        }
        provider.reportCall(with: callID, endedAt: date, reason: native)
        descriptors[callID] = nil; outgoing.remove(callID)
        for id in pending.filter({ $0.value.value.callID == callID }).map(\.key) { completeAction(id: id, succeeded: false) }
    }
    func updateCall(_ descriptor: SystemCallDescriptor) {
        guard !invalidated, descriptors[descriptor.id] != nil, valid(descriptor) else { return }
        descriptors[descriptor.id] = descriptor
        provider.reportCall(with: descriptor.id, updated: update(descriptor))
    }
    func invalidate() {
        guard !invalidated else { return }; invalidated = true
        for value in pending.values where !value.action.isComplete && value.value.deadline > Date() { value.action.fail() }
        pending.removeAll(); descriptors.removeAll(); outgoing.removeAll()
        CallAudioSessionBridge.reset()
        provider.invalidate(); hub.finish()
    }

    private func valid(_ descriptor: SystemCallDescriptor) -> Bool {
        !descriptor.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            descriptor.displayName.utf8.count <= 1024 &&
            !descriptor.displayName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    private func update(_ descriptor: SystemCallDescriptor) -> CXCallUpdate {
        let value = CXCallUpdate()
        value.remoteHandle = CXHandle(type: .generic, value: descriptor.id.uuidString)
        value.localizedCallerName = descriptor.displayName; value.hasVideo = descriptor.isVideo
        value.supportsDTMF = false; value.supportsHolding = false
        value.supportsGrouping = false; value.supportsUngrouping = false
        return value
    }
    private func receive(_ action: CXCallAction, kind: SystemCallAction.Kind) {
        guard !invalidated, descriptors[action.callUUID] != nil else { action.fail(); return }
        let value = SystemCallAction(id: action.uuid, callID: action.callUUID, kind: kind, deadline: action.timeoutDate)
        pending[action.uuid] = (action, value); hub.yield(.action(value))
    }
}

extension NativeSystemCalling: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        MainActor.assumeIsolated {
            pending.removeAll(); descriptors.removeAll(); outgoing.removeAll()
            CallAudioSessionBridge.reset(); hub.yield(.audioActivationChanged(false)); hub.yield(.reset)
        }
    }
    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        MainActor.assumeIsolated { receive(action, kind: .start) }
    }
    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        MainActor.assumeIsolated { receive(action, kind: .answer) }
    }
    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        MainActor.assumeIsolated { receive(action, kind: .end) }
    }
    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        MainActor.assumeIsolated { receive(action, kind: .setMuted(action.isMuted)) }
    }
    nonisolated func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) { action.fail() }
    nonisolated func provider(_ provider: CXProvider, perform action: CXSetGroupCallAction) { action.fail() }
    nonisolated func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) { action.fail() }
    nonisolated func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        MainActor.assumeIsolated {
            if let value = pending.removeValue(forKey: action.uuid) { hub.yield(.timedOut(value.value)) }
        }
    }
    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated {
            CallAudioSessionBridge.didActivate(audioSession); hub.yield(.audioActivationChanged(true))
        }
    }
    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated {
            CallAudioSessionBridge.didDeactivate(audioSession); hub.yield(.audioActivationChanged(false))
        }
    }
}
#endif
