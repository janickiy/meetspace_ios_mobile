import Foundation

/// Upload response bodies need a data delegate: URLSession's async upload API buffers
/// the complete response before returning. All mutable state is protected by `lock`.
final class BoundedUpload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private let progress: TransferProgress?
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionUploadTask?
    private var continuation: CheckedContinuation<(Data, URLResponse), any Error>?
    private var response: URLResponse?
    private var responseLimit = 0
    private var buffer = Data()
    private var finished = false

    init(limit: Int, progress: TransferProgress?) { self.limit = limit; self.progress = progress }

    func run(request: URLRequest, file: URL, configuration: URLSessionConfiguration) async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.uploadTask(with: request, fromFile: file)
                let start = lock.withLock {
                    guard !finished else { return false }
                    self.session = session; self.task = task; self.continuation = continuation
                    return true
                }
                if start { task.resume() }
                else { session.invalidateAndCancel(); continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: { self.cancel() }
    }

    func cancel() { finish(.failure(CancellationError())) }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            finish(.failure(APIError.invalidResponse)); completionHandler(.cancel); return
        }
        guard !(300...399).contains(http.statusCode) else {
            finish(.failure(APIError.redirect)); completionHandler(.cancel); return
        }
        // Preserve small JSON 401/403 errors even when the success response limit is tiny.
        let cap = (200...299).contains(http.statusCode) ? limit : 65_536
        guard response.expectedContentLength <= Int64(cap) else {
            finish(.failure(APIError.responseTooLarge)); completionHandler(.cancel); return
        }
        let accept = lock.withLock {
            guard !finished else { return false }
            self.response = response; responseLimit = cap
            return true
        }
        completionHandler(accept ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let oversized = lock.withLock {
            guard !finished else { return false }
            guard data.count <= responseLimit - buffer.count else { return true }
            buffer.append(data); return false
        }
        if oversized { finish(.failure(APIError.responseTooLarge)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let result: Result<(Data, URLResponse), any Error> = lock.withLock {
            if let error { return .failure(error) }
            guard let response else { return .failure(APIError.invalidResponse) }
            return .success((buffer, response))
        }
        finish(result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(APIError.redirect))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if totalBytesExpectedToSend > 0, !lock.withLock({ finished }) {
            progress?(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
        }
    }

    private func finish(_ result: Result<(Data, URLResponse), any Error>) {
        let pending = lock.withLock { () -> (CheckedContinuation<(Data, URLResponse), any Error>?, URLSession?) in
            guard !finished else { return (nil, nil) }
            finished = true
            let pending = (continuation, session)
            continuation = nil; session = nil; task = nil; response = nil; buffer = Data()
            return pending
        }
        pending.1?.invalidateAndCancel()
        pending.0?.resume(with: result)
    }
}

/// Separate upload sessions use the same ephemeral configuration and participate in
/// account cancellation. The registry owns no credentials or response data.
final class BoundedUploadRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var uploads: [ObjectIdentifier: BoundedUpload] = [:]
    func insert(_ upload: BoundedUpload) { lock.withLock { uploads[ObjectIdentifier(upload)] = upload } }
    func remove(_ upload: BoundedUpload) { lock.withLock { _ = uploads.removeValue(forKey: ObjectIdentifier(upload)) } }
    func cancelAll() {
        let active = lock.withLock { Array(uploads.values) }
        for upload in active { upload.cancel() }
    }
}
