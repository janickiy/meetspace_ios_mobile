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
    func requestAuthorization() async throws -> NormalPushAuthorization
    func refreshAuthorization() async
    func register()
    func unregister()
    /// App delegate forwards Apple's latest token; it is never restored from a local token cache.
    func didRegister(deviceToken: Data)
    func didFailRegistration()
}

@MainActor public enum NormalPushNotificationsFactory {
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
    func requestAuthorization() async throws -> NormalPushAuthorization { throw NormalPushNotificationsError.unavailable }
    func refreshAuthorization() async { }
    func register() { }
    func unregister() { }
    func didRegister(deviceToken: Data) { }
    func didFailRegistration() { }
}
#endif
