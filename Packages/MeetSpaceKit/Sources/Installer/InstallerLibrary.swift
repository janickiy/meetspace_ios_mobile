import Foundation

public enum InstallerLibrary {
    public static var licenseText: String {
        guard let url = Bundle.module.url(forResource: "SSH-THIRD-PARTY-NOTICES.txt", withExtension: nil, subdirectory: "Resources"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "SSH component notices unavailable" }
        return text
    }
}
