import Foundation
import Security
import MeetSpaceCore

/// Authoritative DELETE success for one server/user, never inferred from 401 or a missing session.
/// Contains neither credentials nor a push token. Retained to fence stale account restoration.
public struct PushAccountDeletionConfirmation: Codable, Equatable, Sendable {
    public let origin: ServerOrigin
    public let userID: UUID
    /// Связывает подтверждение удаления аккаунта с его сервером и пользователем.
    /// - Parameters:
    ///   - origin: Базовый HTTPS-адрес сервера MeetSpace.
    ///   - userID: Идентификатор пользователя на выбранном сервере.
    public init(origin: ServerOrigin, userID: UUID) { self.origin = origin; self.userID = userID }

    /// Проверяет уникальность, число и идентификаторы подтверждённых удалений.
    /// - Parameter values: Список сохранённых подтверждений удаления аккаунтов.
    static func validated(_ values: [Self]) throws -> [Self] {
        let keys = values.map { CredentialKey(server: $0.origin, accountID: $0.userID).storageKey }
        // Never evict confirmed scopes to make room: exceeding the bound fails closed.
        guard values.count <= 1000, Set(keys).count == values.count,
              values.allSatisfy({ DirectCall.validID($0.userID) }) else { throw ClientError.storage }
        return values
    }
}

public struct PushRegistrationEntry: Codable, Equatable, Sendable {
    public let origin: ServerOrigin
    public let userID: UUID
    public var deviceIDs: [UUID]
    public var enabled: Bool
    /// Saved before POST. An unknown result must be recovered with this same OS token or remain blocked.
    public var pendingTokenFingerprint: String?
    public var registeredTokenFingerprint: String?
    public var hasBinding: Bool { !deviceIDs.isEmpty || pendingTokenFingerprint != nil }
    /// Создаёт запись состояния регистрации push-устройств для аккаунта.
    /// - Parameters:
    ///   - origin: Базовый HTTPS-адрес сервера MeetSpace.
    ///   - userID: Идентификатор пользователя на выбранном сервере.
    ///   - deviceIDs: Известные серверные идентификаторы устройств этого аккаунта.
    ///   - enabled: Признак включённых уведомлений.
    ///   - pendingTokenFingerprint: Отпечаток токена, который предстоит зарегистрировать.
    ///   - registeredTokenFingerprint: Отпечаток токена, регистрацию которого уже подтвердил сервер.
    public init(origin: ServerOrigin, userID: UUID, deviceIDs: [UUID] = [], enabled: Bool = false,
                pendingTokenFingerprint: String? = nil, registeredTokenFingerprint: String? = nil) {
        self.origin = origin; self.userID = userID; self.deviceIDs = deviceIDs; self.enabled = enabled
        self.pendingTokenFingerprint = pendingTokenFingerprint; self.registeredTokenFingerprint = registeredTokenFingerprint
    }
}

/// Global to this installation, independent of the account index and account credential deletion.
public struct PushRegistrationJournal: Codable, Equatable, Sendable {
    public var entries: [PushRegistrationEntry]
    /// Durable fallback for stores without a separate confirmation item. Ordinary writes retain it.
    public var confirmedDeletions: [PushAccountDeletionConfirmation]
    /// Собирает журнал регистрации устройств и подтверждений удаления аккаунтов.
    /// - Parameters:
    ///   - entries: Записи о регистрации push-устройств по аккаунтам.
    ///   - confirmedDeletions: Локально сохранённые подтверждения удаления аккаунтов.
    public init(entries: [PushRegistrationEntry] = [], confirmedDeletions: [PushAccountDeletionConfirmation] = []) {
        self.entries = entries; self.confirmedDeletions = confirmedDeletions
    }
    private enum CodingKeys: String, CodingKey { case entries, confirmedDeletions }
    /// Восстанавливает журнал, считая список подтверждений пустым в старых записях.
    /// - Parameter decoder: Декодер, установленный вызывающей стороной для чтения полей модели.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        entries = try values.decode([PushRegistrationEntry].self, forKey: .entries)
        confirmedDeletions = try values.decodeIfPresent([PushAccountDeletionConfirmation].self, forKey: .confirmedDeletions) ?? []
    }
    /// Проверяет целостность записей, идентификаторов устройств и отпечатков токенов.
    public func validated() throws -> Self {
        _ = try PushAccountDeletionConfirmation.validated(confirmedDeletions)
        let keys = entries.map { CredentialKey(server: $0.origin, accountID: $0.userID).storageKey }
        guard entries.count <= 1000, Set(keys).count == entries.count else { throw ClientError.storage }
        for entry in entries {
            guard DirectCall.validID(entry.userID), entry.deviceIDs.count <= 100,
                  Set(entry.deviceIDs).count == entry.deviceIDs.count, entry.deviceIDs.allSatisfy(DirectCall.validID)
            else { throw ClientError.storage }
            for fingerprint in [entry.pendingTokenFingerprint, entry.registeredTokenFingerprint].compactMap({ $0 }) {
                guard fingerprint.utf8.count == 64, fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
                else { throw ClientError.storage }
            }
        }
        return self
    }
}

public protocol PushRegistrationStore: Sendable {
    /// Возвращает журнал регистрации push-устройств.
    func load() async throws -> PushRegistrationJournal
    /// Сохраняет проверенный журнал регистрации push-устройств.
    /// - Parameter journal: Журнал регистраций и подтверждённых удалений.
    func save(_ journal: PushRegistrationJournal) async throws
    /// Возвращает сохранённые подтверждения удаления аккаунтов.
    func loadDeletionConfirmations() async throws -> [PushAccountDeletionConfirmation]
    /// Сохраняет подтверждение удаления аккаунта без повторной регистрации того же подтверждения.
    /// - Parameter confirmation: Подтверждение удаления аккаунта на указанном сервере.
    func recordDeletionConfirmation(_ confirmation: PushAccountDeletionConfirmation) async throws
}

public extension PushRegistrationStore {
    /// Читает подтверждения удаления аккаунтов из сохранённого журнала push-регистраций.
    ///
    /// Передаёт вызывающему коду ошибки чтения и проверки журнала.
    func loadDeletionConfirmations() async throws -> [PushAccountDeletionConfirmation] {
        try await load().validated().confirmedDeletions
    }
    /// Сохраняет подтверждение удаления аккаунта без повторной регистрации того же подтверждения.
    /// - Parameter confirmation: Подтверждение удаления аккаунта на указанном сервере.
    func recordDeletionConfirmation(_ confirmation: PushAccountDeletionConfirmation) async throws {
        var next = try await load().validated()
        if !next.confirmedDeletions.contains(confirmation) { next.confirmedDeletions.append(confirmation) }
        try await save(next.validated())
    }
}

public actor MemoryPushRegistrationStore: PushRegistrationStore {
    private var value: PushRegistrationJournal
    /// Создаёт хранилище push-регистраций в памяти с исходным журналом.
    /// - Parameter value: Начальный журнал для хранилища в памяти.
    public init(_ value: PushRegistrationJournal = PushRegistrationJournal()) { self.value = value }
    /// Возвращает журнал регистрации push-устройств.
    public func load() throws -> PushRegistrationJournal { try value.validated() }
    /// Сохраняет проверенный журнал регистрации push-устройств.
    /// - Parameter journal: Журнал регистраций и подтверждённых удалений.
    public func save(_ journal: PushRegistrationJournal) throws {
        var next = journal
        for confirmation in value.confirmedDeletions where !next.confirmedDeletions.contains(confirmation) {
            next.confirmedDeletions.append(confirmation)
        }
        value = try next.validated()
    }
}

/// A distinct Keychain item survives logout. No tokens, sync, broad deletion or plaintext fallback.
public actor KeychainPushRegistrationStore: PushRegistrationStore {
    private let service: String
    private let account: String
    /// Выбирает сервис и запись Keychain для журнала push-регистраций.
    /// - Parameters:
    ///   - service: Имя сервиса, которым помечены записи в Keychain.
    ///   - account: Имя записи в выбранном сервисе Keychain.
    public init(service: String = "com.meetspace.ios.push-registration", account: String = "global-journal-v1") {
        self.service = service; self.account = account
    }
    /// Формирует атрибуты поиска записи журнала или подтверждений в Keychain.
    /// - Parameter account: Имя записи в выбранном сервисе Keychain.
    private func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
    /// Возвращает данные выбранной записи Keychain, если она существует.
    /// - Parameter account: Имя записи в выбранном сервисе Keychain.
    private func read(account: String) throws -> Data? {
        var request = query(account: account)
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecureStoreError.keychain(status) }
        guard let data = result as? Data else { throw SecureStoreError.invalidData }
        return data
    }
    /// Обновляет данные выбранной записи Keychain или создаёт новую запись.
    /// - Parameters:
    ///   - data: Сериализованные данные журнала или подтверждений.
    ///   - account: Имя записи в выбранном сервисе Keychain.
    private func write(_ data: Data, account: String) throws {
        let query = query(account: account)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let added = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            guard added == errSecSuccess else { throw SecureStoreError.keychain(added) }
        } else if status != errSecSuccess { throw SecureStoreError.keychain(status) }
    }
    /// Возвращает журнал регистрации push-устройств.
    public func load() throws -> PushRegistrationJournal {
        guard let data = try read(account: account) else { return PushRegistrationJournal() }
        return try WireJSON.decoder().decode(PushRegistrationJournal.self, from: data).validated()
    }
    /// Сохраняет проверенный журнал регистрации push-устройств.
    /// - Parameter journal: Журнал регистраций и подтверждённых удалений.
    public func save(_ journal: PushRegistrationJournal) throws {
        try write(WireJSON.encoder().encode(journal.validated()), account: account)
    }
    /// Читает и проверяет отдельный список подтверждённых удалений аккаунтов.
    private func readDeletionConfirmations() throws -> [PushAccountDeletionConfirmation] {
        // Independent of the cleanup journal: corrupt/unavailable journal data must not hide
        // durable proof from Identity's exact-scope restoration guard.
        guard let data = try read(account: account + "-confirmed-deletions-v1") else { return [] }
        return try PushAccountDeletionConfirmation.validated(
            WireJSON.decoder().decode([PushAccountDeletionConfirmation].self, from: data))
    }
    /// Возвращает сохранённые подтверждения удаления аккаунтов.
    public func loadDeletionConfirmations() async throws -> [PushAccountDeletionConfirmation] {
        try readDeletionConfirmations()
    }
    /// Сохраняет подтверждение удаления аккаунта без повторной регистрации того же подтверждения.
    /// - Parameter confirmation: Подтверждение удаления аккаунта на указанном сервере.
    public func recordDeletionConfirmation(_ confirmation: PushAccountDeletionConfirmation) async throws {
        // Keep the read/modify/write synchronous inside this actor. Explicit async public
        // methods also prevent concrete callers from selecting the protocol's fallback.
        var next = try readDeletionConfirmations()
        if !next.contains(confirmation) { next.append(confirmation) }
        try write(WireJSON.encoder().encode(PushAccountDeletionConfirmation.validated(next)),
                  account: account + "-confirmed-deletions-v1")
    }
}
