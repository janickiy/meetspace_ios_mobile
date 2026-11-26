import Foundation

/// An integration may provide this only after verifying its real APNs VoIP payload and token
/// registration contract. The current MeetSpace server does not supply such an integration.
/// The resolver MUST synchronously return a valid descriptor for every delivered VoIP push,
/// including its deployment's documented malformed/stale payload policy. It must not do I/O.
@MainActor public protocol ValidatedVoIPPushDeployment: AnyObject {
    var contractIdentifier: String { get }
    /// Синхронно преобразует данные VoIP-уведомления в описание входящего звонка по контракту сервера.
    /// - Parameter payload: Данные уведомления PushKit в формате конкретного сервера.
    func resolveIncomingCall(_ payload: [AnyHashable: Any]) -> SystemCallDescriptor
    /// Регистрирует актуальный токен PushKit на сервере звонков.
    /// - Parameter token: Токен устройства для VoIP-уведомлений.
    func registerVoIPToken(_ token: Data) async throws
    /// Отзывает регистрацию текущего VoIP-токена на сервере.
    func invalidateVoIPToken() async
}

public enum VoIPPushError: Error, Equatable, Sendable { case unavailable, invalidDeployment, registrationFailed }

@MainActor public protocol VoIPPushNotifications: AnyObject {
    var isEnabled: Bool { get }
    var failures: AsyncStream<VoIPPushError> { get }
    /// Включает получение VoIP-уведомлений по проверенному серверному контракту.
    /// - Parameter validatedDeployment: Реализация разбора уведомлений и регистрации токена для этого сервера.
    func enable(validatedDeployment: any ValidatedVoIPPushDeployment) throws
    /// Отключает получение VoIP-уведомлений и отзывает токен.
    func disable() async
}

@MainActor public enum VoIPPushNotificationsFactory {
    /// Выбирает реализацию доставки VoIP-звонков для текущей платформы.
    /// - Parameter calling: Сервис, которому передаются входящие звонки.
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
    /// Сохраняет обработчик PushKit для однократного завершения доставки.
    /// - Parameter body: Обработчик завершения, предоставленный PushKit.
    init(_ body: @escaping () -> Void) { self.body = body }
    /// Однократно извлекает и вызывает обработчик завершения доставки.
    func finish() {
        lock.lock(); let value = body; body = nil; lock.unlock()
        value?()
    }
}

@MainActor enum VoIPPushDelivery {
    /// Разбирает уведомление и синхронно сообщает о звонке системе до возврата из делегата PushKit.
    /// - Parameters:
    ///   - payload: Содержимое VoIP-уведомления.
    ///   - deployment: Проверенный обработчик формата этого сервера.
    ///   - calling: Системный сервис для регистрации входящего звонка.
    ///   - completion: Одноразовое завершение обработки уведомления.
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
    /// Сообщает о недоступности PushKit на текущей платформе.
    /// - Parameter validatedDeployment: Реализация разбора уведомлений и регистрации токена для этого сервера.
    func enable(validatedDeployment: any ValidatedVoIPPushDeployment) throws { throw VoIPPushError.unavailable }
    /// Завершает работу адаптера без активной регистрации PushKit.
    func disable() async { }
}
#endif
