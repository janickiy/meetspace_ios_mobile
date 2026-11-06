import Foundation
import Testing
@testable import MeetSpaceAPI

private final class SecurityUploadEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var started: Set<String> = []
    private var stopped: Set<String> = []
    func start(_ path: String) { lock.withLock { _ = started.insert(path) } }
    func stop(_ path: String) { lock.withLock { _ = stopped.insert(path) } }
    func hasStarted(_ path: String) -> Bool { lock.withLock { started.contains(path) } }
    func hasStopped(_ path: String) -> Bool { lock.withLock { stopped.contains(path) } }
}

private final class SecurityUploadProtocol: URLProtocol, @unchecked Sendable {
    static let events = SecurityUploadEvents()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "security-upload.fixture" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!, path = url.path
        Self.events.start(path)
        if path.hasPrefix("/wait/") { return }
        let kind = path.split(separator: "/").first.map(String.init) ?? ""
        var status = 200, headers = ["Content-Type": "application/json"]
        if kind == "announced" { headers["Content-Length"] = "1000000000" }
        if kind == "unauthorized" { status = 401; headers["Content-Length"] = "50" }
        if kind == "error-oversize" { status = 403; headers["Content-Length"] = "65537" }
        if kind == "redirect" { status = 302; headers["Location"] = "https://other.fixture/credentials" }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if ["announced", "error-oversize", "redirect"].contains(kind) { return }
        if kind == "chunked" {
            client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 12))
            client?.urlProtocol(self, didLoad: Data(repeating: 66, count: 12))
            // Deliberately never finish: rejecting the response must not wait for EOF.
            return
        }
        client?.urlProtocol(self, didLoad: Data(repeating: 65, count: kind == "unauthorized" ? 50 : 16))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.events.stop(request.url!.path) }
}

private func securityUploadTransport() -> URLSessionRequestTransport {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SecurityUploadProtocol.self]
    return URLSessionRequestTransport(configuration: configuration)
}
private func securityUploadRequest(_ kind: String) -> URLRequest {
    var request = URLRequest(url: URL(string: "https://security-upload.fixture/\(kind)/\(UUID().uuidString)")!)
    request.httpMethod = "PUT"
    return request
}
private func withSecurityUploadFile<T>(_ body: (URL) async throws -> T) async throws -> T {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("upload-fixture".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    return try await body(url)
}
private enum SecurityUploadTimeout: Error { case deadline }
private func boundedUploadResult(_ transport: URLSessionRequestTransport, request: URLRequest, file: URL, limit: Int) async throws -> NetworkResponse {
    try await withThrowingTaskGroup(of: NetworkResponse.self) { group in
        group.addTask { try await transport.send(request, limit: limit, uploadFile: file, progress: nil) }
        group.addTask { try await Task.sleep(for: .seconds(3)); throw SecurityUploadTimeout.deadline }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
private func waitForUpload(_ condition: () -> Bool) async throws {
    for _ in 0..<100 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw SecurityUploadTimeout.deadline
}

@Test func stage08UploadRejectsOversizeBeforeResponseFinishes() async throws {
    try await withSecurityUploadFile { file in
        for kind in ["announced", "chunked", "error-oversize"] {
            let transport = securityUploadTransport(), request = securityUploadRequest(kind)
            await #expect(throws: APIError.responseTooLarge) {
                try await boundedUploadResult(transport, request: request, file: file, limit: 16)
            }
            try await waitForUpload { SecurityUploadProtocol.events.hasStopped(request.url!.path) }
        }
    }
}

@Test func stage08UploadPreservesBoundedSuccessAndHTTPError() async throws {
    try await withSecurityUploadFile { file in
        let transport = securityUploadTransport()
        let success = try await boundedUploadResult(transport, request: securityUploadRequest("ready"), file: file, limit: 16)
        #expect(success.status == 200 && success.data.count == 16)
        let denied = try await boundedUploadResult(transport, request: securityUploadRequest("unauthorized"), file: file, limit: 1)
        #expect(denied.status == 401 && denied.data.count == 50)
        await #expect(throws: APIError.redirect) {
            try await boundedUploadResult(transport, request: securityUploadRequest("redirect"), file: file, limit: 16)
        }
    }
}

@Test func stage08UploadCancellationAndAccountDrainReleasePendingRequests() async throws {
    try await withSecurityUploadFile { file in
        let transport = securityUploadTransport(), firstRequest = securityUploadRequest("wait"), secondRequest = securityUploadRequest("wait")
        let first = Task { try await transport.send(firstRequest, limit: 16, uploadFile: file, progress: nil) }
        try await waitForUpload { SecurityUploadProtocol.events.hasStarted(firstRequest.url!.path) }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        try await waitForUpload { SecurityUploadProtocol.events.hasStopped(firstRequest.url!.path) }
        let second = Task { try await transport.send(secondRequest, limit: 16, uploadFile: file, progress: nil) }
        try await waitForUpload { SecurityUploadProtocol.events.hasStarted(secondRequest.url!.path) }
        await transport.cancelAll()
        await #expect(throws: CancellationError.self) { try await second.value }
        try await waitForUpload { SecurityUploadProtocol.events.hasStopped(secondRequest.url!.path) }
        // The account client can still send its final logout after draining existing requests.
        let next = try await boundedUploadResult(transport, request: securityUploadRequest("ready"), file: file, limit: 16)
        #expect(next.status == 200)
    }
}
