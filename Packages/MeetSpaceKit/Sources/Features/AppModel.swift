import Foundation
import Observation
import MeetSpaceCore
import MeetSpaceAPI
import MeetSpaceStorage
import MeetSpaceRealtime
import MeetSpaceMedia
import MeetSpaceCalling
import MeetSpaceBroadcast

public struct AppDependencies: Sendable {
    public let serverProbe: any ServerProbing
    public let configuration: any ConfigurationStore
    public let credentials: any SecureStore
    public let accounts: any AccountIndexStore
    public let transport: @Sendable () -> any RequestTransport
    public let sockets: any RealtimeSocketFactory
    public let conferenceSockets: any ConferenceSocketFactory
    public let media: @MainActor @Sendable () -> any ConferenceMediaEngine
    public let broadcast: @MainActor @Sendable () -> any ScreenBroadcastController
    public let calling: @MainActor @Sendable () -> any SystemCalling
    public let notifications: @MainActor @Sendable () -> any NormalPushNotifications
    public let pushStore: any PushRegistrationStore
    public let calendarPreferences: @Sendable (CredentialKey) -> any CalendarPreferencesStore
    public let recordingDownloads: @Sendable (AccountRecord) -> (any RecordingDownloading)?
    public init(serverProbe: any ServerProbing, configuration: any ConfigurationStore, credentials: any SecureStore,
                accounts: any AccountIndexStore = MemoryAccountIndexStore(),
                transport: @escaping @Sendable () -> any RequestTransport = { URLSessionRequestTransport() },
                sockets: any RealtimeSocketFactory = URLSessionSocketFactory(),
                conferenceSockets: any ConferenceSocketFactory = URLSessionConferenceSocketFactory(),
                media: @escaping @MainActor @Sendable () -> any ConferenceMediaEngine = { ConferenceMediaFactory.make() },
                broadcast: @escaping @MainActor @Sendable () -> any ScreenBroadcastController = { BroadcastControllerFactory.make() },
                calling: @escaping @MainActor @Sendable () -> any SystemCalling = { SystemCallingFactory.make() },
                notifications: @escaping @MainActor @Sendable () -> any NormalPushNotifications = { NormalPushNotificationsFactory.make() },
                pushStore: any PushRegistrationStore = MemoryPushRegistrationStore(),
                calendarPreferences: @escaping @Sendable (CredentialKey) -> any CalendarPreferencesStore = { _ in MemoryCalendarPreferencesStore() },
                recordingDownloads: @escaping @Sendable (AccountRecord) -> (any RecordingDownloading)? = { _ in nil }) {
        self.serverProbe = serverProbe; self.configuration = configuration; self.credentials = credentials
        self.accounts = accounts; self.transport = transport; self.sockets = sockets
        self.conferenceSockets = conferenceSockets; self.media = media; self.broadcast = broadcast
        self.calling = calling; self.notifications = notifications; self.pushStore = pushStore
        self.calendarPreferences = calendarPreferences
        self.recordingDownloads = recordingDownloads
    }
    @MainActor public static func live(calling: (any SystemCalling)? = nil,
                                       notifications: (any NormalPushNotifications)? = nil) -> AppDependencies {
        let system = calling ?? SystemCallingFactory.make()
        let push = notifications ?? NormalPushNotificationsFactory.make()
        return AppDependencies(serverProbe: ServerProbe(), configuration: PreferencesStore(),
                        credentials: KeychainStore(service: "com.meetspace.ios.credentials"), accounts: AccountPreferencesStore(),
                        calling: { system }, notifications: { push },
                        pushStore: KeychainPushRegistrationStore(service: "com.meetspace.ios.push-bindings"),
                        calendarPreferences: { UserDefaultsCalendarPreferencesStore(account: $0) })
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
    public private(set) var guestConference: ConferenceSession?
    public private(set) var guestBusy = false
    public var guestError: String?
    public var activeConference: ConferenceSession? { guestConference ?? identity.conferences?.call }
    @ObservationIgnored private let dependencies: AppDependencies
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    @ObservationIgnored private var probeGeneration = UUID()
    @ObservationIgnored private var preferenceTask: Task<Void, Never>?
    @ObservationIgnored private var guestGeneration = UUID()
    @ObservationIgnored private var departingGuest: ConferenceSession?

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

    public func joinGuest(server: String, invitation: String, name: String) async -> Bool {
        guard !guestBusy, !identity.busy, identity.messaging == nil, guestConference == nil else { return false }
        let epoch = UUID(); guestGeneration = epoch
        guestBusy = true; guestError = nil; defer { guestBusy = false }
        do {
            if let departingGuest {
                guard await departingGuest.awaitDeparture() else {
                    guestError = "Сервер не подтвердил предыдущий выход. Повторный вход пока недоступен."
                    return false
                }
                self.departingGuest = nil
            }
            let origin = try ServerOrigin(server)
            let code = try ConferenceInviteGateway.inviteCode(from: invitation, origin: origin)
            let gateway = ConferenceInviteGateway(origin: origin, transport: dependencies.transport())
            let invite = try await gateway.lookup(code: code)
            guard guestGeneration == epoch, identity.messaging == nil, !identity.busy else { return false }
            let guest = try await gateway.guestJoin(code: code, displayName: name)
            let repository = ConferenceRepository(origin: origin, guest: guest, transport: dependencies.transport())
            guard guestGeneration == epoch, identity.messaging == nil, !identity.busy else {
                _ = try? await repository.leave(guest.conferenceID); return false
            }
            guestConference = ConferenceSession(repository: repository, title: invite.title, participant: guest.participant,
                sockets: dependencies.conferenceSockets, makeMedia: dependencies.media, makeBroadcast: dependencies.broadcast)
            guestConference?.observeLobby()
            return true
        } catch { guestError = userMessage(error); return false }
    }
    public func dismissConference() async {
        if let guestConference {
            await guestConference.leave(); departingGuest = guestConference; self.guestConference = nil
        } else { await identity.conferences?.dismissCall() }
    }
    public func identityChanged() {
        guestGeneration = UUID()
        if identity.messaging != nil, let guestConference {
            Task { await guestConference.leave() }
            self.guestConference = nil
        }
    }

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
