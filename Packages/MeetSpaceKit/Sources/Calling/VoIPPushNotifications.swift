import Foundation

/// An integration may provide this only after verifying its real APNs VoIP payload and token
/// registration contract. The current MeetSpace server does not supply such an integration.
/// The resolver MUST synchronously return a valid descriptor for every delivered VoIP push,
/// including its deployment's documented malformed/stale payload policy. It must not do I/O.
@MainActor public protocol ValidatedVoIPPushDeployment: AnyObject {
    var contractIdentifier: String { get }
    func resolveIncomingCall(_ payload: [AnyHashable: Any]) -> SystemCallDescriptor
    func registerVoIPToken(_ token: Data) async throws
    func invalidateVoIPToken() async
}

public enum VoIPPushError: Error, Equatable, Sendable { case unavailable, invalidDeployment, registrationFailed }

@MainActor public protocol VoIPPushNotifications: AnyObject {
    var isEnabled: Bool { get }
    var failures: AsyncStream<VoIPPushError> { get }
    func enable(validatedDeployment: any ValidatedVoIPPushDeployment) throws
    func disable() async
}

@MainActor public enum VoIPPushNotificationsFactory {
    public static func make(calling: any SystemCalling) -> any VoIPPushNotifications {
        #if os(iOS)
        NativeVoIPPushNotifications(calling: calling)
        #else
        UnavailableVoIPPushNotifications()
        #endif
    }
}

/// Owns a legacy SDK completion block across queues. The lock makes completion exactly once even
/// if an adapter invokes a completion twice; no CallKit/PushKit object crosses into application code.
final class PushCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var body: (() -> Void)?
    init(_ body: @escaping () -> Void) { self.body = body }
    func finish() {
        lock.lock(); let value = body; body = nil; lock.unlock()
        value?()
    }
}

@MainActor enum VoIPPushDelivery {
    static func report(_ payload: [AnyHashable: Any], deployment: any ValidatedVoIPPushDeployment,
                       calling: any SystemCalling, completion: PushCompletion) {
        let descriptor = deployment.resolveIncomingCall(payload)
        // No Task/await: report reaches CXProvider before the PushKit delegate returns.
        calling.reportIncoming(descriptor) { @Sendable _ in completion.finish() }
    }
}

#if !os(iOS)
@MainActor private final class UnavailableVoIPPushNotifications: VoIPPushNotifications {
    let isEnabled = false
    var failures: AsyncStream<VoIPPushError> { AsyncStream { $0.finish() } }
    func enable(validatedDeployment: any ValidatedVoIPPushDeployment) throws { throw VoIPPushError.unavailable }
    func disable() async { }
}
#endif
