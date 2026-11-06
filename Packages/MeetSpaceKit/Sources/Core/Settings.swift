import Foundation

/// The current platform contract exposes recording modes, not guessed feature booleans.
/// Decode the complete /capabilities envelope so callers retain its build provenance.
public struct ServerCapabilities: Decodable, Equatable, Sendable {
    public let recordingModes: [String]
    public let buildVersion: String
    public init(recordingModes: [String], buildVersion: String = "") {
        self.recordingModes = recordingModes; self.buildVersion = buildVersion
    }
    private enum CodingKeys: String, CodingKey { case capabilities, buildVersion }
    private enum FeatureKeys: String, CodingKey { case recordingModes }
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
    /// Mirrors Go strings.TrimSpace, rune counting, and unicode.IsControl for this field.
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
