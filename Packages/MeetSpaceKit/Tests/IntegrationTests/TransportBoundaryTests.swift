import Foundation
import Testing
@testable import MeetSpaceAPI

private final class BoundaryProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "transport.fixture" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        if url.path == "/wait" { return }
        let status = url.path == "/unauthorized" ? 401 : url.path == "/redirect" ? 302 : 200
        let body = Data(repeating: 65, count: 131_072)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": String(status == 401 ? 50 : body.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: status == 401 ? Data(repeating: 65, count: 50) : body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private func boundaryTransport() -> URLSessionRequestTransport {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BoundaryProtocol.self]
    return URLSessionRequestTransport(configuration: configuration)
}
@Test func tinyDownloadPreservesLargerUnauthorizedResponse() async throws {
    let response = try await boundaryTransport().send(URLRequest(url: URL(string: "https://transport.fixture/unauthorized")!),
        limit: 1, uploadFile: nil, progress: nil)
    #expect(response.status == 401 && response.data.count == 50)
}
@Test func successfulDownloadIsBoundedBeforeAccumulation() async throws {
    await #expect(throws: APIError.responseTooLarge) {
        try await boundaryTransport().send(URLRequest(url: URL(string: "https://transport.fixture/large")!),
            limit: 10, uploadFile: nil, progress: nil)
    }
}
@Test func cancelledDownloadDoesNotRemainInFlight() async throws {
    let transport = boundaryTransport()
    let running = Task {
        try await transport.send(URLRequest(url: URL(string: "https://transport.fixture/wait")!),
            limit: 10, uploadFile: nil, progress: nil)
    }
    try await Task.sleep(for: .milliseconds(20))
    running.cancel()
    await #expect(throws: CancellationError.self) { try await running.value }
}
private final class ProgressValues: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func append(_ value: Double) { lock.withLock { values.append(value) } }
    var snapshot: [Double] { lock.withLock { values } }
}
@Test func downloadProgressUsesReceivedBytesAndFinishesAtOne() async throws {
    let values = ProgressValues()
    _ = try await boundaryTransport().send(URLRequest(url: URL(string: "https://transport.fixture/progress")!),
        limit: 131_072, uploadFile: nil, progress: { values.append($0) })
    #expect(values.snapshot.contains(0.5) && values.snapshot.last == 1)
}
