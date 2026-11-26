import Foundation
import Crypto
import Security

public actor InstallerRepository {
    private let transport: any InstallerTransport
    private let defaults: UserDefaults
    private let storageKey = "meetspace.installer.public-ticket.v1"
    private let pinsKey = "meetspace.installer.host-pins.v1"
    /// Создаёт клиент установки с SSH-транспортом и хранилищем доверия и заданий.
    /// - Parameters:
    ///   - transport: Транспорт для проверки SSH-ключа и выполнения программы на сервере.
    ///   - defaults: Хранилище локальных настроек устройства.
    public init(transport: any InstallerTransport = NativeInstallerTransport(), defaults: UserDefaults = .standard) {
        self.transport = transport; self.defaults = defaults
    }
    /// Получает ключ SSH-сервера и проверяет его по ранее сохранённому ключу.
    /// - Parameter endpoint: Адрес, порт и имя пользователя SSH-сервера.
    public func inspect(_ endpoint: InstallerEndpoint) async throws -> (InstallerHostKey, Bool) {
        let actual = try await transport.inspect(endpoint)
        let saved = defaults.dictionary(forKey: pinsKey)?[endpoint.pinID] as? String
        return (actual, saved != nil && saved != actual.openSSH)
    }
    /// Запоминает подтверждённый ключ SSH для указанного хоста и порта.
    /// - Parameters:
    ///   - key: Публичный ключ SSH-сервера, которому доверяет пользователь.
    ///   - endpoint: Адрес, порт и имя пользователя SSH-сервера.
    public func trust(_ key: InstallerHostKey, endpoint: InstallerEndpoint) {
        var pins = defaults.dictionary(forKey: pinsKey) ?? [:]; pins[endpoint.pinID] = key.openSSH; defaults.set(pins, forKey: pinsKey)
    }
    /// Удаляет сохранённое доверие к SSH-серверу.
    /// - Parameter endpoint: Адрес, порт и имя пользователя SSH-сервера.
    public func forgetTrust(_ endpoint: InstallerEndpoint) {
        var pins = defaults.dictionary(forKey: pinsKey) ?? [:]; pins.removeValue(forKey: endpoint.pinID); defaults.set(pins, forKey: pinsKey)
    }
    /// Восстанавливает сохранённое задание и проверяет целостность его плана.
    public func pending() throws -> InstallerTicket? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        guard data.count <= 300 * 1024 else { throw InstallerFailure.response }
        let value = try JSONDecoder().decode(InstallerTicket.self, from: data)
        let verified = try InstallerBundle().parsePlan(value.plan.json)
        guard value.plan == verified, UUID(uuidString: value.jobID) != nil else { throw InstallerFailure.response }
        return value
    }
    /// Сохраняет данные задания для восстановления наблюдения за установкой.
    /// - Parameter ticket: Сохранённые данные подключения, плана и идентификатора задания.
    public func remember(_ ticket: InstallerTicket) throws { defaults.set(try JSONEncoder().encode(ticket), forKey: storageKey) }
    /// Удаляет локальные данные последнего задания установки.
    public func forget() { defaults.removeObject(forKey: storageKey) }
    /// Передаёт программу SSH-транспорту после сверки ключа сервера.
    /// - Parameters:
    ///   - endpoint: Адрес, порт и имя пользователя SSH-сервера.
    ///   - credentials: Данные доступа к SSH-серверу.
    ///   - key: Публичный ключ SSH-сервера, которому доверяет пользователь.
    ///   - input: Программа и входные данные, передаваемые установщику через SSH.
    private func execute(_ endpoint: InstallerEndpoint, credentials: InstallerCredentials, key: InstallerHostKey, input: Data) async throws -> Data {
        guard defaults.dictionary(forKey: pinsKey)?[endpoint.pinID] as? String == key.openSSH else { throw InstallerFailure.hostChanged }
        return try await transport.execute(endpoint, credentials: credentials, key: key, input: input)
    }
    /// Выполняет предварительные проверки сервера и разбирает полученные результаты.
    /// - Parameters:
    ///   - endpoint: Адрес, порт и имя пользователя SSH-сервера.
    ///   - credentials: Данные доступа к SSH-серверу.
    ///   - key: Публичный ключ SSH-сервера, которому доверяет пользователь.
    ///   - domain: Доменное имя развёртываемого сервера MeetSpace.
    public func preflight(_ endpoint: InstallerEndpoint, credentials: InstallerCredentials, key: InstallerHostKey, domain: String) async throws -> [String:String] {
        let script = try resource("preflight.sh")
        let args = try canonical(["domain":domain,"host":endpoint.host])
        let input = Data("import base64,json,subprocess\na=json.loads(base64.b64decode('\(args.base64EncodedString())'))\nr=subprocess.run(['sh','-s','--',a['domain'],a['host']],input=base64.b64decode('\(script.base64EncodedString())'),stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=90)\n__import__('sys').stdout.write(r.stdout.decode())\n".utf8)
        let output = try await execute(endpoint, credentials: credentials, key: key, input: input)
        guard let text = String(data: output, encoding: .utf8) else { throw InstallerFailure.response }
        var values: [String:String] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3, fields[0] == "MSPF1", values[String(fields[1])] == nil else { throw InstallerFailure.response }
            values[String(fields[1])] = String(fields[2])
        }
        guard values["complete"] == "1", values["protocol"] == "1" else { throw InstallerFailure.response }
        return values
    }
    /// Запрашивает план установки и проверяет его соответствие выбранным параметрам.
    /// - Parameters:
    ///   - endpoint: Адрес, порт и имя пользователя SSH-сервера.
    ///   - credentials: Данные доступа к SSH-серверу.
    ///   - key: Публичный ключ SSH-сервера, которому доверяет пользователь.
    ///   - options: Выбранные параметры развёртывания сервера.
    public func plan(_ endpoint: InstallerEndpoint, credentials: InstallerCredentials, key: InstallerHostKey, options: InstallerOptions) async throws -> InstallerPlan {
        let requested = try options.validated()
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(requested))
        let result = try await request("plan", endpoint: endpoint, credentials: credentials, key: key, body: ["options":body])
        let plan = try InstallerBundle().parsePlan(canonical(result))
        guard plan.options == requested else { throw InstallerFailure.response }
        return plan
    }
    /// Запускает подтверждённый план и сохраняет данные для восстановления задания.
    /// - Parameters:
    ///   - ticket: Сохранённые данные подключения, плана и идентификатора задания.
    ///   - credentials: Данные доступа к SSH-серверу.
    ///   - docker: Подтверждение установки компонентов Docker при необходимости.
    ///   - acme: Согласие с условиями выдачи сертификата ACME.
    ///   - adminPassword: Пароль для создаваемой учётной записи администратора.
    ///   - smtpPassword: Пароль SMTP-сервера, если настроена отправка почты.
    public func apply(_ ticket: InstallerTicket, credentials: InstallerCredentials, docker: Bool, acme: Bool, adminPassword: String, smtpPassword: String?) async throws -> InstallerStatus {
        guard ticket.plan.expiresAt > Date() else { throw InstallerFailure.expired }
        guard acme, !ticket.plan.requiresDocker || docker, InstallerOptions.validAdminPassword(adminPassword) else { throw InstallerFailure.invalid("Подтвердите план и проверьте пароль администратора.") }
        var body: [String:Any] = ["plan":try JSONSerialization.jsonObject(with: ticket.plan.json),"jobId":ticket.jobID,"confirmedPlanHash":ticket.plan.hash,"confirmDockerInstall":docker,"acceptAcmeTerms":acme,"adminPassword":adminPassword]
        if ticket.plan.options.smtp != nil {
            guard let password = smtpPassword, !password.isEmpty, password.utf8.count <= 4096, !password.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) else { throw InstallerFailure.invalid("Введите пароль SMTP.") }
            body["smtpPassword"] = password
        }
        // Persist only the public ticket BEFORE the mutation, so lost responses remain recoverable.
        try remember(ticket)
        return try parseStatus(await request("apply", endpoint: ticket.endpoint, credentials: credentials, key: ticket.key, body: body), ticket: ticket)
    }
    /// Запрашивает статус, отмену или продолжение сохранённого задания установки.
    /// - Parameters:
    ///   - action: Команда status, cancel или resume для текущего задания.
    ///   - ticket: Сохранённые данные подключения, плана и идентификатора задания.
    ///   - credentials: Данные доступа к SSH-серверу.
    public func control(_ action: String, ticket: InstallerTicket, credentials: InstallerCredentials) async throws -> InstallerStatus {
        guard ["status","cancel","resume"].contains(action) else { throw InstallerFailure.response }
        var body: [String:Any] = ["jobId":ticket.jobID,"planHash":ticket.planHash]
        if action == "resume" { body["confirmedPlanHash"] = ticket.planHash }
        return try parseStatus(await request(action, endpoint: ticket.endpoint, credentials: credentials, key: ticket.key, body: body), ticket: ticket)
    }
    /// Упаковывает команду установщика, исполняет её и проверяет ответ протокола MSI1.
    /// - Parameters:
    ///   - action: Название запрашиваемого действия.
    ///   - endpoint: Адрес, порт и имя пользователя SSH-сервера.
    ///   - credentials: Данные доступа к SSH-серверу.
    ///   - key: Публичный ключ SSH-сервера, которому доверяет пользователь.
    ///   - body: Словарь полей для команды протокола MSI1.
    private func request(_ action: String, endpoint: InstallerEndpoint, credentials: InstallerCredentials, key: InstallerHostKey, body: [String:Any]) async throws -> [String:Any] {
        let payload = try InstallerBundle().payload(action, body)
        let output = try await execute(endpoint, credentials: credentials, key: key, input: payload)
        let value = try object(output)
        guard value["protocol"] as? String == "MSI1", let ok = value["ok"] as? Bool else { throw InstallerFailure.response }
        if !ok {
            let code = value["errorCode"] as? String ?? "INVALID_RESPONSE"
            guard code.range(of: "^[A-Z_]{1,64}$", options: .regularExpression) != nil else { throw InstallerFailure.response }
            throw InstallerFailure.invalid("Установщик остановлен: \(code). Проверьте параметры или восстановите наблюдение. Данные автоматически не удаляются.")
        }
        guard let result = value["result"] as? [String:Any] else { throw InstallerFailure.response }
        return result
    }
}
func resource(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil) else { throw InstallerFailure.response }
    let data = try Data(contentsOf: url); guard data.count <= 256 * 1024 else { throw InstallerFailure.response }; return data
}
func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func object(_ data: Data) throws -> [String:Any] {
    guard data.count <= 256 * 1024, let value = try JSONSerialization.jsonObject(with: data) as? [String:Any] else { throw InstallerFailure.response }; return value
}
/// The signed Python protocol hashes compact, key-sorted, ASCII JSON (not Foundation slash escaping).
func canonical(_ value: Any) throws -> Data {
    let raw = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
    guard let text = String(data: raw, encoding: .utf8) else { throw InstallerFailure.response }
    return Data(text.utf16.map { $0 > 127 ? String(format: "\\u%04x", $0) : String(UnicodeScalar($0)!) }.joined().utf8)
}
func parseStatus(_ value: [String:Any], ticket: InstallerTicket) throws -> InstallerStatus {
    let states = ["running","cancel_requested","cancelled","needs_recovery","failed","completed"]
    guard value["jobId"] as? String == ticket.jobID, value["planHash"] as? String == ticket.planHash,
          value["commit"] as? String == ticket.plan.commit, value["domain"] as? String == ticket.plan.options.domain,
          let state = value["state"] as? String, states.contains(state), let phase = value["phase"] as? String,
          phase.range(of: "^[a-z:-]{1,64}$", options: .regularExpression) != nil,
          let completed = value["completedPhases"] as? [String], Set(completed).count == completed.count,
          completed.allSatisfy(installerPhases.contains), state != "completed" || completed == installerPhases,
          let events = value["events"] as? [[String:Any]], events.count <= 64 else { throw InstallerFailure.response }
    let code = value["errorCode"] as? String
    guard code == nil || code!.range(of: "^[A-Z_]{1,64}$", options: .regularExpression) != nil else { throw InstallerFailure.response }
    let lines = try events.map { item -> String in
        guard let phase = item["phase"] as? String, phase.range(of: "^[a-z:-]{1,64}$", options: .regularExpression) != nil,
              let state = item["state"] as? String, states.contains(state), let sequence = item["sequence"] as? Int else { throw InstallerFailure.response }
        return "\(sequence). \(phase) · \(state)"
    }
    return InstallerStatus(state: state, phase: phase, completed: completed, events: lines, errorCode: code)
}
