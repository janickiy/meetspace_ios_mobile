import Foundation

/// A validated origin, never a URL carrying credentials, a path, or a query.
public struct ServerOrigin: Hashable, Codable, Sendable {
    public let url: URL

    public enum ValidationError: Error, Equatable, Sendable {
        case invalidURL, httpsRequired, originRequired
    }

    public init(_ input: String) throws {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              !value.contains("\\"), !value.contains("%"),
              var parts = URLComponents(string: value), let host = parts.host, !host.isEmpty,
              parts.url != nil else { throw ValidationError.invalidURL }
        guard parts.scheme?.lowercased() == "https" else { throw ValidationError.httpsRequired }
        guard parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else { throw ValidationError.originRequired }
        if let port = parts.port, !(1...65535).contains(port) { throw ValidationError.invalidURL }
        // URLComponents handles IDNA and IPv6. Never silently strip a server subpath.
        parts.scheme = "https"
        parts.host = host.lowercased()
        parts.path = ""
        if parts.port == 443 { parts.port = nil }
        guard let normalized = parts.url else { throw ValidationError.invalidURL }
        url = normalized
    }

    public init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(url.absoluteString)
    }

    public var displayName: String { url.host() ?? url.absoluteString }
}
