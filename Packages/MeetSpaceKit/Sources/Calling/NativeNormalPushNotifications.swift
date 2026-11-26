#if os(iOS)
import Foundation
import UIKit
@preconcurrency import UserNotifications

@MainActor final class NativeNormalPushNotifications: NormalPushNotifications {
    let events: AsyncStream<NormalPushNotificationEvent>
    private let continuation: AsyncStream<NormalPushNotificationEvent>.Continuation
    private(set) var authorization = NormalPushAuthorization.notDetermined
    private var registrationEnabled = false

    /// Создаёт поток событий разрешения и регистрации обычных уведомлений.
    init() {
        let pair = AsyncStream.makeStream(of: NormalPushNotificationEvent.self, bufferingPolicy: .bufferingNewest(32))
        events = pair.stream; continuation = pair.continuation
    }
    /// Запрашивает баннеры, значки и звук и считывает итоговый статус из настроек уведомлений.
    func requestAuthorization() async throws -> NormalPushAuthorization {
        do { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) }
        catch {
            continuation.yield(.failure(.permissionRequestFailed))
            throw NormalPushNotificationsError.permissionRequestFailed
        }
        await refreshAuthorization()
        return authorization
    }
    /// Публикует актуальный статус разрешения, полученный от системного центра уведомлений.
    func refreshAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: authorization = .notDetermined
        case .denied: authorization = .denied
        case .authorized: authorization = .authorized
        case .provisional: authorization = .provisional
        case .ephemeral: authorization = .ephemeral
        @unknown default: authorization = .unavailable
        }
        continuation.yield(.authorization(authorization))
    }
    /// Включает обработку ответов регистрации и запрашивает у UIKit токен APNs.
    func register() { registrationEnabled = true; UIApplication.shared.registerForRemoteNotifications() }
    /// Отменяет регистрацию в UIKit и отключает обработку запоздалых ответов.
    func unregister() { registrationEnabled = false; UIApplication.shared.unregisterForRemoteNotifications() }
    /// Публикует полученный токен для активной регистрации или сообщает об ошибке при пустом токене.
    /// - Parameter deviceToken: Последний токен, полученный непосредственно от Apple.
    func didRegister(deviceToken: Data) {
        guard registrationEnabled else { return }
        guard !deviceToken.isEmpty else { didFailRegistration(); return }
        continuation.yield(.token(deviceToken))
    }
    /// Публикует ошибку для активной попытки регистрации в APNs.
    func didFailRegistration() {
        guard registrationEnabled else { return }
        continuation.yield(.failure(.registrationFailed))
    }
}
#endif
