import Foundation
import Observation
import MeetSpaceInstaller

@MainActor @Observable public final class InstallerModel {
    public enum Step: Int { case server, fingerprint, access, preflight, options, plan, progress, complete }
    public var step: Step = .server
    public var host = ""
    public var port = "22"
    public var domain = ""
    public var user = "root"
    public var password = ""
    public var privateKey = ""
    public var passphrase = ""
    public var usePrivateKey = false
    public var options = InstallerOptions()
    public var smtp = InstallerOptions.SMTP()
    public var smtpEnabled = false
    public var adminPassword = ""
    public var adminRepeat = ""
    public var smtpPassword = ""
    public var trustConfirmed = false
    public var planConfirmed = false
    public var dockerConfirmed = false
    public var acmeConfirmed = false
    public private(set) var key: InstallerHostKey?
    public private(set) var keyChanged = false
    public private(set) var facts: [String:String] = [:]
    public private(set) var plan: InstallerPlan?
    public private(set) var ticket: InstallerTicket?
    public private(set) var status: InstallerStatus?
    public private(set) var busy = false
    public private(set) var stale = false
    public var error: String?
    @ObservationIgnored private let repository: InstallerRepository
    @ObservationIgnored private var credentials: InstallerCredentials?
    @ObservationIgnored private var operation: Task<Void,Never>?
    @ObservationIgnored private var poll: Task<Void,Never>?
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var accessExpiry: Date?
    /// Создаёт модель мастера установки с указанным или стандартным репозиторием.
    /// - Parameter repository: Репозиторий установки, используемый для операций SSH и хранения задания.
    public init(repository: InstallerRepository? = nil) {
        if let repository { self.repository = repository; return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uitesting"), ProcessInfo.processInfo.arguments.contains("-installer-fixture"),
           let defaults = UserDefaults(suiteName: "meetspace.installer.ui-fixture") {
            defaults.removePersistentDomain(forName: "meetspace.installer.ui-fixture")
            self.repository = InstallerRepository(transport: InstallerFixtureTransport(), defaults: defaults)
            return
        }
        #endif
        self.repository = InstallerRepository()
    }
    public var stepNumber: Int { switch step { case .server: 1; case .fingerprint: 2; case .access: 3; case .complete: 5; default: 4 } }
    var hasPreviousStep: Bool {
        !busy && ticket == nil && [.fingerprint, .access, .preflight, .options, .plan].contains(step)
    }

    /// Возвращает мастер на предыдущий доступный шаг и сообщает, состоялся ли переход.
    ///
    /// Returning to an editable server or plan invalidates the previous confirmation.
    func goBack() -> Bool {
        guard hasPreviousStep else { return false }
        error = nil
        switch step {
        case .fingerprint, .access:
            clearSecrets()
            key = nil
            keyChanged = false
            facts = [:]
            options.publicIpv4 = ""
            trustConfirmed = false
            step = .server
        case .preflight:
            clearSecrets()
            step = .access
        case .options:
            step = .preflight
        case .plan:
            plan = nil
            adminPassword = ""; adminRepeat = ""; smtpPassword = ""
            planConfirmed = false; dockerConfirmed = false; acmeConfirmed = false
            step = .options
        default: return false
        }
        return true
    }
    public var serverURL: String { "https://" + (ticket?.plan.options.domain ?? options.domain) }
    /// Проверяет хост, порт и имя пользователя из формы и создаёт адрес SSH-подключения.
    private func endpoint() throws -> InstallerEndpoint {
        guard let number = Int(port) else { throw InstallerFailure.invalid("SSH-порт должен быть числом от 1 до 65535.") }
        return try InstallerEndpoint(host: host, port: number, user: user)
    }
    /// Восстанавливает сохранённое задание установки и связанные с ним параметры мастера.
    public func restore() async {
        do { if let saved = try await repository.pending() {
            ticket = saved; plan = saved.plan; options = saved.plan.options; domain = options.domain
            host = saved.endpoint.host; port = String(saved.endpoint.port); user = saved.endpoint.user; key = saved.key
            stale = true; step = .progress
        } } catch { self.error = "Не удалось прочитать сохранённое задание установки." }
    }
    /// Запускает один шаг установки, управляя индикатором занятости и ошибками.
    /// - Parameter body: Асинхронная операция текущего шага.
    private func run(_ body: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; poll?.cancel(); busy = true; error = nil
        let current = UUID(); epoch = current
        operation = Task { [weak self] in
            do { try await body() }
            catch is CancellationError { }
            catch { if self?.epoch == current { self?.error = error.localizedDescription; self?.stale = self?.ticket != nil } }
            guard let self, epoch == current else { return }; busy = false; operation = nil
        }
    }
    /// Получает ключ SSH-сервера и сравнивает его с сохранённым отпечатком.
    public func inspect() {
        run { [self] in
            let endpoint = try endpoint()
            // Normalize the domain with the same options validator, using a temporary valid IP until diagnostics.
            var candidate = options; candidate.domain = domain; candidate.publicIpv4 = "203.0.113.10"
            domain = try candidate.validated().domain
            let (observed, changed) = try await repository.inspect(endpoint); try Task.checkCancellation()
            key = observed; keyChanged = changed; trustConfirmed = false; step = .fingerprint
        }
    }
    /// Сохраняет доверие к подтверждённому пользователем ключу SSH и переходит к вводу доступа.
    public func trust() {
        guard trustConfirmed, !keyChanged, let key else { return }
        run { [self] in try await repository.trust(key, endpoint: endpoint()); try Task.checkCancellation(); step = .access }
    }
    /// Удаляет сохранённый доверенный ключ и возвращает мастер на шаг выбора сервера.
    public func forgetTrust() {
        run { [self] in try await repository.forgetTrust(endpoint()); try Task.checkCancellation(); key = nil; keyChanged = false; step = .server }
    }
    /// Возвращает действующие учётные данные SSH или требует повторного подтверждения доступа.
    private func access() throws -> InstallerCredentials {
        guard let credentials else { step = .access; throw InstallerFailure.invalid("Подтвердите доступ SSH заново.") }
        // Match Android: idle access/options expire; reviewed plan and recovery retain in-memory access.
        guard ticket != nil || plan != nil || accessExpiry.map({ $0 > Date() }) == true else {
            self.credentials = nil; step = .access
            throw InstallerFailure.invalid("Срок SSH-доступа истёк. Подтвердите доступ заново.")
        }
        return credentials
    }
    /// Проверяет введённые учётные данные SSH и переводит мастер к следующему шагу.
    public func authenticate() {
        run { [self] in
            let endpoint = try endpoint(); guard let key else { throw InstallerFailure.response }
            credentials = usePrivateKey ? .privateKey(privateKey, passphrase: passphrase) : .password(password)
            password = ""; privateKey = ""; passphrase = ""; accessExpiry = Date().addingTimeInterval(600)
            if let ticket {
                status = try await repository.control("status", ticket: ticket, credentials: access()); try Task.checkCancellation()
                stale = false; step = status?.state == "completed" ? .complete : .progress
            } else {
                facts = try await repository.preflight(endpoint, credentials: access(), key: key, domain: domain); try Task.checkCancellation()
                options.domain = domain
                if let ip = facts["dns_domain"]?.split(separator: ",").first, ip.split(separator: ".").count == 4 { options.publicIpv4 = String(ip) }
                else if host.split(separator: ".").count == 4, host.allSatisfy({ $0.isNumber || $0 == "." }) { options.publicIpv4 = host }
                step = .preflight
            }
        }
    }
    /// Запрашивает план установки с выбранными параметрами сервера.
    public func requestPlan() {
        run { [self] in
            guard let key else { throw InstallerFailure.response }
            options.smtp = smtpEnabled ? smtp : nil
            let result = try await repository.plan(endpoint(), credentials: access(), key: key, options: options)
            try Task.checkCancellation(); plan = result; options = result.options
            adminPassword = ""; adminRepeat = ""; smtpPassword = ""; planConfirmed = false; dockerConfirmed = false; acmeConfirmed = false
            if let existing = result.existingJobID {
                let saved = try InstallerTicket(endpoint: endpoint(), key: key, plan: result, jobID: existing)
                try await repository.remember(saved); ticket = saved; stale = true; step = .progress
            } else { step = .plan }
        }
    }
    public var canApply: Bool { !busy && planConfirmed && acmeConfirmed && (plan?.requiresDocker != true || dockerConfirmed) && InstallerOptions.validAdminPassword(adminPassword) && adminPassword == adminRepeat && (options.smtp == nil || !smtpPassword.isEmpty) }
    /// Запускает подтверждённый план и сохраняет данные задания для последующего восстановления.
    public func apply() {
        guard canApply, let plan, let key else { return }
        run { [self] in
            let saved = try InstallerTicket(endpoint: endpoint(), key: key, plan: plan)
            try await repository.remember(saved); ticket = saved; step = .progress; stale = true
            let admin = adminPassword, mail = smtpPassword; adminPassword = ""; adminRepeat = ""; smtpPassword = ""
            status = try await repository.apply(saved, credentials: access(), docker: dockerConfirmed, acme: acmeConfirmed, adminPassword: admin, smtpPassword: mail)
            try Task.checkCancellation(); stale = false; step = status?.state == "completed" ? .complete : .progress
        }
    }
    /// Отправляет управляющую команду для текущего задания и обновляет его состояние.
    /// - Parameter action: Команда управления заданием установки.
    public func control(_ action: String) {
        guard let ticket else { return }
        run { [self] in
            status = try await repository.control(action, ticket: ticket, credentials: access()); try Task.checkCancellation()
            stale = false; step = status?.state == "completed" ? .complete : .progress
        }
    }
    /// Периодически запрашивает статус активного задания, пока открыт шаг выполнения.
    public func observe() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            if step == .progress, !busy, !stale, status?.terminal == false, credentials != nil { control("status") }
        }
    }
    /// Запрашивает новый план и проверяет, успел ли сервер создать задание установки.
    ///
    /// Reconcile an uncertain apply without creating a second job or erasing server data.
    public func refreshMissingPlan() {
        guard let previous = ticket else { return }
        run { [self] in
            let fresh = try await repository.plan(previous.endpoint, credentials: access(), key: previous.key, options: previous.plan.options)
            try Task.checkCancellation()
            if let existing = fresh.existingJobID {
                let recovered = InstallerTicket(endpoint: previous.endpoint, key: previous.key, plan: fresh, jobID: existing)
                try await repository.remember(recovered); ticket = recovered; plan = fresh; stale = true; step = .progress
            } else {
                // Read-only server plan confirmed no managed job. A NEW explicit confirmation is required.
                await repository.forget(); ticket = nil; status = nil; plan = fresh; options = fresh.options
                adminPassword = ""; adminRepeat = ""; smtpPassword = ""
                planConfirmed = false; dockerConfirmed = false; acmeConfirmed = false; stale = false; step = .plan
            }
        }
    }
    /// Возвращает мастер к подтверждению доступа для восстановления соединения.
    public func reconnect() { credentials = nil; error = nil; stale = true; step = .access }
    /// Отменяет локальную операцию, очищает секреты и помечает состояние сохранённого задания для сверки.
    public func cancelLocalOperation() { epoch = UUID(); operation?.cancel(); operation = nil; busy = false; clearSecrets(); stale = ticket != nil }
    /// Прекращает локальную работу мастера и опрос состояния задания.
    public func detach() { cancelLocalOperation(); poll?.cancel(); poll = nil }
    /// Удаляет введённые пароли, приватный ключ и временные данные SSH из модели.
    private func clearSecrets() { credentials = nil; password = ""; privateKey = ""; passphrase = ""; adminPassword = ""; adminRepeat = ""; smtpPassword = ""; accessExpiry = nil }
    /// Убирает сведения о завершённой установке из хранилища и очищает секреты.
    public func forgetCompleted() async { guard status?.state == "completed" else { return }; await repository.forget(); ticket = nil; clearSecrets() }
}
