import Foundation
import Security
import XCTest
import MeetSpaceCore
import MeetSpaceStorage

@MainActor final class Stage08SecurityKeychainTests: XCTestCase {
    func testCredentialsRemainDeviceOnlyAndUnsynchronizedAfterUpdate() async throws {
        let service = "com.meetspace.ios.tests.security.\(UUID().uuidString)"
        let key = CredentialKey(server: try ServerOrigin("https://keychain.fixture"), accountID: UUID())
        let store = KeychainStore(service: service)
        defer { removeFixture(service: service, account: key.storageKey) }
        try await store.write(Data("first-fixture".utf8), for: key)
        try assertProtection(service: service, account: key.storageKey)
        try await store.write(Data("updated-fixture".utf8), for: key)
        try assertProtection(service: service, account: key.storageKey)
    }

    func testPushCleanupJournalUsesTheSameDeviceOnlyProtection() async throws {
        let service = "com.meetspace.ios.tests.push-security.\(UUID().uuidString)", account = "fixture-journal"
        let store = KeychainPushRegistrationStore(service: service, account: account)
        defer { removeFixture(service: service, account: account) }
        try await store.save(PushRegistrationJournal())
        try assertProtection(service: service, account: account)
        try await store.save(PushRegistrationJournal())
        try assertProtection(service: service, account: account)
    }

    func testDeletionConfirmationSurvivesJournalRewriteWithDeviceOnlyProtection() async throws {
        let service = "com.meetspace.ios.tests.deletion-security.\(UUID().uuidString)", account = "fixture-journal"
        let ledgerAccount = account + "-confirmed-deletions-v1"
        let store = KeychainPushRegistrationStore(service: service, account: account)
        defer {
            removeFixture(service: service, account: account)
            removeFixture(service: service, account: ledgerAccount)
        }
        let origin = try ServerOrigin("https://deletion-keychain.fixture"), userID = UUID()
        let confirmed = PushAccountDeletionConfirmation(origin: origin, userID: userID)
        try await store.recordDeletionConfirmation(confirmed)
        try assertProtection(service: service, account: ledgerAccount)
        // Real SecItemUpdate, plus an unrelated journal rewrite, must preserve the proof.
        try await store.recordDeletionConfirmation(confirmed)
        try await store.save(PushRegistrationJournal())
        try assertProtection(service: service, account: ledgerAccount)
        let reopened = KeychainPushRegistrationStore(service: service, account: account)
        let confirmations = try await reopened.loadDeletionConfirmations()
        let journal = try await reopened.load()
        XCTAssertEqual(confirmations, [confirmed])
        XCTAssertTrue(journal.entries.isEmpty)
    }

    private func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: kSecAttrSynchronizableAny]
    }
    private func assertProtection(service: String, account: String, file: StaticString = #filePath, line: UInt = #line) throws {
        var query = query(service: service, account: account)
        query[kSecReturnAttributes as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        XCTAssertEqual(status, errSecSuccess, file: file, line: line)
        let attributes = try XCTUnwrap(result as? [String: Any], file: file, line: line)
        // Attributes only: no secret payload is requested or printed by the assertions.
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String, file: file, line: line)
        XCTAssertEqual(attributes[kSecAttrSynchronizable as String] as? Bool, false, file: file, line: line)
    }
    private func removeFixture(service: String, account: String) {
        SecItemDelete(query(service: service, account: account) as CFDictionary)
    }
}
