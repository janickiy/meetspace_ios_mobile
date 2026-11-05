import Foundation

public enum ClientError: Error, Equatable, Sendable {
    case invalidInput, accountLimit, missingSession, sessionExpired, accountMismatch, storage
    case invalidFileName, unsupportedFile, fileTooLarge, scopeMismatch
}

public struct AccountUser: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let email: String
    public let displayName: String?
    public let isAdmin: Bool
    public let guestConferenceId: UUID?
    public let avatarVersion: String?
    public let createdAt: Date
    public let updatedAt: Date
    public var name: String { displayName.flatMap { $0.isEmpty ? nil : $0 } ?? email }
}

public struct AccountRecord: Codable, Equatable, Sendable, Identifiable {
    public let server: ServerOrigin
    public var user: AccountUser
    public var id: String { key.storageKey }
    public var key: CredentialKey { CredentialKey(server: server, accountID: user.id) }
    public init(server: ServerOrigin, user: AccountUser) { self.server = server; self.user = user }
}

/// Only public metadata belongs in the account index. Secrets never enter this type.
public struct AccountIndex: Codable, Equatable, Sendable {
    public var accounts: [AccountRecord]
    public var activeID: String?
    public init(accounts: [AccountRecord] = [], activeID: String? = nil) {
        self.accounts = accounts; self.activeID = activeID
    }
    public mutating func upsert(_ account: AccountRecord) throws {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) { accounts[index] = account }
        else {
            guard accounts.filter({ $0.server == account.server }).count < 5 else { throw ClientError.accountLimit }
            accounts.append(account)
        }
        activeID = account.id
    }
    public mutating func remove(_ id: String) {
        accounts.removeAll { $0.id == id }
        if activeID == id { activeID = nil }
    }
    public func validated() throws -> Self {
        guard Set(accounts.map(\.id)).count == accounts.count,
              accounts.allSatisfy({ $0.user.guestConferenceId == nil && $0.user.email.utf8.count <= 254 }),
              Dictionary(grouping: accounts, by: { $0.server }).values.allSatisfy({ $0.count <= 5 }),
              activeID == nil || accounts.contains(where: { $0.id == activeID }) else { throw ClientError.storage }
        return self
    }
}

public protocol AccountIndexStore: Sendable {
    func load() async throws -> AccountIndex
    func save(_ index: AccountIndex) async throws
}

/// Keychain payload. Do not add CustomStringConvertible or include this type in logs.
public struct SessionCredentials: Codable, Sendable {
    public let accessToken: String
    public let sessionCookie: String?
    public let expiresAt: Date
    public init(accessToken: String, sessionCookie: String?, expiresAt: Date) {
        self.accessToken = accessToken; self.sessionCookie = sessionCookie; self.expiresAt = expiresAt
    }
    public func validated() throws -> Self {
        guard !accessToken.isEmpty, accessToken.utf8.count <= 16_384,
              !accessToken.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              sessionCookie.map({ !$0.isEmpty && $0.utf8.count <= 4096 && $0.utf8.allSatisfy {
                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
              } }) ?? true else { throw ClientError.missingSession }
        return self
    }
}

public enum WireJSON {
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: raw) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid timestamp"))
            }
            return date
        }
        return decoder
    }
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

public enum AccountValidation {
    public static func email(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, value.utf8.count <= 254,
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) })
        else { throw ClientError.invalidInput }
        return value
    }
    public static func registration(email: String, password: String, name: String) throws {
        _ = try self.email(email)
        let count = password.unicodeScalars.count // Backend counts Go runes, not grapheme clusters.
        guard (8...128).contains(count), name.unicodeScalars.count <= 100,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw ClientError.invalidInput }
    }
}
