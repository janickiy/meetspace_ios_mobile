#if os(iOS)
import Foundation
import UIKit
@preconcurrency import UserNotifications

@MainActor final class NativeNormalPushNotifications: NormalPushNotifications {
    let events: AsyncStream<NormalPushNotificationEvent>
    private let continuation: AsyncStream<NormalPushNotificationEvent>.Continuation
    private(set) var authorization = NormalPushAuthorization.notDetermined
    private var registrationEnabled = false

    init() {
        let pair = AsyncStream.makeStream(of: NormalPushNotificationEvent.self, bufferingPolicy: .bufferingNewest(32))
        events = pair.stream; continuation = pair.continuation
    }
    func requestAuthorization() async throws -> NormalPushAuthorization {
        do { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) }
        catch {
            continuation.yield(.failure(.permissionRequestFailed))
            throw NormalPushNotificationsError.permissionRequestFailed
        }
        await refreshAuthorization()
        return authorization
    }
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
    func register() { registrationEnabled = true; UIApplication.shared.registerForRemoteNotifications() }
    func unregister() { registrationEnabled = false; UIApplication.shared.unregisterForRemoteNotifications() }
    func didRegister(deviceToken: Data) {
        guard registrationEnabled else { return }
        guard !deviceToken.isEmpty else { didFailRegistration(); return }
        continuation.yield(.token(deviceToken))
    }
    func didFailRegistration() {
        guard registrationEnabled else { return }
        continuation.yield(.failure(.registrationFailed))
    }
}
#endif
