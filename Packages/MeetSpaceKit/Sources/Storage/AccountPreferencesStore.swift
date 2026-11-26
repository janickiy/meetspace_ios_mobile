import Foundation
import MeetSpaceCore

public actor AccountPreferencesStore: AccountIndexStore {
    private let defaults: UserDefaults
    private let key = "meetspace.accounts.v1"
    /// Открывает настройки устройства для хранения индекса аккаунтов.
    /// - Parameter suiteName: Имя набора UserDefaults или nil для стандартных настроек приложения.
    public init(suiteName: String? = nil) { defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }
    /// Загружает индекс аккаунтов и текущий выбор пользователя.
    public func load() throws -> AccountIndex {
        guard let data = defaults.data(forKey: key) else { return AccountIndex() }
        return try WireJSON.decoder().decode(AccountIndex.self, from: data).validated()
    }
    /// Сохраняет проверенный индекс аккаунтов устройства.
    /// - Parameter index: Индекс аккаунтов с текущим выбором пользователя.
    public func save(_ index: AccountIndex) throws {
        defaults.set(try WireJSON.encoder().encode(index.validated()), forKey: key)
    }
}

public actor MemoryAccountIndexStore: AccountIndexStore {
    private var value = AccountIndex()
    /// Создаёт пустое хранилище индекса аккаунтов в памяти.
    public init() {}
    /// Загружает индекс аккаунтов и текущий выбор пользователя.
    public func load() -> AccountIndex { value }
    /// Сохраняет проверенный индекс аккаунтов устройства.
    /// - Parameter index: Индекс аккаунтов с текущим выбором пользователя.
    public func save(_ index: AccountIndex) throws { value = try index.validated() }
}
