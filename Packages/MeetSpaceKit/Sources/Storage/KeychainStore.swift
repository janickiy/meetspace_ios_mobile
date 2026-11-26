import Foundation
import Security
import MeetSpaceCore

public enum SecureStoreError: Error, Equatable { case keychain(OSStatus), invalidData }

/// Actor confines Security calls. No broad deletion, sync, logging, or plaintext fallback.
public actor KeychainStore: SecureStore {
    private let service: String
    /// Выбирает сервис Keychain для защищённых данных аккаунтов.
    /// - Parameter service: Имя сервиса, которым помечены записи в Keychain.
    public init(service: String) { self.service = service }

    /// Формирует атрибуты поиска записи Keychain по серверу и аккаунту.
    /// - Parameter key: Ключ учётных данных, составленный из адреса сервера и идентификатора аккаунта.
    private func query(_ key: CredentialKey) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key.storageKey,
         kSecAttrSynchronizable as String: false]
    }

    /// Читает данные учётной записи из Keychain.
    /// - Parameter key: Ключ учётных данных, составленный из адреса сервера и идентификатора аккаунта.
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

    /// Обновляет данные в Keychain или создаёт новую запись для аккаунта.
    /// - Parameters:
    ///   - value: Байты данных сессии для записи в Keychain.
    ///   - key: Ключ учётных данных, составленный из адреса сервера и идентификатора аккаунта.
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

    /// Удаляет данные учётной записи из Keychain.
    /// - Parameter key: Ключ учётных данных, составленный из адреса сервера и идентификатора аккаунта.
    public func delete(_ key: CredentialKey) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecureStoreError.keychain(status) }
    }
}
