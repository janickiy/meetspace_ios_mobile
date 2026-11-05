import Foundation
import MeetSpaceCore

public actor AccountPreferencesStore: AccountIndexStore {
    private let defaults: UserDefaults
    private let key = "meetspace.accounts.v1"
    public init(suiteName: String? = nil) { defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }
    public func load() throws -> AccountIndex {
        guard let data = defaults.data(forKey: key) else { return AccountIndex() }
        return try WireJSON.decoder().decode(AccountIndex.self, from: data).validated()
    }
    public func save(_ index: AccountIndex) throws {
        defaults.set(try WireJSON.encoder().encode(index.validated()), forKey: key)
    }
}

public actor MemoryAccountIndexStore: AccountIndexStore {
    private var value = AccountIndex()
    public init() {}
    public func load() -> AccountIndex { value }
    public func save(_ index: AccountIndex) throws { value = try index.validated() }
}
