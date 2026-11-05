import Foundation
import Security
import MeetSpaceCore

public enum SecureStoreError: Error, Equatable { case keychain(OSStatus), invalidData }

/// Actor confines Security calls. No broad deletion, sync, logging, or plaintext fallback.
public actor KeychainStore: SecureStore {
    private let service: String
    public init(service: String) { self.service = service }

    private func query(_ key: CredentialKey) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key.storageKey,
         kSecAttrSynchronizable as String: false]
    }

    public func read(_ key: CredentialKey) throws -> Data? {
        var request = query(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecureStoreError.keychain(status) }
        guard let data = value as? Data else { throw SecureStoreError.invalidData }
        return data
    }

    public func write(_ value: Data, for key: CredentialKey) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query(key) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let addStatus = SecItemAdd(query(key).merging(attributes) { _, new in new } as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw SecureStoreError.keychain(addStatus) }
        } else if status != errSecSuccess { throw SecureStoreError.keychain(status) }
    }

    public func delete(_ key: CredentialKey) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecureStoreError.keychain(status) }
    }
}
