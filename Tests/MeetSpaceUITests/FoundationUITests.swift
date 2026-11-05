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

    func testValidServerAdvancesToUnavailableAuthentication() {
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
        app.buttons["tab.profile"].tap()
        let appearance = app.buttons["Оформление"]
        for _ in 0..<4 where !appearance.isHittable { app.swipeUp() }
        XCTAssertTrue(appearance.isHittable); appearance.tap()
        XCTAssertTrue(app.segmentedControls["appearancePicker"].waitForExistence(timeout: 5))
        app.buttons["Тёмная"].tap()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "appearance-dark-large-text"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
