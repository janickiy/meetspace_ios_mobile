import Foundation
import MeetSpaceCore

public struct ServerVersion: Codable, Equatable, Sendable {
    public let version: String
    public let commit: String
    public let buildTime: String
    public init(version: String, commit: String, buildTime: String) {
        self.version = version; self.commit = commit; self.buildTime = buildTime
    }
}

public enum APIError: Error, Equatable, Sendable {
    case offline, timeout, tls, invalidResponse, redirect, httpStatus(Int), responseTooLarge
}

public protocol ServerProbing: Sendable {
    func check(_ origin: ServerOrigin) async throws -> ServerVersion
}

public struct HTTPResponse: Sendable {
    public let status: Int
    public let contentType: String?
    public let data: Data
    public init(status: Int, contentType: String?, data: Data) {
        self.status = status; self.contentType = contentType; self.data = data
    }
}

public protocol HTTPTransport: Sendable {
    func get(_ url: URL) async throws -> HTTPResponse
}

public struct ServerProbe: ServerProbing {
    private let transport: any HTTPTransport
    public init(transport: any HTTPTransport = URLSessionTransport()) { self.transport = transport }

    public func check(_ origin: ServerOrigin) async throws -> ServerVersion {
        // Audited backend: GET /version; no /api/v1 prefix, no bearer or cookies.
        let response = try await transport.get(origin.url.appendingPathComponent("version"))
        guard !(300...399).contains(response.status) else { throw APIError.redirect }
        guard response.status == 200 else { throw APIError.httpStatus(response.status) }
        guard response.data.count <= URLSessionTransport.maximumResponseBytes else { throw APIError.responseTooLarge }
        guard response.contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json",
              let value = try? JSONDecoder().decode(ServerVersion.self, from: response.data),
              !value.version.isEmpty else { throw APIError.invalidResponse }
        return value
    }
}

private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil) // A new origin must be explicitly entered and checked by the user.
    }
}

public final class URLSessionTransport: HTTPTransport, Sendable {
    public static let maximumResponseBytes = 131_072
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        // No trust callbacks, custom certificates, or ATS exceptions: system TLS validation.
        session = URLSession(configuration: configuration, delegate: RedirectPolicy(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func get(_ url: URL) async throws -> HTTPResponse {
        guard url.scheme == "https" else { throw APIError.tls }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
            guard response.expectedContentLength <= Int64(Self.maximumResponseBytes) else { throw APIError.responseTooLarge }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < Self.maximumResponseBytes else { throw APIError.responseTooLarge }
                data.append(byte)
            }
            return HTTPResponse(status: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type"), data: data)
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost: throw APIError.offline
            case .timedOut: throw APIError.timeout
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
                 .clientCertificateRequired: throw APIError.tls
            default: throw APIError.invalidResponse
            }
        }
    }
}
