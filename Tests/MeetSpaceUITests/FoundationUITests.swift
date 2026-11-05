import XCTest

@MainActor final class FoundationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitesting", "-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"] + arguments
        app.launch()
        return app
    }

    private func capture(_ app: XCUIApplication, name: String) {
        // TabView's crossfade can outlive element existence on CI; do not record a transition frame.
        Thread.sleep(forTimeInterval: 0.5)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func revealDemoLink(_ app: XCUIApplication) -> XCUIElement {
        let link = app.buttons["openDemo"]
        for _ in 0..<4 where !link.isHittable { app.swipeUp() }
        return link
    }

    func testFirstLaunchDoesNotImplyAuthentication() {
        let app = launch()
        XCTAssertTrue(app.buttons["connectServer"].waitForExistence(timeout: 10))
        capture(app, name: "welcome-light")
        XCTAssertFalse(app.staticTexts["demoBanner"].exists)
        let demo = revealDemoLink(app)
        XCTAssertTrue(demo.isHittable); demo.tap()
        XCTAssertTrue(app.buttons["exitDemo"].waitForExistence(timeout: 5))
        capture(app, name: "meetings-light")
        app.buttons["tab.messages"].tap()
        XCTAssertTrue(app.buttons["chat.0"].waitForExistence(timeout: 5))
        capture(app, name: "messages-light")
        app.buttons["tab.profile"].tap()
        XCTAssertTrue(app.staticTexts["Демо-профиль"].exists)
        capture(app, name: "profile-light")
        app.buttons["exitDemo"].tap()
        XCTAssertTrue(app.buttons["connectServer"].waitForExistence(timeout: 5))
    }

    func testInvalidHTTPAddressIsRejected() {
        let app = launch()
        app.buttons["connectServer"].tap()
        let address = app.textFields["serverURL"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap(); address.typeText("http://fixture.example")
        app.buttons["checkServer"].tap()
        XCTAssertTrue(app.otherElements["serverError"].exists || app.staticTexts["serverError"].exists)
    }

    func testValidServerAdvancesToAuthenticationWithEmptySubmitDisabled() {
        let app = launch()
        app.buttons["connectServer"].tap()
        let address = app.textFields["serverURL"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap(); address.typeText("https://fixture.example")
        app.buttons["checkServer"].tap()
        let next = app.buttons["Перейти ко входу"]
        XCTAssertTrue(next.waitForExistence(timeout: 5)); next.tap()
        XCTAssertTrue(app.secureTextFields["Пароль"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Войти"].isEnabled)
    }

    private func authentication(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["connectServer"].waitForExistence(timeout: 10))
        app.buttons["connectServer"].tap()
        let address = app.textFields["serverURL"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap(); address.typeText("https://fixture.example")
        app.buttons["checkServer"].tap()
        let next = app.buttons["Перейти ко входу"]
        XCTAssertTrue(next.waitForExistence(timeout: 5)); next.tap()
    }

    private func login(_ app: XCUIApplication, password: String = "fixture-password") {
        authentication(app)
        let email = app.textFields["Электронная почта"]
        XCTAssertTrue(email.waitForExistence(timeout: 5)); email.tap(); email.typeText("first@fixture.example")
        let secret = app.secureTextFields["Пароль"]
        secret.tap(); secret.typeText(password)
        let submit = app.buttons["authenticationSubmit"]
        for _ in 0..<3 where !submit.isHittable { app.swipeUp() }
        XCTAssertTrue(submit.isEnabled); submit.tap()
    }

    func testAuthenticationErrorIsVisibleAndDoesNotOpenWorkspace() {
        let app = launch(["-auth-error"])
        login(app, password: "wrong-password")
        XCTAssertTrue(app.staticTexts["authenticationError"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["tab.messages"].exists)
        capture(app, name: "stage03-authentication-error")
    }

    func testAuthenticatedChatSendAndLogout() {
        let app = launch(); login(app)
        let chat = app.buttons["conversation.22222222-2222-4222-8222-222222222222"]
        XCTAssertTrue(chat.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["demoBanner"].exists)
        capture(app, name: "stage03-live-chats")
        chat.tap()
        let composer = app.textFields["messageComposer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap(); composer.typeText("Проверка сообщения")
        app.buttons["sendMessage"].tap()
        XCTAssertTrue(app.staticTexts["Проверка сообщения"].waitForExistence(timeout: 5))
        capture(app, name: "stage03-live-thread")
        app.buttons["tab.profile"].tap()
        XCTAssertTrue(app.buttons["addAccount"].waitForExistence(timeout: 5))
        capture(app, name: "stage03-live-profile")
        app.buttons["Выйти из аккаунта"].firstMatch.tap()
        let logout = app.buttons["Выйти"]
        XCTAssertTrue(logout.waitForExistence(timeout: 5)); logout.tap()
        XCTAssertTrue(app.secureTextFields["Пароль"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["tab.messages"].exists)
    }

    func testCreateGroupWithSelectedMember() {
        let app = launch(); login(app)
        let newChat = app.buttons["newChat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 10)); newChat.tap()
        let toggle = app.switches["Групповой чат"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        // SwiftUI Form exposes both the row and the actual UISwitch. Tap the thumb control.
        let control = toggle.switches.firstMatch
        if control.exists { control.tap() }
        else { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        let name = app.textFields["Название группы"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Команда iOS")
        app.buttons["Выбрать участников"].tap()
        let peer = app.buttons["peer.11111111-1111-4111-8111-111111111113"]
        XCTAssertTrue(peer.waitForExistence(timeout: 5)); peer.tap()
        app.buttons["Готово"].tap()
        app.buttons["createConversation"].tap()
        XCTAssertTrue(app.staticTexts["Команда iOS"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["messageComposer"].waitForExistence(timeout: 10))
        app.buttons["О группе"].tap()
        XCTAssertTrue(app.staticTexts["Тестовый собеседник"].waitForExistence(timeout: 5))
        capture(app, name: "stage03-group-members")
    }

    private func createConference(_ app: XCUIApplication, title: String) {
        login(app)
        let meetings = app.buttons["tab.meetings"]
        XCTAssertTrue(meetings.waitForExistence(timeout: 10)); meetings.tap()
        let create = app.buttons["createConference"]
        XCTAssertTrue(create.waitForExistence(timeout: 10)); create.tap()
        let name = app.textFields["conferenceTitle"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText(title)
        let submit = app.buttons["conferenceCreateSubmit"]
        for _ in 0..<3 where !submit.isHittable { app.swipeUp() }
        XCTAssertTrue(submit.isEnabled); submit.tap()
        XCTAssertTrue(app.buttons["conferenceJoin"].waitForExistence(timeout: 10))
    }

    private func waitForValue(_ value: String, of element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed, file: file, line: line)
    }

    private func joinConference(_ app: XCUIApplication) {
        app.buttons["conferenceJoin"].tap()
        let microphone = app.buttons["conferenceMic"]
        XCTAssertTrue(microphone.waitForExistence(timeout: 10))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: microphone)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed)
        waitForValue("Выключен", of: microphone)
        waitForValue("Выключен", of: app.buttons["conferenceCamera"])
    }

    private func leaveConference(_ app: XCUIApplication) {
        let leave = app.buttons["conferenceLeave"]
        XCTAssertTrue(leave.waitForExistence(timeout: 5)); leave.tap()
        XCTAssertTrue(app.buttons["createConference"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["conferenceMic"].exists)
        XCTAssertFalse(app.buttons["conferenceCamera"].exists)
    }

    /// Exercises the real SwiftUI/session flow through DEBUG REST/signaling/media doubles.
    /// Camera frames and permissions here are deterministic fixtures, not physical-device validation.
    func testConferenceCreateMediaControlsChatAndLeave() {
        let app = launch()
        createConference(app, title: "Встреча команды")
        capture(app, name: "stage04-prejoin")
        joinConference(app)

        let microphone = app.buttons["conferenceMic"]
        microphone.tap(); waitForValue("Включён", of: microphone)
        microphone.tap(); waitForValue("Выключен", of: microphone)
        let camera = app.buttons["conferenceCamera"]
        camera.tap(); waitForValue("Включён", of: camera)
        XCTAssertTrue(app.staticTexts["Тестовое видео"].waitForExistence(timeout: 5))
        capture(app, name: "stage04-connected")

        app.buttons["conferenceParticipants"].tap()
        XCTAssertTrue(app.staticTexts["Тестовый участник"].firstMatch.waitForExistence(timeout: 5))
        capture(app, name: "stage04-participants")
        let closeParticipants = app.buttons["conferencePanelClose"]
        XCTAssertTrue(closeParticipants.waitForExistence(timeout: 5)); closeParticipants.tap()

        app.buttons["conferenceChat"].tap()
        // A vertical-axis SwiftUI TextField can bridge to UITextView on iOS.
        let input = app.descendants(matching: .any).matching(identifier: "conferenceChatInput").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let textView = app.textViews["conferenceChatInput"]
        let composer = textView.exists ? textView : app.textFields["conferenceChatInput"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5)); composer.tap(); composer.typeText("Сообщение встречи")
        app.buttons["conferenceChatSend"].tap()
        XCTAssertTrue(app.staticTexts["Сообщение встречи"].waitForExistence(timeout: 5))
        capture(app, name: "stage04-meeting-chat")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Validate the compact chat while the keyboard is open")
        let heading = app.staticTexts["conferenceChatHeading"]
        let sender = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "conferenceMessageSender.")).firstMatch
        XCTAssertTrue(heading.exists && sender.exists)
        for text in [sender, app.staticTexts["Сообщение встречи"]] {
            XCTAssertGreaterThanOrEqual(text.frame.minY, heading.frame.maxY, "Chat header must not cover message text")
            XCTAssertLessThanOrEqual(text.frame.maxY, composer.frame.minY, "Composer must not cover message text")
        }
        for identifier in ["conferenceMic", "conferenceCamera", "conferenceParticipants", "conferenceChat", "conferenceLeave"] {
            XCTAssertGreaterThanOrEqual(app.buttons[identifier].frame.height, 44, "Primary controls keep their touch target while typing")
        }
        app.buttons["conferencePanelClose"].tap()
        camera.tap(); waitForValue("Выключен", of: camera)
        leaveConference(app)
    }

    func testConferenceDeniedCameraPermissionKeepsCaptureOffAndCanLeave() {
        let app = launch(["-media-permission-denied"])
        createConference(app, title: "Проверка разрешений")
        joinConference(app)
        let camera = app.buttons["conferenceCamera"]
        camera.tap()
        XCTAssertTrue(app.staticTexts["conferenceError"].waitForExistence(timeout: 5))
        waitForValue("Выключен", of: camera)
        waitForValue("Выключен", of: app.buttons["conferenceMic"])
        XCTAssertFalse(app.staticTexts["Тестовое видео"].exists)
        capture(app, name: "stage04-camera-permission-denied")
        leaveConference(app)
    }

    func testOfflineStateCanRetryInExplicitDemo() {
        let app = launch(["-demo", "-offline"])
        XCTAssertTrue(app.staticTexts["Нет подключения"].waitForExistence(timeout: 5))
        app.buttons["Повторить"].tap()
        XCTAssertTrue(app.buttons["meeting.1"].waitForExistence(timeout: 5))
    }

    func testStateScreensAreReachable() {
        for (flag, title) in [("-empty", "Здесь пока пусто"), ("-error", "Не удалось загрузить"), ("-loading", "Загружаем пространство…")] {
            let app = launch(["-demo", flag])
            XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    func testLargeTextNavigationAndAppearance() {
        let app = launch(["-demo", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(app.buttons["exitDemo"].waitForExistence(timeout: 5))
        XCTAssertLessThan(app.buttons["tab.profile"].frame.height + app.buttons["exitDemo"].frame.height,
                          app.frame.height / 4, "Persistent controls must leave space for large-text content")
        app.buttons["tab.profile"].tap()
        let appearance = app.buttons["Оформление"]
        for _ in 0..<4 where !appearance.isHittable { app.swipeUp() }
        XCTAssertTrue(appearance.isHittable); appearance.tap()
        let dark = app.buttons["appearance.dark"]
        XCTAssertTrue(dark.waitForExistence(timeout: 5))
        for _ in 0..<4 where !dark.isHittable { app.swipeUp() }
        XCTAssertTrue(dark.isHittable); dark.tap()
        XCTAssertTrue(dark.isSelected)
        capture(app, name: "appearance-dark-large-text")
    }
}
