import Foundation
import Testing
@testable import MeetSpaceCalling
import MeetSpaceMedia

private final class CompletionCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@MainActor private final class PushCallingFixture: SystemCalling {
    var events: AsyncStream<SystemCallEvent> { AsyncStream { $0.finish() } }
    let isAvailable = true
    var reported: [SystemCallDescriptor] = []
    var completion: (@Sendable (Result<Void, SystemCallingError>) -> Void)?
    func reportIncoming(_ descriptor: SystemCallDescriptor, completion: @escaping @Sendable (Result<Void, SystemCallingError>) -> Void) {
        reported.append(descriptor); self.completion = completion
    }
    func requestStart(_ descriptor: SystemCallDescriptor) async throws { }
    func requestAnswer(callID: UUID) async throws { }
    func requestEnd(callID: UUID) async throws { }
    func requestMuted(_ muted: Bool, callID: UUID) async throws { }
    func completeAction(id: UUID, succeeded: Bool) { }
    func reportConnecting(callID: UUID, at date: Date?) { }
    func reportConnected(callID: UUID, at date: Date?) { }
    func reportEnded(callID: UUID, reason: SystemCallEndReason, at date: Date?) { }
    func updateCall(_ descriptor: SystemCallDescriptor) { }
    func invalidate() { }
}

@MainActor private final class VerifiedPushFixture: ValidatedVoIPPushDeployment {
    let contractIdentifier = "test-only-injected-contract"
    let descriptor = SystemCallDescriptor(id: UUID(), displayName: "Fixture caller", isVideo: false)
    var resolutions = 0
    var registrations = 0
    func resolveIncomingCall(_ payload: [AnyHashable: Any]) -> SystemCallDescriptor {
        resolutions += 1; return descriptor
    }
    func registerVoIPToken(_ token: Data) async throws { registrations += 1 }
    func invalidateVoIPToken() async { }
}

@Suite("Native calling boundaries") struct NativeCallingBoundaryTests {
    @Test @MainActor func pushReportsSynchronouslyAndCompletesOnlyAfterCallKitResult() {
        let calling = PushCallingFixture(), deployment = VerifiedPushFixture(), count = CompletionCount()
        VoIPPushDelivery.report([:], deployment: deployment, calling: calling, completion: PushCompletion { count.increment() })
        #expect(calling.reported == [deployment.descriptor])
        #expect(deployment.resolutions == 1)
        #expect(deployment.registrations == 0)
        #expect(count.value == 0)
        calling.completion?(.success(()))
        calling.completion?(.failure(.incomingRejected))
        #expect(count.value == 1)
    }

    @Test @MainActor func rejectedIncomingCallStillCompletesPushExactlyOnce() {
        let calling = PushCallingFixture(), deployment = VerifiedPushFixture(), count = CompletionCount()
        VoIPPushDelivery.report([:], deployment: deployment, calling: calling, completion: PushCompletion { count.increment() })
        calling.completion?(.failure(.incomingRejected))
        calling.completion?(.failure(.incomingRejected))
        #expect(count.value == 1)
    }

    @Test func pushCompletionIsSafeAcrossConcurrentCallbacks() {
        let count = CompletionCount()
        let callback = PushCompletion { count.increment() }
        DispatchQueue.concurrentPerform(iterations: 32) { _ in callback.finish() }
        #expect(count.value == 1)
    }

    @Test @MainActor func cancellingAccountConsumerPreservesOtherAndFutureSubscriptions() async {
        let hub = SystemCallEventHub()
        let oldAccount = hub.subscribe(), continuingAccount = hub.subscribe()
        let consumer = Task { for await _ in oldAccount { } }
        consumer.cancel(); await consumer.value
        let newAccount = hub.subscribe(replay: [.audioActivationChanged(false)])
        var continuing = continuingAccount.makeAsyncIterator(), new = newAccount.makeAsyncIterator()
        #expect(await new.next() == .audioActivationChanged(false))
        hub.yield(.reset)
        #expect(await continuing.next() == .reset)
        #expect(await new.next() == .reset)
        hub.finish()
        #expect(await continuing.next() == nil)
        #expect(await new.next() == nil)
    }

    @Test @MainActor func actionsCanReplayToRestoredAccountWithoutCompletingProviderStream() async {
        let hub = SystemCallEventHub()
        let action = SystemCallAction(id: UUID(), callID: UUID(), kind: .answer, deadline: Date().addingTimeInterval(30))
        var restored = hub.subscribe(replay: [.action(action)]).makeAsyncIterator()
        #expect(await restored.next() == .action(action))
        hub.yield(.timedOut(action))
        #expect(await restored.next() == .timedOut(action))
        hub.finish()
    }

    @Test func conferenceAudioRemainsApplicationManagedByDefault() {
        let conference = ConferenceMediaConfiguration(iceServers: [], mediaPeerID: UUID())
        let directCall = ConferenceMediaConfiguration(iceServers: [], mediaPeerID: UUID(), audioActivation: .callKit)
        #expect(conference.audioActivation == .application)
        #expect(directCall.audioActivation == .callKit)
    }

    #if !os(iOS)
    @Test @MainActor func hostFactoriesCannotPretendToRegisterVoIPOrPlaceSystemCalls() async {
        let calling = SystemCallingFactory.make()
        #expect(!calling.isAvailable)
        do { try await calling.requestStart(SystemCallDescriptor(id: UUID(), displayName: "Fixture", isVideo: false)); Issue.record("Host started CallKit") }
        catch { #expect(error as? SystemCallingError == .unavailable) }
        let push = VoIPPushNotificationsFactory.make(calling: calling)
        #expect(!push.isEnabled)
        do { try push.enable(validatedDeployment: VerifiedPushFixture()); Issue.record("Host enabled PushKit") }
        catch { #expect(error as? VoIPPushError == .unavailable) }
        let normal = NormalPushNotificationsFactory.make()
        #expect(normal.authorization == .unavailable)
        normal.unregister()
    }
    #endif
}
