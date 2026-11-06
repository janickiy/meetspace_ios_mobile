#if os(iOS)
import Foundation
@preconcurrency import PushKit

@MainActor final class NativeVoIPPushNotifications: NSObject, VoIPPushNotifications {
    let failures: AsyncStream<VoIPPushError>
    private let continuation: AsyncStream<VoIPPushError>.Continuation
    private let calling: any SystemCalling
    private var registry: PKPushRegistry?
    private var deployment: (any ValidatedVoIPPushDeployment)?
    private var generation = UUID()
    private var tokenTask: Task<Void, Never>?
    private var disabling = false
    private(set) var isEnabled = false

    init(calling: any SystemCalling) {
        self.calling = calling
        let pair = AsyncStream.makeStream(of: VoIPPushError.self, bufferingPolicy: .bufferingNewest(16))
        failures = pair.stream; continuation = pair.continuation
        super.init()
        // Intentionally no PKPushRegistry or desiredPushTypes until verified deployment injection.
    }

    func enable(validatedDeployment: any ValidatedVoIPPushDeployment) throws {
        guard !isEnabled, !disabling, calling.isAvailable,
              !validatedDeployment.contractIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoIPPushError.invalidDeployment
        }
        // Never reinterpret a delayed push/token callback with another deployment's resolver.
        if let deployment, deployment !== validatedDeployment { throw VoIPPushError.invalidDeployment }
        generation = UUID(); deployment = validatedDeployment; isEnabled = true
        let registry = self.registry ?? PKPushRegistry(queue: .main)
        self.registry = registry; registry.delegate = self
        registry.desiredPushTypes = [.voIP]
    }

    func disable() async {
        guard !disabling else { return }
        disabling = true; defer { disabling = false }
        generation = UUID(); isEnabled = false
        let registration = tokenTask; tokenTask = nil; registration?.cancel()
        registry?.desiredPushTypes = []
        // Keep the verified resolver for a callback already enqueued before unregistering.
        // It must still be reported to CallKit; the account coordinator reconciles server state.
        await registration?.value
        await deployment?.invalidateVoIPToken()
    }

    private func register(_ token: Data) {
        guard isEnabled, let deployment, !token.isEmpty else { return }
        let previous = tokenTask; previous?.cancel(); let operation = generation
        tokenTask = Task { [weak self] in
            // Cancellation does not guarantee that a registrar has stopped its network write.
            // Preserve the chain so rotation and disable's revoke follow every earlier write.
            await previous?.value
            guard let self, !Task.isCancelled, generation == operation, isEnabled else { return }
            do { try await deployment.registerVoIPToken(token) }
            catch {
                guard !Task.isCancelled, generation == operation, isEnabled else { return }
                continuation.yield(.registrationFailed)
            }
        }
    }
}

extension NativeVoIPPushNotifications: PKPushRegistryDelegate {
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        let token = pushCredentials.token
        MainActor.assumeIsolated { if self.registry === registry { register(token) } }
    }
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        MainActor.assumeIsolated {
            guard self.registry === registry, let deployment else { return }
            let registration = tokenTask; registration?.cancel()
            tokenTask = Task { await registration?.value; await deployment.invalidateVoIPToken() }
        }
    }
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
                                 for type: PKPushType, completion: @escaping () -> Void) {
        let completion = PushCompletion(completion)
        MainActor.assumeIsolated {
            guard type == .voIP, let deployment else { completion.finish(); return }
            VoIPPushDelivery.report(payload.dictionaryPayload, deployment: deployment, calling: calling, completion: completion)
        }
    }
}
#endif
