import Foundation
import Security
import MeetSpaceCore

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
    public init(entries: [PushRegistrationEntry] = []) { self.entries = entries }
    public func validated() throws -> Self {
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
}

public actor MemoryPushRegistrationStore: PushRegistrationStore {
    private var value: PushRegistrationJournal
    public init(_ value: PushRegistrationJournal = PushRegistrationJournal()) { self.value = value }
    public func load() throws -> PushRegistrationJournal { try value.validated() }
    public func save(_ journal: PushRegistrationJournal) throws { value = try journal.validated() }
}

/// A distinct Keychain item survives logout. No tokens, sync, broad deletion or plaintext fallback.
public actor KeychainPushRegistrationStore: PushRegistrationStore {
    private let service: String
    private let account: String
    public init(service: String = "com.meetspace.ios.push-registration", account: String = "global-journal-v1") {
        self.service = service; self.account = account
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
    public func load() throws -> PushRegistrationJournal {
        var request = query
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return PushRegistrationJournal() }
        guard status == errSecSuccess else { throw SecureStoreError.keychain(status) }
        guard let data = result as? Data else { throw SecureStoreError.invalidData }
        return try WireJSON.decoder().decode(PushRegistrationJournal.self, from: data).validated()
    }
    public func save(_ journal: PushRegistrationJournal) throws {
        let attributes: [String: Any] = [kSecValueData as String: try WireJSON.encoder().encode(journal.validated()),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let added = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            guard added == errSecSuccess else { throw SecureStoreError.keychain(added) }
        } else if status != errSecSuccess { throw SecureStoreError.keychain(status) }
    }
}
