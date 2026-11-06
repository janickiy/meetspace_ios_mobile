import Foundation
import CryptoKit
import MeetSpaceCore

public protocol RecordingDownloading: Sendable {
    func download(url: URL, file: RecordingFile, progress: TransferProgress?) async throws -> URL
    func remove(_ url: URL) async
    func close() async
}

private final class RecordingRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Account-scoped temporary artifacts, streamed with bounded memory. Never attaches API
/// credentials, follows redirects, persists signed URLs, or accepts cleartext storage URLs.
public actor URLSessionRecordingDownloader: RecordingDownloading {
    public static let maximumBytes: Int64 = 512 * 1024 * 1024
    private let session: URLSession
    private let root: URL
    private var closed = false
    public init(account: AccountRecord, baseDirectory: URL? = nil) {
        self.init(account: account, baseDirectory: baseDirectory, configuration: .ephemeral)
    }
    init(account: AccountRecord, baseDirectory: URL?, configuration: URLSessionConfiguration) {
        configuration.urlCache = nil; configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 900
        session = URLSession(configuration: configuration, delegate: RecordingRedirectPolicy(), delegateQueue: nil)
        let scope = SHA256.hash(data: Data(account.id.utf8)).map { String(format: "%02x", $0) }.joined()
        root = (baseDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0])
            .appendingPathComponent("MeetSpaceRecordings", isDirectory: true).appendingPathComponent(scope, isDirectory: true)
        // Previous process's plaintext cache is not reusable without authorization.
        try? FileManager.default.removeItem(at: root)
    }
    deinit { session.invalidateAndCancel() }
    public func download(url: URL, file: RecordingFile, progress: TransferProgress?) async throws -> URL {
        try checkOpen()
        guard url.scheme == "https", url.host?.isEmpty == false, url.user == nil, url.password == nil, url.fragment == nil else { throw APIError.tls }
        try FilePolicy.validateName(file.filename)
        guard file.available, file.sizeBytes.map({ $0 > 0 && $0 <= Self.maximumBytes }) ?? true else { throw RecordingAccessError.tooLarge }
        let supported = ["final_mp4": "video/mp4", "final_audio": "audio/mp4", "tracks_archive": "application/zip", "preview_jpg": "image/jpeg"]
        guard supported[file.type] == file.mimeType else { throw RecordingAccessError.unsupportedMedia }
        var folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var values = URLResourceValues(); values.isExcludedFromBackup = true; try folder.setResourceValues(values)
        let destination = folder.appendingPathComponent(file.filename)
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: folder) } }
        #if os(iOS)
        let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete, .posixPermissions: 0o600]
        #else
        let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        #endif
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: attributes) else { throw ClientError.storage }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var request = URLRequest(url: url); request.httpMethod = "GET"
        request.setValue(file.mimeType, forHTTPHeaderField: "Accept")
        // No Authorization/Cookie, even if object storage happens to share the API origin.
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            try checkOpen()
            guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
            guard !(300...399).contains(http.statusCode) else { throw APIError.redirect }
            guard http.statusCode == 200 else { throw APIError.httpStatus(http.statusCode) }
            let mime = http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
            guard mime == file.mimeType else { throw RecordingAccessError.invalidArtifact }
            let announced = response.expectedContentLength
            guard announced <= Self.maximumBytes else { throw RecordingAccessError.tooLarge }
            guard file.sizeBytes.map({ announced < 0 || announced == $0 }) ?? true else { throw RecordingAccessError.invalidArtifact }
            var received: Int64 = 0; var chunk = Data(); chunk.reserveCapacity(65_536); var hash = SHA256()
            for try await byte in bytes {
                guard received < Self.maximumBytes, file.sizeBytes.map({ received < $0 }) ?? true else { throw RecordingAccessError.tooLarge }
                chunk.append(byte); received += 1
                if chunk.count == 65_536 {
                    try checkOpen(); try handle.write(contentsOf: chunk); hash.update(data: chunk); chunk.removeAll(keepingCapacity: true)
                    if let size = file.sizeBytes { progress?(Double(received) / Double(size)) }
                }
            }
            try checkOpen()
            if !chunk.isEmpty { try handle.write(contentsOf: chunk); hash.update(data: chunk) }
            guard received > 0, file.sizeBytes.map({ received == $0 }) ?? true, announced < 0 || received == announced else { throw RecordingAccessError.invalidArtifact }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard file.checksumSHA256.map({ $0.lowercased() == digest }) ?? true else { throw RecordingAccessError.invalidArtifact }
            try handle.synchronize(); try checkOpen(); committed = true; progress?(1)
            return destination
        } catch is CancellationError { throw CancellationError() }
        catch let error as APIError { throw error }
        catch let error as RecordingAccessError { throw error }
        catch let error as ClientError { throw error }
        catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .timedOut: throw APIError.timeout
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid: throw APIError.tls
            default: throw APIError.offline
            }
        } catch { throw RecordingAccessError.invalidArtifact }
    }
    public func remove(_ url: URL) {
        guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
    public func close() async {
        closed = true
        let tasks = await session.allTasks; tasks.forEach { $0.cancel() }
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: root)
    }
    private func checkOpen() throws { try Task.checkCancellation(); if closed { throw CancellationError() } }
}
