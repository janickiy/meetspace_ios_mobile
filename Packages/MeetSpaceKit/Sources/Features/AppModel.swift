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
    /// Объединяет сервисы, хранилища и фабрики, используемые приложением.
    /// - Parameters:
    ///   - serverProbe: Сервис проверки совместимости сервера.
    ///   - configuration: Хранилище адреса сервера и настроек приложения.
    ///   - credentials: Хранилище секретов сессии.
    ///   - accounts: Индекс сохранённых аккаунтов.
    ///   - transport: Фабрика транспорта HTTP-запросов.
    ///   - sockets: Фабрика сокетов событий рабочего пространства.
    ///   - conferenceSockets: Фабрика сокетов конференций.
    ///   - media: Фабрика аудио- и видеодвижка конференций.
    ///   - broadcast: Фабрика контроллера трансляции экрана.
    ///   - calling: Фабрика системной интеграции звонков.
    ///   - notifications: Фабрика сервиса обычных push-уведомлений.
    ///   - pushStore: Хранилище регистраций устройств для push-уведомлений.
    ///   - calendarPreferences: Фабрика хранилища настроек календаря по ключу аккаунта.
    ///   - recordingDownloads: Фабрика загрузчика записей для конкретного аккаунта.
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
    /// Создаёт набор сервисов для работы приложения с сервером и системными службами.
    /// - Parameters:
    ///   - calling: Системная интеграция звонков, если её предоставляет вызывающая сторона.
    ///   - notifications: Сервис push-уведомлений, если его предоставляет вызывающая сторона.
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
    private(set) var demoChats = DemoChatStore()
    private(set) var demoFolders = DemoFolderStore()
    private(set) var demoMeetings = DemoMeetingsState()
    private(set) var demoDeletedRecordings: Set<Int> = []
    private var demoCreatedRecordings: [RecordingLibraryEntry] = []
    private(set) var demoAccounts = DemoAccounts()
    var demoProfile: DemoAccountProfile { demoAccounts.current }
    private(set) var demoPrejoinTitle: String?
    var demoConferenceEntry: DemoConferenceEntry?
    public private(set) var isDemo = false
    public var tab: AppTab = .meetings
    public var meetingsPath: [AppRoute] = []
    public var messagesPath: [AppRoute] = []
    public var profilePath: [AppRoute] = []
    public var contentState: LoadState = .content
    public var configuration = AppConfiguration()
    public private(set) var probeState: LoadState = .empty
    public private(set) var checkedServer: ServerOrigin?
    private(set) var connectionPrefill: ServerOrigin?
    var authenticationServer: ServerOrigin? {
        identity.addingAccount ? checkedServer : configuration.server
    }
    public private(set) var serverVersion: ServerVersion?
    public private(set) var connectionError: ConnectionError?
    var showingWorkspaceNotifications = false
    /// Открывает список уведомлений рабочего пространства.
    func presentWorkspaceNotifications() { showingWorkspaceNotifications = true }
    public var installerPresented = false
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

    /// Создаёт модель приложения и общую модель авторизации.
    /// - Parameter dependencies: Сервисы и хранилища приложения.
    public init(dependencies: AppDependencies = .live()) {
        self.dependencies = dependencies; identity = IdentityModel(dependencies: dependencies)
    }

    /// Восстанавливает настройки приложения и ранее сохранённый аккаунт.
    public func restore() async {
        do { configuration = try await dependencies.configuration.load() }
        catch { notice = "Не удалось прочитать настройки. Введите адрес сервера заново." }
        await identity.restore()
        if let account = identity.messaging?.account { configuration.server = account.server; tab = .messages }
        else if let account = identity.index.accounts.first(where: { $0.id == identity.index.activeID }) {
            configuration.server = account.server; onboarding = .login
        }
    }

    /// Переключает шаг знакомства с приложением и при необходимости подставляет адрес сервера.
    /// - Parameters:
    ///   - screen: Шаг, который нужно открыть.
    ///   - server: Адрес сервера для формы подключения.
    public func show(_ screen: Onboarding, server: ServerOrigin? = nil) {
        guard !identity.busy else { return }
        if screen == .connect {
            connectionPrefill = server ?? configuration.server
            addressChanged()
        } else { cancelProbe() }
        onboarding = screen
    }
    /// Отменяет проверку сервера и возвращает пользователя к форме входа.
    public func sessionEnded() { cancelProbe(); onboarding = .login }

    /// Входит во встречу по приглашению от имени гостя и сообщает об успехе.
    /// - Parameters:
    ///   - server: Адрес сервера встречи.
    ///   - invitation: Ссылка или код приглашения.
    ///   - name: Имя гостя для списка участников.
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
    /// Закрывает текущую конференцию и запускает выход участника.
    public func dismissConference() async {
        if let guestConference {
            await guestConference.leave(); departingGuest = guestConference; self.guestConference = nil
        } else { await identity.conferences?.dismissCall() }
    }
    /// Отменяет незавершённый гостевой вход и покидает гостевую встречу при открытии рабочего пространства аккаунта.
    public func identityChanged() {
        guestGeneration = UUID()
        if identity.messaging != nil, let guestConference {
            Task { await guestConference.leave() }
            self.guestConference = nil
        }
    }

    /// Сбрасывает результат проверки после изменения адреса сервера.
    public func addressChanged() {
        cancelProbe()
        checkedServer = nil; serverVersion = nil; connectionError = nil; probeState = .empty
    }

    /// Отменяет текущую проверку сервера и исключает применение её запоздавшего результата.
    public func cancelProbe() {
        probeGeneration = UUID()
        probeTask?.cancel(); probeTask = nil
        if probeState == .loading { probeState = .empty }
    }

    /// Проверяет введённый адрес и совместимость сервера для входа.
    /// - Parameter input: Адрес из поля подключения.
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

    /// Открывает форму входа для проверенного сервера и при необходимости сохраняет его адрес.
    public func continueToLogin() async {
        guard probeState == .content, let server = checkedServer else { return }
        // Sign in with a separate account before changing the active workspace's origin.
        if identity.addingAccount { show(.login); return }
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

    /// Проверяет другой сервер и открывает форму добавления аккаунта для него.
    /// - Parameters:
    ///   - server: Сервер, на котором предстоит войти.
    ///   - account: Аккаунт, из которого начат переход.
    func openLoginForServer(_ server: ServerOrigin, from account: AccountRecord) async {
        guard identity.messaging?.account.id == account.id, !identity.busy, !isDemo else { return }
        checkServer(server.url.absoluteString)
        let generation = probeGeneration
        await probeTask?.value
        guard !Task.isCancelled, generation == probeGeneration, checkedServer == server,
              identity.messaging?.account.id == account.id, !identity.busy else { return }
        identity.error = nil
        identity.information = nil
        identity.addingAccount = true
        show(.login)
    }

    /// Меняет тему интерфейса и сохраняет её в настройках приложения.
    /// - Parameter appearance: Выбранная тема.
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

    /// Инициализирует демонстрационные данные и открывает деморежим.
    public func enterDemo() {
        guard identity.messaging == nil, !identity.busy else { return }
        demoChats = DemoChatStore()
        demoFolders = DemoFolderStore()
        demoMeetings = DemoMeetingsState()
        demoDeletedRecordings = []
        demoCreatedRecordings = []
        demoAccounts = DemoAccounts(server: configuration.server)
        showingWorkspaceNotifications = false
        cancelProbe(); isDemo = true; tab = .meetings
        meetingsPath = []; messagesPath = []; profilePath = []; contentState = .content
    }

    /// Закрывает деморежим и возвращает приложение к приветствию.
    public func leaveDemo() {
        isDemo = false; onboarding = .welcome
        demoPrejoinTitle = nil; demoConferenceEntry = nil
        meetingsPath = []; messagesPath = []; profilePath = []
    }

    var demoRecordings: [RecordingLibraryEntry] {
        let samples = RecordingLibraryEntry.demoSamples(ownerName: demoProfile.name)
        let created = demoCreatedRecordings.map { entry in
            var current = entry
            current.owner = RecordingLibraryEntry.ownName(demoProfile.name)
            return current
        }
        return (samples + created).enumerated().compactMap { demoDeletedRecordings.contains($0.offset) ? nil : $0.element }
    }

    /// Находит доступную демонстрационную запись по её числовому идентификатору.
    /// - Parameter index: Идентификатор записи в демобиблиотеке.
    func demoRecording(at index: Int) -> RecordingLibraryEntry? {
        demoRecordings.first { $0.id == String(index) }
    }

    /// Убирает демонстрационную запись из библиотеки, если разрешено её удаление.
    /// - Parameter index: Идентификатор записи в демобиблиотеке.
    func deleteDemoRecording(at index: Int) {
        if demoRecording(at: index)?.canDelete == true { demoDeletedRecordings.insert(index) }
    }

    /// Добавляет запись демонстрационной встречи в библиотеку и возвращает её идентификатор.
    /// - Parameters:
    ///   - title: Название встречи для карточки записи.
    ///   - mode: Формат записи.
    ///   - duration: Продолжительность записи в секундах.
    ///   - participantCount: Число участников, если известно.
    ///   - meetingID: Идентификатор связанной встречи, если известен.
    @discardableResult
    func addDemoMeetingRecording(title: String, mode: RecordingMode, duration: TimeInterval,
                                 participantCount: Int? = nil, meetingID: UUID? = nil) -> Int {
        let index = RecordingLibraryEntry.demoSamples(ownerName: demoProfile.name).count + demoCreatedRecordings.count
        let seconds = duration.isFinite ? Int(max(0, min(duration, Double(Int32.max)))) : nil
        let entry = RecordingLibraryEntry(id: String(index), meetingID: meetingID?.uuidString ?? "demo-call-\(index)", kind: RecordingPreviewKind(mode: mode),
                                          title: title, date: Date(), duration: seconds, owner: RecordingLibraryEntry.ownName(demoProfile.name),
                                          participantCount: participantCount, initials: [], isLive: false, statusTitle: nil, canDelete: true)
        demoCreatedRecordings.append(entry)
        return index
    }

    /// Открывает экран подготовки к демонстрационной встрече.
    /// - Parameter title: Название встречи для экрана подготовки.
    func showDemoPrejoin(title: String? = nil) {
        demoPrejoinTitle = title
        demoConferenceEntry = nil
        navigate(.prejoin)
    }

    /// Добавляет экран в стек навигации активной вкладки.
    /// - Parameter route: Назначение перехода.
    public func navigate(_ route: AppRoute) {
        switch tab {
        case .meetings: meetingsPath.append(route)
        case .messages: messagesPath.append(route)
        case .profile: profilePath.append(route)
        }
    }
}

struct DemoConferenceEntry {
    let name: String
    let microphone: Bool
    let camera: Bool
    let title: String?
    var guest = false
}
