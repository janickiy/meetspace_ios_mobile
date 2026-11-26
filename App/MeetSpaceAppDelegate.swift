import UIKit
import UserNotifications
import MeetSpaceCalling
import MeetSpaceCore

/// The provider exists for the process lifetime, before account restoration or network access.
@MainActor final class AppPlatformRuntime {
    static let shared = AppPlatformRuntime()
    let calling = SystemCallingFactory.make()
    let notifications = NormalPushNotificationsFactory.make()
    let voip: any VoIPPushNotifications
    /// Связывает обработчик VoIP-уведомлений с общим сервисом системных звонков.
    private init() {
        voip = VoIPPushNotificationsFactory.make(calling: calling)
        // The audited server has no VoIP token/payload contract. No registry is enabled here.
    }
}

@MainActor final class MeetSpaceAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private var isUITesting: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-uitesting")
        #else
        false
        #endif
    }
    /// Готовит сервисы платформы при запуске и назначает делегата центра уведомлений.
    /// - Parameters:
    ///   - application: Запущенное приложение UIKit.
    ///   - launchOptions: Контекст запуска, переданный системой.
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        guard !isUITesting else { return true }
        _ = AppPlatformRuntime.shared
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    /// Передаёт полученный токен APNs сервису обычных уведомлений.
    /// - Parameters:
    ///   - application: Приложение, зарегистрированное в APNs.
    ///   - deviceToken: Актуальный токен устройства от Apple.
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        guard !isUITesting else { return }
        AppPlatformRuntime.shared.notifications.didRegister(deviceToken: deviceToken)
    }
    /// Сообщает сервису уведомлений об отказе в регистрации в APNs.
    /// - Parameters:
    ///   - application: Приложение, запросившее регистрацию.
    ///   - error: Ошибка, полученная от UIKit.
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        guard !isUITesting else { return }
        AppPlatformRuntime.shared.notifications.didFailRegistration()
    }
    /// Выбирает баннер и запись в списке для уведомления на переднем плане, учитывая настройку звука.
    /// - Parameters:
    ///   - center: Центр, доставивший уведомление.
    ///   - notification: Уведомление, полученное активным приложением.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // Ordinary APNs only; never interpret it as a call or a command to switch account.
        ForegroundNotificationSound.enabled ? [.banner, .list, .sound] : [.banner, .list]
    }
    /// Принимает ответ на уведомление. Обновление рабочего пространства выполняется при активации сцены.
    /// - Parameters:
    ///   - center: Центр, получивший ответ.
    ///   - response: Выбранное пользователем действие с уведомлением.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse) async {
        // Scene activation reconciles the authenticated workspace. The audited gateway doesn't
        // provide a verified account-scoped deep-link payload, so no payload URL is followed.
    }
}
