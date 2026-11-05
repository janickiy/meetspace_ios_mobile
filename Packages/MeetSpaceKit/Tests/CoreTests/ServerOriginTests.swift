import Foundation
import Testing
@testable import MeetSpaceCore
import MeetSpaceRealtime

@Test(arguments: ["http://meet.example", "meet.example", "https://user:pass@meet.example",
                  "https://meet.example/api", "https://meet.example?ticket=secret", "https://meet.example/#secret",
                  "https://meet.example:0", "https://meet.example:65536", "https://meet.example\\evil",
                  "https://meet.example/a/..", "https://meet.%65xample", "https://meet. example", "https://", ""])
func rejectsUnsafeOrigins(_ input: String) {
    #expect(throws: (any Error).self) { try ServerOrigin(input) }
}

@Test func normalizesOriginAndPreservesCustomPort() throws {
    #expect(try ServerOrigin(" HTTPS://MEET.EXAMPLE:443/ \n").url.absoluteString == "https://meet.example")
    #expect(try ServerOrigin("https://meet.example:8443").url.port == 8443)
    #expect(try ServerOrigin("https://[::1]:8443/").url.port == 8443)
    #expect(try ServerOrigin("https://пример.рф").url.scheme == "https")
}

@Test func decodeCannotBypassValidation() throws {
    #expect(throws: (any Error).self) { try JSONDecoder().decode(ServerOrigin.self, from: Data("\"http://meet.example\"".utf8)) }
    let origin = try ServerOrigin("https://meet.example")
    #expect(try JSONDecoder().decode(ServerOrigin.self, from: JSONEncoder().encode(origin)) == origin)
}

@Test func credentialsAreScopedByServerAndAccount() throws {
    let id = UUID()
    let a = CredentialKey(server: try ServerOrigin("https://one.example"), accountID: id)
    let b = CredentialKey(server: try ServerOrigin("https://two.example"), accountID: id)
    let c = CredentialKey(server: a.server, accountID: UUID())
    #expect(Set([a.storageKey, b.storageKey, c.storageKey]).count == 3)
}

@Test func realtimeUsesAuditedPathsAndEncodesTicket() throws {
    let origin = try ServerOrigin("https://meet.example:8443")
    let ticket = "one+time&value=?"
    let url = try RealtimeEndpoint.url(origin: origin, scope: .user, ticket: ticket)
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.scheme == "wss")
    #expect(components.port == 8443)
    #expect(components.path == "/api/v1/ws")
    #expect(components.queryItems == [URLQueryItem(name: "ticket", value: ticket)])
    let id = UUID()
    let conference = try RealtimeEndpoint.url(origin: origin, scope: .conference(id), ticket: "ticket")
    #expect(conference.path == "/api/v1/conferences/\(id.uuidString.lowercased())/ws")
    #expect(throws: (any Error).self) { try RealtimeEndpoint.url(origin: origin, scope: .user, ticket: " ") }
}
