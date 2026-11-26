import Foundation

/// The current platform contract exposes recording modes, not guessed feature booleans.
/// Decode the complete /capabilities envelope so callers retain its build provenance.
public struct ServerCapabilities: Decodable, Equatable, Sendable {
    public let recordingModes: [String]
    public let buildVersion: String
    /// Сохраняет заявленные сервером режимы записи и версию сборки.
    /// - Parameters:
    ///   - recordingModes: Перечень режимов записи, поддерживаемых сервером.
    ///   - buildVersion: Версия серверной сборки.
    public init(recordingModes: [String], buildVersion: String = "") {
        self.recordingModes = recordingModes; self.buildVersion = buildVersion
    }
    private enum CodingKeys: String, CodingKey { case capabilities, buildVersion }
    private enum FeatureKeys: String, CodingKey { case recordingModes }
    /// Извлекает режимы записи и версию из ответа сервера, проверяя их формат.
    /// - Parameter decoder: Декодер, установленный вызывающей стороной для чтения полей модели.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let features = try values.nestedContainer(keyedBy: FeatureKeys.self, forKey: .capabilities)
        recordingModes = features.contains(.recordingModes) ? try features.decode([String].self, forKey: .recordingModes) : []
        buildVersion = try values.decode(String.self, forKey: .buildVersion)
        guard recordingModes.count <= 32, Set(recordingModes).count == recordingModes.count,
              recordingModes.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.count <= 64 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
              buildVersion.unicodeScalars.count <= 256,
              !buildVersion.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid capabilities"))
        }
    }
}

public enum ProfileValidation {
    /// Проверяет длину и допустимые символы биографии и нормализует переводы строк.
    /// - Parameter input: Введённый пользователем текст биографии.
    public static func bio(_ input: String) throws -> String {
        let value = input.replacingOccurrences(of: "\r\n", with: "\n")
        guard value.unicodeScalars.count <= 1000, !value.unicodeScalars.contains(where: {
            $0.properties.generalCategory == .control && $0 != "\n" && $0 != "\t"
        }) else { throw ClientError.invalidInput }
        return value
    }

    /// Удаляет крайние пробельные символы и проверяет отображаемое имя по правилам сервера.
    ///
    /// Допустимая длина — от 1 до 100 скалярных значений Unicode. Управляющие символы запрещены.
    /// - Parameter input: Предлагаемое отображаемое имя пользователя.
    public static func displayName(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...100).contains(value.unicodeScalars.count),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ClientError.invalidInput
        }
        return value
    }
}

/// A local product decision, independent of server capabilities. Never silently enabled remotely.
public enum IOSFeatureAvailability {
    public static let sshInstallationEnabled = false
}
