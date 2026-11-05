import Foundation
import MeetSpaceCore

public struct NetworkResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let data: Data
    public init(status: Int, headers: [String: String] = [:], data: Data = Data()) {
        self.status = status; self.headers = headers.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }; self.data = data
    }
}
public typealias TransferProgress = @Sendable (Double) -> Void

public protocol RequestTransport: Sendable {
    func send(_ request: URLRequest, limit: Int, uploadFile: URL?, progress: TransferProgress?) async throws -> NetworkResponse
    func cancelAll() async
}
public extension RequestTransport {
    func cancelAll() async {}
}

private final class TransferDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let progress: TransferProgress?
    init(progress: TransferProgress?) { self.progress = progress }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if totalBytesExpectedToSend > 0 {
            progress?(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
        }
    }
}

/// Separate ephemeral sessions per client. Cookies and credentials are never managed by URLSession.
public final class URLSessionRequestTransport: RequestTransport, Sendable {
    private let session: URLSession
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 90
        session = URLSession(configuration: configuration, delegate: TransferDelegate(progress: nil), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    public func cancelAll() async {
        let tasks = await session.allTasks
        tasks.forEach { $0.cancel() }
    }
    public func send(_ request: URLRequest, limit: Int = 2_097_152, uploadFile: URL? = nil,
                     progress: TransferProgress? = nil) async throws -> NetworkResponse {
        guard request.url?.scheme == "https", request.url?.user == nil, request.url?.password == nil else { throw APIError.tls }
        try Task.checkCancellation()
        do {
            let response: URLResponse
            let data: Data
            if let uploadFile {
                // Input is an immutable staged file, limited to 10 MiB before the upload starts.
                (data, response) = try await session.upload(for: request, fromFile: uploadFile,
                                                           delegate: TransferDelegate(progress: progress))
                guard data.count <= limit else { throw APIError.responseTooLarge }
            } else {
                let (bytes, incoming) = try await session.bytes(for: request)
                defer { bytes.task.cancel() }
                response = incoming
                guard incoming.expectedContentLength <= Int64(limit) else { throw APIError.responseTooLarge }
                var buffer = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard buffer.count < limit else { throw APIError.responseTooLarge }
                    buffer.append(byte)
                    if buffer.count % 65_536 == 0, incoming.expectedContentLength > 0 {
                        progress?(min(1, Double(buffer.count) / Double(incoming.expectedContentLength)))
                    }
                }
                data = buffer
            }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
            guard !(300...399).contains(http.statusCode) else { throw APIError.redirect }
            let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
                if let key = pair.key as? String { result[key.lowercased()] = String(describing: pair.value) }
            }
            if (200...299).contains(http.statusCode) { progress?(1) }
            return NetworkResponse(status: http.statusCode, headers: headers, data: data)
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost: throw APIError.offline
            case .timedOut: throw APIError.timeout
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid: throw APIError.tls
            default: throw APIError.invalidResponse
            }
        }
    }
}

public enum EndpointURL {
    public static func make(_ origin: ServerOrigin, path: [String], query: [URLQueryItem] = []) throws -> URL {
        guard path.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(where: { "/\\%?#".contains($0) }) })
        else { throw ClientError.invalidInput }
        let url = (["api", "v1"] + path).reduce(origin.url) { $0.appendingPathComponent($1) }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw APIError.invalidResponse }
        if !query.isEmpty { components.queryItems = query }
        guard let result = components.url else { throw APIError.invalidResponse }
        return result
    }
}

func requireSuccess(_ response: NetworkResponse) throws {
    guard (200...299).contains(response.status) else { throw APIError.httpStatus(response.status) }
}
func decodeJSON<T: Decodable>(_ type: T.Type, from response: NetworkResponse) throws -> T {
    try requireSuccess(response)
    guard response.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else { throw APIError.invalidResponse }
    do { return try WireJSON.decoder().decode(type, from: response.data) }
    catch { throw APIError.invalidResponse }
}
struct ItemResponse<T: Decodable>: Decodable { let item: T }
struct ItemsResponse<T: Decodable>: Decodable { let items: [T] }
struct UserResponse: Decodable { let user: AccountUser }
struct EmptyBody: Encodable {}
