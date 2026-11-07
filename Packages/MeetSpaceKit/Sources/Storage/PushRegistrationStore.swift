import Foundation
import Security
import MeetSpaceCore

/// Authoritative DELETE success for one server/user, never inferred from 401 or a missing session.
/// Contains neither credentials nor a push token. Retained to fence stale account restoration.
public struct PushAccountDeletionConfirmation: Codable, Equatable, Sendable {
    public let origin: ServerOrigin
    public let userID: UUID
    public init(origin: ServerOrigin, userID: UUID) { self.origin = origin; self.userID = userID }

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
    public init(entries: [PushRegistrationEntry] = [], confirmedDeletions: [PushAccountDeletionConfirmation] = []) {
        self.entries = entries; self.confirmedDeletions = confirmedDeletions
    }
    private enum CodingKeys: String, CodingKey { case entries, confirmedDeletions }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        entries = try values.decode([PushRegistrationEntry].self, forKey: .entries)
        confirmedDeletions = try values.decodeIfPresent([PushAccountDeletionConfirmation].self, forKey: .confirmedDeletions) ?? []
    }
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
    func load() async throws -> PushRegistrationJournal
    func save(_ journal: PushRegistrationJournal) async throws
    func loadDeletionConfirmations() async throws -> [PushAccountDeletionConfirmation]
    func recordDeletionConfirmation(_ confirmation: PushAccountDeletionConfirmation) async throws
}

public extension PushRegistrationStore {
    /// A real, throwing journal-backed implementation for existing stores, not a no-op receipt.
    func loadDeletionConfirmations() async throws -> [PushAccountDeletionConfirmation] {
        try await load().validated().confirmedDeletions
    }
    func recordDeletionConfirmation(_ confirmation: PushAccountDeletionConfirmation) async throws {
        var next = try await load().validated()
        if !next.confirmedDeletions.contains(confirmation) { next.confirmedDeletions.append(confirmation) }
        try await save(next.validated())
    }
}

public actor MemoryPushRegistrationStore: PushRegistrationStore {
    private var value: PushRegistrationJournal
    public init(_ value: PushRegistrationJournal = PushRegistrationJournal()) { self.value = value }
    public func load() throws -> PushRegistrationJournal { try value.validated() }
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
    public init(service: String = "com.meetspace.ios.push-registration", account: String = "global-journal-v1") {
        self.service = service; self.account = account
    }
    private func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
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
    public func load() throws -> PushRegistrationJournal {
        guard let data = try read(account: account) else { return PushRegistrationJournal() }
        return try WireJSON.decoder().decode(PushRegistrationJournal.self, from: data).validated()
    }
    public func save(_ journal: PushRegistrationJournal) throws {
        try write(WireJSON.encoder().encode(journal.validated()), account: account)
    }
    private func readDeletionConfirmations() throws -> [PushAccountDeletionConfirmation] {
        // Independent of the cleanup journal: corrupt/unavailable journal data must not hide
        // durable proof from Identity's exact-scope restoration guard.
        guard let data = try read(account: account + "-confirmed-deletions-v1") else { return [] }
        return try PushAccountDeletionConfirmation.validated(
            WireJSON.decoder().decode([PushAccountDeletionConfirmation].self, from: data))
    }
    public func loadDeletionConfirmations() async throws -> [PushAccountDeletionConfirmation] {
        try readDeletionConfirmations()
    }
    public func recordDeletionConfirmation(_ confirmation: PushAccountDeletionConfirmation) async throws {
        // Keep the read/modify/write synchronous inside this actor. Explicit async public
        // methods also prevent concrete callers from selecting the protocol's fallback.
        var next = try readDeletionConfirmations()
        if !next.contains(confirmation) { next.append(confirmation) }
        try write(WireJSON.encoder().encode(PushAccountDeletionConfirmation.validated(next)),
                  account: account + "-confirmed-deletions-v1")
    }
}
