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

    /// Готовит адаптер PushKit и поток ошибок. Регистрация начинается после включения сервиса.
    /// - Parameter calling: Сервис системных звонков для обработки входящих уведомлений.
    init(calling: any SystemCalling) {
        self.calling = calling
        let pair = AsyncStream.makeStream(of: VoIPPushError.self, bufferingPolicy: .bufferingNewest(16))
        failures = pair.stream; continuation = pair.continuation
        super.init()
        // Intentionally no PKPushRegistry or desiredPushTypes until verified deployment injection.
    }

    /// Включает получение VoIP-уведомлений по проверенному серверному контракту.
    /// - Parameter validatedDeployment: Реализация разбора уведомлений и регистрации токена для этого сервера.
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

    /// Отменяет регистрацию PushKit, ожидает завершения записи токена и отзывает его на сервере.
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

    /// Последовательно регистрирует обновления токена, исключая запись устаревшей версии после новой.
    /// - Parameter token: Токен, выданный текущей регистрацией PushKit.
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
    /// Передаёт обновлённый VoIP-токен на регистрацию.
    /// - Parameters:
    ///   - registry: Экземпляр реестра, выдавшего токен.
    ///   - pushCredentials: Данные PushKit, содержащие токен устройства.
    ///   - type: Вид уведомлений, к которому относится токен.
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        let token = pushCredentials.token
        MainActor.assumeIsolated { if self.registry === registry { register(token) } }
    }
    /// Отменяет ожидающую регистрацию и отзывает недействительный токен на сервере.
    /// - Parameters:
    ///   - registry: Реестр, сообщивший об отзыве токена.
    ///   - type: Вид уведомлений, для которого отозван токен.
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        MainActor.assumeIsolated {
            guard self.registry === registry, let deployment else { return }
            let registration = tokenTask; registration?.cancel()
            tokenTask = Task { await registration?.value; await deployment.invalidateVoIPToken() }
        }
    }
    /// Передаёт входящее VoIP-уведомление проверенному обработчику и завершает вызов PushKit.
    /// - Parameters:
    ///   - registry: Реестр, доставивший уведомление.
    ///   - payload: Данные входящего звонка от PushKit.
    ///   - type: Тип полученного уведомления.
    ///   - completion: Обработчик PushKit, вызываемый по завершении регистрации звонка.
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
