import Foundation
import Testing
import MeetSpaceCore
@testable import MeetSpaceAPI

private actor TransportStub: HTTPTransport {
    let response: HTTPResponse
    var requestedURLs: [URL] = []
    init(status: Int = 200, contentType: String? = "application/json; charset=utf-8", body: String = "{\"version\":\"1.2\",\"commit\":\"abc\",\"buildTime\":\"unknown\"}") {
        response = HTTPResponse(status: status, contentType: contentType, data: Data(body.utf8))
    }
    func get(_ url: URL) -> HTTPResponse { requestedURLs.append(url); return response }
}

@Test func probesOnlyPublicVersionEndpoint() async throws {
    let transport = TransportStub()
    let version = try await ServerProbe(transport: transport).check(ServerOrigin("https://meet.example:8443"))
    #expect(version.version == "1.2")
    #expect(await transport.requestedURLs.map(\.absoluteString) == ["https://meet.example:8443/version"])
}

@Test(arguments: [301, 302, 307, 308]) func redirectsAreNotAccepted(_ status: Int) async throws {
    let probe = ServerProbe(transport: TransportStub(status: status))
    await #expect(throws: APIError.redirect) { try await probe.check(ServerOrigin("https://meet.example")) }
}

@Test(arguments: [401, 403, 404, 429, 500]) func preservesHTTPStatus(_ status: Int) async throws {
    let probe = ServerProbe(transport: TransportStub(status: status))
    await #expect(throws: APIError.httpStatus(status)) { try await probe.check(ServerOrigin("https://meet.example")) }
}

@Test(arguments: ["<html>proxy login</html>", "{}", "{\"version\":\"\",\"commit\":\"a\",\"buildTime\":\"b\"}"])
func rejectsMalformedVersion(_ body: String) async throws {
    let probe = ServerProbe(transport: TransportStub(body: body))
    await #expect(throws: APIError.invalidResponse) { try await probe.check(ServerOrigin("https://meet.example")) }
}

@Test func rejectsHTMLContentTypeAndLargeResponse() async throws {
    let origin = try ServerOrigin("https://meet.example")
    await #expect(throws: APIError.invalidResponse) {
        try await ServerProbe(transport: TransportStub(contentType: "text/html")).check(origin)
    }
    await #expect(throws: APIError.responseTooLarge) {
        try await ServerProbe(transport: TransportStub(body: String(repeating: "x", count: 131_073))).check(origin)
    }
}
