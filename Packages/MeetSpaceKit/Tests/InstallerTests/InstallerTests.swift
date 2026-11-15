import Foundation
import Testing
@testable import MeetSpaceInstaller

@Test func installerSignedAndroidBundleAndStdinPayload() throws {
    let bundle = try InstallerBundle()
    #expect(bundle.manifest["installerVersion"] as? String == "1.0.0")
    let secret = "private-marker-never-in-command"
    let payload = try bundle.payload("apply", ["adminPassword":secret])
    #expect(payload.count < 512 * 1024)
    #expect(!String(decoding: payload, as: UTF8.self).contains(secret))
    #expect(throws: InstallerFailure.self) { try bundle.payload("shell", [:]) }
}
@Test func installerInputRejectsShellInjectionAndReservedAdminPort() throws {
    #expect(throws: InstallerFailure.self) { try InstallerEndpoint(host: "server;curl example.com") }
    #expect(throws: InstallerFailure.self) { try InstallerEndpoint(host: "example.com", port: 0) }
    #expect(throws: InstallerFailure.self) { try InstallerEndpoint(host: "example.com", user: "root && id") }
    var options = InstallerOptions(); options.domain = "https://meet.example.org/"; options.publicIpv4 = "203.0.113.10"
    #expect(try options.validated().domain == "meet.example.org")
    options.admin.httpsPort = 8082
    #expect(throws: InstallerFailure.self) { try options.validated() }
    #expect(!InstallerOptions.validAdminPassword("short"))
    #expect(!InstallerOptions.validAdminPassword("password\nsecret"))
    #expect(InstallerOptions.validAdminPassword("правильный-пароль"))
}
@Test func installerCanonicalJSONAndFingerprint() throws {
    #expect(String(decoding: try canonical(["b":"Привет","a":"https://example.org"]), as: UTF8.self) == "{\"a\":\"https://example.org\",\"b\":\"\\u041f\\u0440\\u0438\\u0432\\u0435\\u0442\"}")
    let key = try InstallerHostKey(openSSH: "ssh-ed25519 YWJj comment")
    #expect(key.openSSH == "ssh-ed25519 YWJj")
    #expect(key.fingerprint == "SHA256:ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0")
}

/// Opt-in, loopback-only SSH protocol fixture. It never runs an installation or any remote shell command.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MEETSPACE_SSH_FIXTURE"] == "1"))
func installerNativeSSHHandshakePinningAndStdin() async throws {
    func counters() throws -> [String:Int] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "/tmp/meetspace-ssh-fixture/counts.json"))) as? [String:Int])
    }
    let initial = try counters()
    let raw = try Data(contentsOf: URL(fileURLWithPath: "/tmp/meetspace-ssh-fixture/endpoint.json"))
    let endpointData = try #require(JSONSerialization.jsonObject(with: raw) as? [String:Any])
    let port = try #require(endpointData["port"] as? Int)
    let expected = try InstallerHostKey(openSSH: #require(endpointData["hostKey"] as? String))
    let endpoint = try InstallerEndpoint(host: "127.0.0.1", port: port, user: "fixture")
    let transport = NativeInstallerTransport()
    let observed = try await transport.inspect(endpoint)
    #expect(observed == expected)
    let counts = try counters()
    #expect(counts["auth"] == initial["auth"]) // Inspection stopped before sending any credentials.
    let result = try await transport.execute(endpoint, credentials: .password("fixture-only-password"), key: observed, input: Data("pass\n".utf8))
    #expect(String(decoding: result, as: UTF8.self) == "MS_TEST_OK")
    let wrong = try InstallerHostKey(openSSH: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILPNQ7HnSGlQJ4uTYrYbvyr5w0zOvE6rFNQXUuI8IJZx")
    await #expect(throws: (any Error).self) { try await transport.execute(endpoint, credentials: .password("fixture-only-password"), key: wrong, input: Data("pass\n".utf8)) }
    let final = try counters()
    #expect(final["auth"] == initial["auth"]! + 1)
    #expect(final["exec"] == initial["exec"]! + 1)
    #expect(final["payloads"] == initial["payloads"]! + 1)

    // Cancel while the server deliberately withholds auth success. No exec may follow later.
    let delayed = try InstallerEndpoint(host: "127.0.0.1", port: port, user: "slowfixture")
    let attempt = Task { try await transport.execute(delayed, credentials: .password("fixture-only-password"), key: observed, input: Data("pass\n".utf8)) }
    for _ in 0..<100 {
        if try counters()["auth"] == final["auth"]! + 1 { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(try counters()["auth"] == final["auth"]! + 1)
    let cancelledAt = ContinuousClock.now
    attempt.cancel()
    await #expect(throws: (any Error).self) { try await attempt.value }
    #expect(cancelledAt.duration(to: .now) < .seconds(2))
    try await Task.sleep(for: .milliseconds(3200))
    let afterCancellation = try counters()
    #expect(afterCancellation["exec"] == final["exec"])
    #expect(afterCancellation["payloads"] == final["payloads"])
}

#if DEBUG
@Test func installerFixtureUsesVerifiedPlanAndDurablePublicRecoveryTicket() async throws {
    let suite = "meetspace.installer.tests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let repository = InstallerRepository(transport: InstallerFixtureTransport(), defaults: defaults)
    let endpoint = try InstallerEndpoint(host: "203.0.113.10")
    let (key, changed) = try await repository.inspect(endpoint)
    #expect(!changed)
    await repository.trust(key, endpoint: endpoint)
    var options = InstallerOptions(); options.domain = "meet.example.org"; options.publicIpv4 = "203.0.113.10"
    let plan = try await repository.plan(endpoint, credentials: .password("test-only"), key: key, options: options)
    #expect(plan.options.domain == "meet.example.org")
    let ticket = InstallerTicket(endpoint: endpoint, key: key, plan: plan)
    let running = try await repository.apply(ticket, credentials: .password("test-only"), docker: true, acme: true, adminPassword: "fixture-admin-secret", smtpPassword: nil)
    #expect(running.state == "running")
    #expect(try await repository.pending() == ticket)
    let publicData = try #require(UserDefaults(suiteName: suite)?.data(forKey: "meetspace.installer.public-ticket.v1"))
    #expect(!String(decoding: publicData, as: UTF8.self).contains("fixture-admin-secret"))
    let completed = try await repository.control("status", ticket: ticket, credentials: .password("test-only"))
    #expect(completed.completed == installerPhases)
    await repository.forgetTrust(endpoint)
    await #expect(throws: InstallerFailure.self) { try await repository.control("resume", ticket: ticket, credentials: .password("test-only")) }
}
#endif
