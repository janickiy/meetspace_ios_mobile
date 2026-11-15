import Foundation

/// Device-local audio choices. No account or server credentials are stored here.
public struct DeviceAudioPreferences: Codable, Equatable, Sendable {
    public var mutedOnJoin = true
    public var noiseSuppression = true
    public var preferredInputUID: String?
    public var inputGain: Float = 1
    public init() {}
    public func validated() -> Self {
        var value = self
        value.inputGain = inputGain.isFinite ? min(1, max(0, inputGain)) : 1
        if let uid = preferredInputUID, uid.isEmpty || uid.utf8.count > 512 || uid.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) { value.preferredInputUID = nil }
        return value
    }
    public static func load(defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: "meetspace.audio.v1"),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value.validated()
    }
    public func save(defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(validated()) { defaults.set(data, forKey: "meetspace.audio.v1") }
    }
}
