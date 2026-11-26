import Foundation

/// Device-local audio choices. No account or server credentials are stored here.
public struct DeviceAudioPreferences: Codable, Equatable, Sendable {
    public var mutedOnJoin = true
    public var noiseSuppression = true
    public var preferredInputUID: String?
    public var inputGain: Float = 1
    public var speakerVolume: Float = 1
    public var signalVolume: Float = 1
    public static let levelsDidChange = Notification.Name("meetspace.audio.levelsDidChange")
    /// Создаёт исходные настройки микрофона, динамика и звуковых сигналов устройства.
    public init() {}

    /// Восстанавливает аудионастройки, подставляя громкость по умолчанию для старых записей.
    /// - Parameter decoder: Декодер, установленный вызывающей стороной для чтения полей модели.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mutedOnJoin = try values.decode(Bool.self, forKey: .mutedOnJoin)
        noiseSuppression = try values.decode(Bool.self, forKey: .noiseSuppression)
        preferredInputUID = try values.decodeIfPresent(String.self, forKey: .preferredInputUID)
        inputGain = try values.decode(Float.self, forKey: .inputGain)
        speakerVolume = try values.decodeIfPresent(Float.self, forKey: .speakerVolume) ?? 1
        signalVolume = try values.decodeIfPresent(Float.self, forKey: .signalVolume) ?? 1
    }

    /// Ограничивает уровни громкости и сбрасывает недопустимый идентификатор аудиовхода.
    public func validated() -> Self {
        var value = self
        func bounded(_ level: Float) -> Float { level.isFinite ? min(1, max(0, level)) : 1 }
        value.inputGain = bounded(inputGain)
        value.speakerVolume = bounded(speakerVolume)
        value.signalVolume = bounded(signalVolume)
        if let uid = preferredInputUID, uid.isEmpty || uid.utf8.count > 512 || uid.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) { value.preferredInputUID = nil }
        return value
    }
    /// Читает и проверяет аудионастройки устройства или возвращает исходные значения.
    /// - Parameter defaults: Хранилище локальных настроек устройства.
    public static func load(defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: "meetspace.audio.v1"),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value.validated()
    }
    /// Сохраняет проверенные настройки громкости и аудиовхода на устройстве.
    /// - Parameter defaults: Хранилище локальных настроек устройства.
    public func save(defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(validated()) { defaults.set(data, forKey: "meetspace.audio.v1") }
    }
}
