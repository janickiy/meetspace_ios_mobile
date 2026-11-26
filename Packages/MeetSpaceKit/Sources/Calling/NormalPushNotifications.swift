import Foundation

public enum NormalPushAuthorization: Equatable, Sendable {
    case notDetermined, denied, authorized, provisional, ephemeral, unavailable
}

public enum NormalPushNotificationsError: Error, Equatable, Sendable {
    case unavailable, permissionRequestFailed, registrationFailed
}

public enum NormalPushNotificationEvent: Equatable, Sendable {
    case token(Data)
    case authorization(NormalPushAuthorization)
    case failure(NormalPushNotificationsError)
}

/// Ordinary APNs registration is independent of the VoIP PushKit registration and payload path.
@MainActor public protocol NormalPushNotifications: AnyObject {
    var events: AsyncStream<NormalPushNotificationEvent> { get }
    var authorization: NormalPushAuthorization { get }
    /// Запрашивает у пользователя разрешение на обычные уведомления и возвращает его актуальный статус.
    func requestAuthorization() async throws -> NormalPushAuthorization
    /// Обновляет сохранённый статус разрешения по системным настройкам уведомлений.
    func refreshAuthorization() async
    /// Запрашивает регистрацию приложения в APNs для обычных уведомлений.
    func register()
    /// Отменяет регистрацию приложения для обычных уведомлений.
    func unregister()
    /// Принимает свежий токен от делегата приложения после регистрации в APNs.
    /// - Parameter deviceToken: Последний токен, полученный непосредственно от Apple.
    func didRegister(deviceToken: Data)
    /// Обрабатывает отказ APNs в регистрации устройства.
    func didFailRegistration()
}

@MainActor public enum NormalPushNotificationsFactory {
    /// Выбирает адаптер обычных уведомлений для текущей платформы.
    public static func make() -> any NormalPushNotifications {
        #if os(iOS)
        NativeNormalPushNotifications()
        #else
        UnavailableNormalPushNotifications()
        #endif
    }
}

#if !os(iOS)
@MainActor private final class UnavailableNormalPushNotifications: NormalPushNotifications {
    let events = AsyncStream<NormalPushNotificationEvent> { $0.finish() }
    let authorization = NormalPushAuthorization.unavailable
    /// Сообщает о недоступности запроса разрешения на обычные уведомления.
    func requestAuthorization() async throws -> NormalPushAuthorization { throw NormalPushNotificationsError.unavailable }
    /// Пропускает обновление разрешения на платформе без APNs.
    func refreshAuthorization() async { }
    /// Пропускает запрос регистрации на платформе без APNs.
    func register() { }
    /// Пропускает запрос отмены регистрации на платформе без APNs.
    func unregister() { }
    /// Пропускает событие получения токена на платформе без APNs.
    /// - Parameter deviceToken: Последний токен, полученный непосредственно от Apple.
    func didRegister(deviceToken: Data) { }
    /// Пропускает сообщение об ошибке регистрации на платформе без APNs.
    func didFailRegistration() { }
}
#endif
