import Foundation
import Observation
import MeetSpaceCore
import MeetSpaceAPI
import MeetSpaceStorage
import MeetSpaceRealtime

public struct AppDependencies: Sendable {
    public let serverProbe: any ServerProbing
    public let configuration: any ConfigurationStore
    public let credentials: any SecureStore
    public let accounts: any AccountIndexStore
    public let transport: @Sendable () -> any RequestTransport
    public let sockets: any RealtimeSocketFactory
    public init(serverProbe: any ServerProbing, configuration: any ConfigurationStore, credentials: any SecureStore,
                accounts: any AccountIndexStore = MemoryAccountIndexStore(),
                transport: @escaping @Sendable () -> any RequestTransport = { URLSessionRequestTransport() },
                sockets: any RealtimeSocketFactory = URLSessionSocketFactory()) {
        self.serverProbe = serverProbe; self.configuration = configuration; self.credentials = credentials
        self.accounts = accounts; self.transport = transport; self.sockets = sockets
    }
    public static func live() -> AppDependencies {
        AppDependencies(serverProbe: ServerProbe(), configuration: PreferencesStore(),
                        credentials: KeychainStore(service: "com.meetspace.ios.credentials"), accounts: AccountPreferencesStore())
    }
}

@MainActor @Observable public final class AppModel {
    public enum Onboarding: Hashable { case welcome, connect, login, register }
    public private(set) var onboarding: Onboarding = .welcome
    public private(set) var isDemo = false
    public var tab: AppTab = .meetings
    public var meetingsPath: [AppRoute] = []
    public var messagesPath: [AppRoute] = []
    public var profilePath: [AppRoute] = []
    public var contentState: LoadState = .content
    public var configuration = AppConfiguration()
    public private(set) var probeState: LoadState = .empty
    public private(set) var checkedServer: ServerOrigin?
    public private(set) var serverVersion: ServerVersion?
    public private(set) var connectionError: ConnectionError?
    public var notice: String?
    public let identity: IdentityModel
    @ObservationIgnored private let dependencies: AppDependencies
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    @ObservationIgnored private var probeGeneration = UUID()
    @ObservationIgnored private var preferenceTask: Task<Void, Never>?

    public enum ConnectionError: Equatable { case invalidURL, offline, timeout, tls, redirect, incompatible, storage }

    public init(dependencies: AppDependencies = .live()) {
        self.dependencies = dependencies; identity = IdentityModel(dependencies: dependencies)
    }

    public func restore() async {
        do { configuration = try await dependencies.configuration.load() }
        catch { notice = "Не удалось прочитать настройки. Введите адрес сервера заново." }
        await identity.restore()
        if let account = identity.messaging?.account { configuration.server = account.server; tab = .messages }
        else if let account = identity.index.accounts.first(where: { $0.id == identity.index.activeID }) {
            configuration.server = account.server; onboarding = .login
        }
    }

    public func show(_ screen: Onboarding) {
        guard !identity.busy else { return }
        if screen == .connect { addressChanged() } else { cancelProbe() }
        onboarding = screen
    }
    public func sessionEnded() { cancelProbe(); onboarding = .login }

    public func addressChanged() {
        cancelProbe()
        checkedServer = nil; serverVersion = nil; connectionError = nil; probeState = .empty
    }

    public func cancelProbe() {
        probeGeneration = UUID()
        probeTask?.cancel(); probeTask = nil
        if probeState == .loading { probeState = .empty }
    }

    public func checkServer(_ input: String) {
        addressChanged()
        guard let server = try? ServerOrigin(input) else {
            connectionError = .invalidURL; probeState = .failed; return
        }
        let generation = probeGeneration
        probeState = .loading
        probeTask = Task { [weak self, dependencies] in
            do {
                let version = try await dependencies.serverProbe.check(server)
                try Task.checkCancellation()
                guard let self, self.probeGeneration == generation else { return }
                self.checkedServer = server; self.serverVersion = version; self.probeState = .content
            } catch is CancellationError { /* A newer check or leaving the screen owns the state. */ }
            catch {
                guard let self, self.probeGeneration == generation else { return }
                switch error {
                case APIError.offline: self.connectionError = .offline; self.probeState = .offline
                case APIError.timeout: self.connectionError = .timeout; self.probeState = .failed
                case APIError.tls: self.connectionError = .tls; self.probeState = .failed
                case APIError.redirect: self.connectionError = .redirect; self.probeState = .failed
                default: self.connectionError = .incompatible; self.probeState = .failed
                }
            }
        }
    }

    public func continueToLogin() async {
        guard probeState == .content, let server = checkedServer else { return }
        let generation = probeGeneration
        var next = configuration; next.server = server
        do {
            try await dependencies.configuration.save(next)
            guard probeGeneration == generation else { return }
            configuration = next; show(.login)
        } catch {
            guard probeGeneration == generation else { return }
            connectionError = .storage; probeState = .failed
        }
    }

    public func setAppearance(_ appearance: Appearance) {
        configuration.appearance = appearance
        let snapshot = configuration
        let prior = preferenceTask
        preferenceTask = Task { [weak self, dependencies] in
            await prior?.value // Preserve write order when the picker changes quickly.
            do { try await dependencies.configuration.save(snapshot) }
            catch { self?.notice = "Не удалось сохранить настройки." }
        }
    }

    public func enterDemo() {
        guard identity.messaging == nil, !identity.busy else { return }
        cancelProbe(); isDemo = true; tab = .meetings
        meetingsPath = []; messagesPath = []; profilePath = []; contentState = .content
    }

    public func leaveDemo() {
        isDemo = false; onboarding = .welcome
        meetingsPath = []; messagesPath = []; profilePath = []
    }

    public func navigate(_ route: AppRoute) {
        switch tab {
        case .meetings: meetingsPath.append(route)
        case .messages: messagesPath.append(route)
        case .profile: profilePath.append(route)
        }
    }
}
