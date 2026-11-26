import Foundation
import Crypto

public enum InstallerFailure: Error, LocalizedError, Equatable {
    case invalid(String), hostChanged, network, response, expired
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .hostChanged: "Ключ SSH-сервера изменился. Подключение заблокировано. Сравните отпечаток с администратором."
        case .network: "Связь прервана. Состояние сервера неизвестно. Подключитесь снова для проверки."
        case .response: "Ответ установщика не прошёл проверку. Состояние сервера неизвестно; восстановите наблюдение."
        case .expired: "План устарел. Получите новый план перед установкой."
        }
    }
}
public struct InstallerEndpoint: Codable, Sendable, Equatable {
    public let host: String
    public let port: Int
    public let user: String
    /// Проверяет адрес SSH-хоста, порт и имя пользователя для подключения.
    /// - Parameters:
    ///   - host: Имя или IP-адрес SSH-сервера.
    ///   - port: Порт подключения по SSH.
    ///   - user: Имя пользователя SSH для подключения к серверу.
    public init(host: String, port: Int = 22, user: String = "root") throws {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty, host.count <= 253, host.range(of: "^[a-z0-9][a-z0-9.:-]*$", options: .regularExpression) != nil,
              (1...65535).contains(port), user.range(of: "^[a-zA-Z_][a-zA-Z0-9_.-]{0,63}$", options: .regularExpression) != nil else {
            throw InstallerFailure.invalid("Проверьте адрес VPS, SSH-порт и имя пользователя.")
        }
        self.host = host; self.port = port; self.user = user
    }
    public var pinID: String { "\(host):\(port)" }
}
public struct InstallerHostKey: Codable, Sendable, Equatable {
    public let openSSH: String
    public let fingerprint: String
    /// Извлекает публичный ключ OpenSSH и вычисляет его отпечаток SHA-256.
    /// - Parameter openSSH: Публичный ключ сервера в текстовом формате OpenSSH.
    public init(openSSH: String) throws {
        let parts = openSSH.split(separator: " ")
        guard parts.count >= 2, let raw = Data(base64Encoded: String(parts[1])), raw.count <= 16384 else { throw InstallerFailure.response }
        self.openSSH = String(parts[0]) + " " + String(parts[1])
        self.fingerprint = "SHA256:" + Data(SHA256.hash(data: raw)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
}
public enum InstallerCredentials: Sendable {
    case password(String)
    case privateKey(String, passphrase: String)
}
public struct InstallerOptions: Codable, Sendable, Equatable {
    public struct Admin: Codable, Sendable, Equatable {
        public var username = "admin"; public var httpsPort = 8081;

        /// Задаёт имя администратора и порт панели управления по умолчанию.
        public init() {}
    }
    public struct SMTP: Codable, Sendable, Equatable {
        public var host = ""; public var port = 587; public var from = ""; public var username = ""; public var tlsMode = "starttls"
        /// Задаёт начальные параметры SMTP с использованием STARTTLS.
        public init() {}
    }
    public var domain = ""
    public var publicIpv4 = ""
    public var acmeEmail = ""
    public var imageMode = "source"
    public var imageRelease: String? = nil
    public var admin = Admin()
    public var smtp: SMTP? = nil
    /// Создаёт настройки новой установки со значениями по умолчанию.
    public init() {}
    /// Проверяет параметры развёртывания и нормализует домен и режим поставки.
    public func validated() throws -> InstallerOptions {
        var result = self
        let input = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: input.hasPrefix("https://") ? input : "https://" + input),
              url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil, ["", "/"].contains(url.path), let host = url.host,
              host.contains("."), !host.allSatisfy({ $0.isNumber || $0 == "." }),
              host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ $0.range(of: "^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$", options: .regularExpression) != nil }) else {
            throw InstallerFailure.invalid("Укажите полное доменное имя MeetSpace без пути и порта.")
        }
        result.domain = host.lowercased()
        let octets = publicIpv4.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets.allSatisfy({ Int($0).map { (0...255).contains($0) } == true }),
              ["source", "images"].contains(imageMode), admin.username.range(of: "^[a-z0-9][a-z0-9.@+_-]{2,39}$", options: .regularExpression) != nil,
              (1024...65535).contains(admin.httpsPort), ![8082,3478,5349,50010].contains(admin.httpsPort), !(49160...49259).contains(admin.httpsPort) else {
            throw InstallerFailure.invalid("Проверьте публичный IPv4, логин и HTTPS-порт администратора.")
        }
        guard acmeEmail.isEmpty || (acmeEmail.utf8.count <= 254 && acmeEmail.range(of: "^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,63}$", options: .regularExpression) != nil) else {
            throw InstallerFailure.invalid("Проверьте email для сертификата.")
        }
        result.imageRelease = imageMode == "images" ? "latest" : nil
        if let smtp {
            guard !smtp.host.isEmpty, smtp.host.count <= 253, smtp.host.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil,
                  (1...65535).contains(smtp.port), smtp.from.contains("@"), !smtp.username.isEmpty,
                  ["tls", "starttls"].contains(smtp.tlsMode), !smtp.username.contains(where: { $0.isNewline || $0 == "\0" }) else {
                throw InstallerFailure.invalid("Проверьте настройки SMTP.")
            }
        }
        return result
    }
    /// Проверяет, подходит ли пароль администратора для передачи установщику.
    /// - Parameter password: Пароль создаваемого администратора MeetSpace.
    public static func validAdminPassword(_ password: String) -> Bool {
        (8...128).contains(password.unicodeScalars.count) && password.utf8.count <= 512 && !password.contains(where: { $0 == "\0" || $0 == "\r" || $0 == "\n" })
    }
}
public struct InstallerPlan: Codable, Sendable, Equatable {
    public let json: Data
    public let hash: String
    public let commit: String
    public let version: String
    public let architecture: String
    public let resourceProfile: String
    public let requiresDocker: Bool
    public let expiresAt: Date
    public let options: InstallerOptions
    public let existingJobID: String?
    public let existingPlanHash: String?
}
public struct InstallerTicket: Codable, Sendable, Equatable {
    public let endpoint: InstallerEndpoint
    public let key: InstallerHostKey
    public let plan: InstallerPlan
    public let jobID: String
    /// Связывает проверенный план с SSH-сервером, его ключом и идентификатором задания.
    /// - Parameters:
    ///   - endpoint: Адрес, порт и имя пользователя SSH-сервера.
    ///   - key: Публичный ключ SSH-сервера, которому доверяет пользователь.
    ///   - plan: Проверенный план установки.
    ///   - jobID: Идентификатор задания, используемый при восстановлении установки.
    public init(endpoint: InstallerEndpoint, key: InstallerHostKey, plan: InstallerPlan, jobID: String = UUID().uuidString.lowercased()) {
        self.endpoint = endpoint; self.key = key; self.plan = plan; self.jobID = jobID
    }
    public var planHash: String { plan.existingPlanHash ?? plan.hash }
}
public struct InstallerStatus: Sendable, Equatable {
    public let state: String
    public let phase: String
    public let completed: [String]
    public let events: [String]
    public let errorCode: String?
    public var terminal: Bool { ["completed", "cancelled", "failed", "needs_recovery"].contains(state) }
}
public protocol InstallerTransport: Sendable {
    /// Получает публичный SSH-ключ узла для последующей сверки.
    /// - Parameter endpoint: Адрес, порт и имя пользователя SSH-сервера.
    func inspect(_ endpoint: InstallerEndpoint) async throws -> InstallerHostKey
    /// Выполняет программу установки через SSH с проверкой ключа сервера.
    /// - Parameters:
    ///   - endpoint: Адрес, порт и имя пользователя SSH-сервера.
    ///   - credentials: Данные доступа к SSH-серверу.
    ///   - key: Публичный ключ SSH-сервера, которому доверяет пользователь.
    ///   - input: Программа и входные данные, передаваемые установщику через SSH.
    func execute(_ endpoint: InstallerEndpoint, credentials: InstallerCredentials, key: InstallerHostKey, input: Data) async throws -> Data
}
public let installerPhases = ["docker", "source", "images", "configuration", "dependencies", "backup", "migrations", "https", "services", "readiness"]
