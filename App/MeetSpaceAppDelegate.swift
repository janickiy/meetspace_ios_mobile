import UIKit
import UserNotifications
import MeetSpaceCalling

/// The provider exists for the process lifetime, before account restoration or network access.
@MainActor final class AppPlatformRuntime {
    static let shared = AppPlatformRuntime()
    let calling = SystemCallingFactory.make()
    let notifications = NormalPushNotificationsFactory.make()
    let voip: any VoIPPushNotifications
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
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        guard !isUITesting else { return true }
        _ = AppPlatformRuntime.shared
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        guard !isUITesting else { return }
        AppPlatformRuntime.shared.notifications.didRegister(deviceToken: deviceToken)
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        guard !isUITesting else { return }
        AppPlatformRuntime.shared.notifications.didFailRegistration()
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // Ordinary APNs only; never interpret it as a call or a command to switch account.
        [.banner, .list, .sound]
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse) async {
        // Scene activation reconciles the authenticated workspace. The audited gateway doesn't
        // provide a verified account-scoped deep-link payload, so no payload URL is followed.
    }
}
