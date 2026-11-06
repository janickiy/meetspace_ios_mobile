import Foundation
import Testing
import MeetSpaceCore
import MeetSpaceAPI
import MeetSpaceStorage
import MeetSpaceRealtime
@testable import MeetSpaceFeatures

private struct Stage07IdentityProbe: ServerProbing {
    func check(_ origin: ServerOrigin) async throws -> ServerVersion { throw APIError.offline }
}
private actor Stage07IdentityPreferences: ConfigurationStore {
    func load() -> AppConfiguration { AppConfiguration() }
    func save(_ value: AppConfiguration) {}
}
private struct Stage07IdentitySockets: RealtimeSocketFactory {
    func connect(_ url: URL) async throws -> any RealtimeSocket { throw APIError.offline }
}
private func stage07IdentityUser(name: String) throws -> AccountUser {
    var value = Fixture.user(); value["displayName"] = name
    return try WireJSON.decoder().decode(AccountUser.self, from: Fixture.data(value))
}

@Test @MainActor func stage07RestoredAndSwitchedProfilesUseFreshAccountMetadataWithoutReplacingCredentials() async throws {
    // UUIDs can coincide across servers. The index lookup must use the whole account scope.
    let first = AccountRecord(server: Fixture.origin, user: try stage07IdentityUser(name: "Старое имя первого"))
    let second = AccountRecord(server: try ServerOrigin("https://second-profile.fixture"), user: try stage07IdentityUser(name: "Старое имя второго"))
    let secrets = TestSecrets(), accounts = MemoryAccountIndexStore()
    try await secrets.write(WireJSON.encoder().encode(Fixture.credentials(expired: true)), for: first.key)
    let secondCredentials = SessionCredentials(accessToken: "second-profile-token", sessionCookie: "second-profile-cookie", expiresAt: Date().addingTimeInterval(3600))
    try await secrets.write(WireJSON.encoder().encode(secondCredentials), for: second.key)
    try await accounts.save(AccountIndex(accounts: [first, second], activeID: first.id))
    let transport = RoutedTransport { request, _ in
        if request.url?.path == "/api/v1/auth/refresh" {
            #expect(request.url?.host == first.server.url.host)
            return try Fixture.login()
        }
        if request.url?.path == "/api/v1/auth/me" {
            let isFirst = request.url?.host == first.server.url.host
            #expect(request.value(forHTTPHeaderField: "Authorization") == (isFirst ? "Bearer fixture-renewed-token" : "Bearer second-profile-token"))
            var user = Fixture.user(); user["displayName"] = isFirst ? "Новое имя первого" : "Новое имя второго"
            return try Fixture.response(["status": "success", "user": user])
        }
        if request.url?.path == "/api/v1/auth/logout" { return NetworkResponse(status: 200) }
        throw APIError.offline
    }
    let identity = IdentityModel(dependencies: AppDependencies(serverProbe: Stage07IdentityProbe(), configuration: Stage07IdentityPreferences(),
        credentials: secrets, accounts: accounts, transport: { transport }, sockets: Stage07IdentitySockets()))

    await identity.restore()
    #expect(identity.error == nil && identity.messaging?.account.id == first.id)
    let firstSettings = try #require(identity.settings)
    #expect(firstSettings.profile.displayName == "Новое имя первого")
    #expect(firstSettings.displayName == "Новое имя первого" && !firstSettings.loaded)
    #expect(identity.index.accounts.first(where: { $0.id == first.id })?.user == firstSettings.profile)
    let firstClient = try #require(identity.messaging?.client)
    #expect(try await firstClient.currentUser() == firstSettings.profile)
    #expect(await transport.requests.filter { $0.url?.path == "/api/v1/auth/refresh" }.count == 1)

    await identity.switchAccount(second)
    #expect(identity.error == nil && identity.messaging?.account.id == second.id)
    let secondSettings = try #require(identity.settings)
    #expect(secondSettings.profile.displayName == "Новое имя второго")
    #expect(secondSettings.displayName == "Новое имя второго" && !secondSettings.loaded)
    #expect(identity.index.accounts.first(where: { $0.id == second.id })?.user == secondSettings.profile)
    #expect(!firstSettings.canSaveProfile)
    await #expect(throws: CancellationError.self) { try await firstClient.currentUser() }
    let stored = await accounts.load()
    #expect(stored.accounts.first(where: { $0.id == first.id })?.user.displayName == "Новое имя первого")
    #expect(stored.accounts.first(where: { $0.id == second.id })?.user.displayName == "Новое имя второго")
    await identity.logout(second); await identity.logout(first)
}

@Test @MainActor func stage07SettingsInitialProfileRejectsAnotherUser() throws {
    let account = try Fixture.account()
    let transport = RoutedTransport { _, _ in throw APIError.offline }
    let client = AuthenticatedClient(account: account, credentials: Fixture.credentials(), secureStore: TestSecrets(), transport: transport)
    let other = try Fixture.account(UUID()).user
    let model = SettingsModel(repository: SettingsRepository(client: client), initialProfile: other)
    #expect(model.profile == account.user && model.displayName == account.user.displayName)
    model.close()
}
