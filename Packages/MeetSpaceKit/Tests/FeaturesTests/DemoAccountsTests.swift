import Testing
import MeetSpaceCore
@testable import MeetSpaceFeatures

@MainActor @Test func demoAccountSwitchRetainsProfileAndServerScope() throws {
    let accounts = DemoAccounts()
    let original = accounts.current
    original.bio = "Личный профиль"
    accounts.select("studio")
    #expect(accounts.current.email == "alex@studio.example.org")
    #expect(accounts.current.bio.isEmpty)
    let otherServer = try ServerOrigin("https://other.example.org")
    accounts.add(name: "Другой профиль", email: original.email, server: otherServer)
    let added = accounts.current
    #expect(accounts.profiles.count == 3)
    accounts.add(name: "Дубликат", email: original.email, server: otherServer)
    #expect(accounts.current === added)
    #expect(accounts.profiles.count == 3)
    #expect(accounts.removeCurrent())
    #expect(accounts.current === original)
    #expect(accounts.current.bio == "Личный профиль")
    #expect(accounts.profiles.count == 2)
}
