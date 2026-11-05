import Foundation
import XCTest
import MeetSpaceCore
import MeetSpaceStorage

@MainActor final class KeychainIntegrationTests: XCTestCase {
    func testKeychainRoundTripUpdateAndScopedDeletion() async throws {
        let store = KeychainStore(service: "com.meetspace.ios.tests.\(UUID().uuidString)")
        let accountID = UUID()
        let first = CredentialKey(server: try ServerOrigin("https://one.example"), accountID: accountID)
        let other = CredentialKey(server: try ServerOrigin("https://two.example"), accountID: accountID)
        do {
            try await store.write(Data("fixture-one".utf8), for: first)
            try await store.write(Data("fixture-other".utf8), for: other)
            try await store.write(Data("updated".utf8), for: first)
            let value = try await store.read(first)
            XCTAssertEqual(value, Data("updated".utf8))
            try await store.delete(first)
            let removed = try await store.read(first)
            let retained = try await store.read(other)
            XCTAssertNil(removed); XCTAssertEqual(retained, Data("fixture-other".utf8))
            try await store.delete(first) // idempotent; must not remove other accounts.
            try await store.delete(other)
        } catch {
            try? await store.delete(first); try? await store.delete(other)
            throw error
        }
    }
}
