import Foundation
import MeetSpaceCore

/// Stores only public server origin and appearance. Credentials belong in SecureStore.
public actor PreferencesStore: ConfigurationStore {
    private let defaults: UserDefaults
    private let key = "meetspace.configuration.v1"
    /// Выбирает набор UserDefaults для сохранения конфигурации приложения.
    /// - Parameter suiteName: Имя набора UserDefaults или nil для стандартных настроек приложения.
    public init(suiteName: String? = nil) { defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }
    /// Загружает конфигурацию приложения или исходные значения.
    public func load() throws -> AppConfiguration {
        guard let data = defaults.data(forKey: key) else { return AppConfiguration() }
        return try JSONDecoder().decode(AppConfiguration.self, from: data)
    }
    /// Сохраняет конфигурацию приложения в UserDefaults.
    /// - Parameter configuration: Адрес сервера и настройки оформления для сохранения.
    public func save(_ configuration: AppConfiguration) throws {
        defaults.set(try JSONEncoder().encode(configuration), forKey: key)
    }
}
