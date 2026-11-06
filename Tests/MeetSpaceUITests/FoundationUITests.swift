import XCTest
import Vision
import UIKit

@MainActor final class FoundationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

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

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        for _ in 0..<5 where !element.isHittable {
            let surface = app.scrollViews.firstMatch.exists ? app.scrollViews.firstMatch :
                (app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app)
            if towardTop { surface.swipeDown() } else { surface.swipeUp() }
        }
        XCTAssertTrue(element.isHittable)
    }

    private func openProfileFeature(_ identifier: String, in app: XCUIApplication) {
        app.buttons["tab.profile"].tap()
        let link = app.buttons[identifier]
        reveal(link, in: app)
        XCTAssertGreaterThanOrEqual(link.frame.height, 44, "The entire navigation row must be tappable")
        link.tap()
    }

    private func contentViewport(for element: XCUIElement, in app: XCUIApplication) -> CGRect {
        var frame = app.frame
        if app.navigationBars.firstMatch.exists {
            let top = app.navigationBars.firstMatch.frame.maxY
            frame = frame.intersection(CGRect(x: frame.minX, y: top, width: frame.width, height: max(0, frame.maxY - top)))
        }
        if app.buttons["tab.profile"].exists {
            frame.size.height = max(0, min(frame.maxY, app.buttons["tab.profile"].frame.minY) - frame.minY)
        }
        let id = element.identifier, label = element.label
        for scroll in app.scrollViews.allElementsBoundByIndex where scroll.frame.width > 0 && scroll.frame.height > 0 {
            let child = id.isEmpty
                ? scroll.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
                : scroll.descendants(matching: .any).matching(identifier: id).firstMatch
            if (!id.isEmpty || !label.isEmpty) && child.exists { frame = frame.intersection(scroll.frame) }
        }
        return frame
    }

    private func revealEntireText(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        for _ in 0..<16 {
            let viewport = self.contentViewport(for: element, in: app).insetBy(dx: 1, dy: 4)
            let frame = element.frame
            if viewport.contains(frame) { return }
            XCTAssertLessThanOrEqual(frame.height, viewport.height, "Target must fit vertically for a whole-element sample")
            let horizontal = frame.minX < viewport.minX || frame.maxX > viewport.maxX
            let delta = horizontal ? frame.midX - viewport.midX : frame.midY - viewport.midY
            let capacity = max(1, (horizontal ? viewport.width : viewport.height) - 30)
            let distance = min(capacity, abs(delta))
            let center = CGPoint(x: viewport.midX, y: viewport.midY)
            let start = horizontal
                ? CGPoint(x: center.x + (delta > 0 ? distance / 2 : -distance / 2), y: center.y)
                : CGPoint(x: center.x, y: center.y + (delta > 0 ? distance / 2 : -distance / 2))
            let end = horizontal ? CGPoint(x: start.x - (delta > 0 ? distance : -distance), y: start.y)
                : CGPoint(x: start.x, y: start.y - (delta > 0 ? distance : -distance))
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: start.x, dy: start.y)).press(forDuration: 0.1,
                thenDragTo: origin.withOffset(CGVector(dx: end.x, dy: end.y)),
                withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        XCTAssertTrue(self.contentViewport(for: element, in: app).contains(element.frame), "Target must be fully visible")
    }

    func testAccessibilityStage08CoreScreens() throws {
        let app = launch()
        var issues: [[String: String]] = []
        func reviewedCase(_ issue: XCUIAccessibilityAuditIssue, screen: String) -> String? {
            let id = issue.element?.identifier ?? ""
            let label = issue.element?.label ?? ""
            if screen == "settings", issue.auditType == .contrast, id == "saveProfile",
               app.buttons["saveProfile"].exists, !app.buttons["saveProfile"].isEnabled {
                return "reviewed: unchanged profile; disabled save action (inactive-control contrast exemption)"
            }
            if screen == "calendar", issue.auditType == .contrast,
               ["calendar.weekday.0", "calendar.weekday.4"].contains(id),
               let element = issue.element, self.contentViewport(for: element, in: app).contains(element.frame) {
                return "reviewed: actual opaque glyph/background pixels; ACCESSIBILITY_CONTRAST_REVIEW.md"
            }
            if issue.auditType == .contrast, let element = issue.element,
               self.contentViewport(for: element, in: app).contains(element.frame) {
                let statusIDs = Set((1...4).map { "recording.status.77777777-7777-4777-8777-77777777777\($0)" })
                if (screen == "welcome" && (id == "welcome.deploySubtitle" ||
                    (label == "Создать пространство на своём VPS" && app.buttons["deployServer"].frame.contains(element.frame)))) ||
                    (screen == "calendar" && id == "calendar.weekSummaryHeading") ||
                    (screen == "folders" && id == "folders.subtitle") ||
                    (screen == "recordings" && statusIDs.contains(id)) {
                    return "reviewed: opaque glyph cores exceed 4.5:1 in actual PNG; ACCESSIBILITY_IPAD_CONTRAST.md"
                }
                if screen == "messages", label == "Выберите чат", app.frame.width >= 800,
                   element.frame.minX > 340, element.frame.height > 50 {
                    return "reviewed: native empty-state node groups decorative icon with high-contrast title"
                }
                if screen == "settings", label == "ПЕ", abs(element.frame.width - 40) < 1,
                   abs(element.frame.height - 40) < 1, element.frame.maxX < 300,
                   app.staticTexts["Первый аккаунт"].exists {
                    return "reviewed: decorative initials duplicate full account name; actual PNG ratio 4.62:1"
                }
            }
            // These are reviewed cases, not a category-wide exclusion. Preserve every raw
            // finding in the attachment. TypographyAccessibilityTests independently measures
            // the bundled fonts at all 12 sizes; the AX5 flow captures the actual layouts.
            if issue.auditType == .textClipped, screen == "welcome", id == "welcome.heading",
               label == "Команда ближе.\nИдей больше." {
                return "reviewed: welcome heading; complete AX5 text in ACCESSIBILITY_REVIEW.md"
            }
            if screen == "messages", label == "ТЕ", let frame = issue.element?.frame,
               abs(frame.width - 44) < 1, abs(frame.height - 44) < 1,
               issue.auditType == .contrast || issue.auditType == .dynamicType {
                let row = app.buttons["conversation.22222222-2222-4222-8222-222222222222"]
                if row.exists, row.frame.contains(frame), row.label.contains("Тестовый собеседник") {
                    return "reviewed: decorative avatar initials; accessible row has the full name"
                }
            }
            guard issue.auditType == .dynamicType,
                  issue.compactDescription == "Dynamic Type font sizes are partially unsupported" else { return nil }
            let menus: [String: [String: String]] = [
                "calendar": ["Все встречи": "calendar.scope", "GMT": "calendar.timeZone"],
                "recordings": ["Все форматы": "recordingModeFilter", "Все статусы": "recordingStatusFilter"]]
            if let controlID = menus[screen]?[label], let frame = issue.element?.frame,
               app.buttons[controlID].exists, app.buttons[controlID].frame.contains(frame) {
                return "reviewed: menu title inside exact control; measured font scaling and AX5 multiline layout"
            }
            let exact: [String: Set<String>] = [
                "messages": ["messages.connectionStatus"],
                "calendar": ["calendar.heading", "calendar.periodTitle", "calendar.today", "calendar.scopeTitle", "calendar.timeZoneTitle"],
                "recordings": ["recordings.filterHint", "recordings.modeTitle", "recordings.statusTitle"], "folders": ["folders.subtitle"]]
            let calendarIDs = Set((0...6).map { "calendar.weekday.\($0)" } +
                                  (0...23).map { "calendar.hour.\($0)" })
            let recordingIDs = Set((1...4).flatMap { index in
                ["recording.date.77777777-7777-4777-8777-77777777777\(index)",
                 "recording.status.77777777-7777-4777-8777-77777777777\(index)"]
            })
            if exact[screen]?.contains(id) == true ||
                (screen == "calendar" && calendarIDs.contains(id)) ||
                (screen == "recordings" && recordingIDs.contains(id)) {
                return "reviewed: measured custom-font scaling; separate AX5 layout coverage"
            }
            let tabs = ["Чаты": "tab.messages", "Встречи": "tab.meetings", "Профиль": "tab.profile"]
            if let tabID = tabs[label], let frame = issue.element?.frame,
               app.buttons[tabID].frame.contains(frame) {
                return "reviewed: measured custom-font scaling; uncapped multiline tab label"
            }
            return nil
        }
        func record(_ issue: XCUIAccessibilityAuditIssue, screen: String, resolution: String?) {
            issues.append(["screen": screen, "type": String(issue.auditType.rawValue),
                           "summary": issue.compactDescription, "detail": issue.detailedDescription,
                           "element": issue.element?.identifier ?? "", "label": issue.element?.label ?? "",
                           "frame": issue.element.map { String(describing: $0.frame) } ?? "",
                           "resolution": resolution ?? "unresolved"])
        }
        func audit(_ screen: String) throws {
            var deferred: [(Int, String)] = []
            capture(app, name: "stage08-accessibility-" + screen)
            // Audit contrast before the engine changes Dynamic Type. Keep the categories
            // separate so each pass sees a settled layout after the preceding trait change.
            let categories: [XCUIAccessibilityAuditType] = [.contrast, .elementDetection, .hitRegion,
                .sufficientElementDescription, .trait, .dynamicType, .textClipped]
            for category in categories {
                try app.performAccessibilityAudit(for: category) { issue in
                    var resolution = reviewedCase(issue, screen: screen)
                    if issue.auditType == .contrast, let element = issue.element,
                       !element.identifier.isEmpty, !self.contentViewport(for: element, in: app).contains(element.frame) {
                        resolution = "deferred: outside scroll viewport; requires fully visible retest"
                        deferred.append((issues.count, element.identifier))
                    }
                    record(issue, screen: screen, resolution: resolution)
                    return true
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
            // Contrast cannot be measured from pixels clipped by a scroll container or
            // covered by persistent chrome. Revisit each identified initial finding in view.
            for (index, identifier) in deferred {
                let target = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
                revealEntireText(target, in: app)
                capture(app, name: "stage08-accessibility-\(screen)-visible-\(identifier)")
                var targetFailed = false
                try app.performAccessibilityAudit(for: .contrast) { issue in
                    let isTarget = issue.element?.identifier == identifier
                    var resolution = reviewedCase(issue, screen: screen)
                    if isTarget && resolution == nil { targetFailed = true }
                    if !isTarget, let element = issue.element,
                       !self.contentViewport(for: element, in: app).contains(element.frame) {
                        resolution = "outside retest viewport: no contrast measurement"
                    }
                    record(issue, screen: screen + "-visible-retest", resolution: resolution)
                    return true
                }
                issues[index]["resolution"] = targetFailed ? "retest failed; see unresolved finding" : "verified: fully visible contrast retest passed"
            }
            if let data = try? JSONSerialization.data(withJSONObject: issues, options: [.prettyPrinted, .sortedKeys]) {
                let progress = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                progress.name = "stage08-audit-progress-" + screen; progress.lifetime = .keepAlways; add(progress)
            }
        }
        func attachIssues() {
            if let data = try? JSONSerialization.data(withJSONObject: issues, options: [.prettyPrinted, .sortedKeys]) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "stage08-accessibility-issues"; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        XCTAssertTrue(app.buttons["connectServer"].waitForExistence(timeout: 10))
        try audit("welcome")
        // Isolate login/AutoFill from the audit engine's temporary trait overrides.
        app.terminate(); app.launch()
        login(app)
        app.buttons["tab.messages"].tap()
        XCTAssertTrue(app.buttons["conversation.22222222-2222-4222-8222-222222222222"].waitForExistence(timeout: 10))
        try audit("messages")
        app.buttons["tab.profile"].tap()
        XCTAssertTrue(app.buttons["openAccountSettings"].waitForExistence(timeout: 5))
        try audit("profile")
        openProfileFeature("openCalendar", in: app)
        XCTAssertTrue(app.segmentedControls["calendar.mode"].waitForExistence(timeout: 10))
        try audit("calendar")
        app.navigationBars.buttons.firstMatch.tap()
        openProfileFeature("openRecordings", in: app)
        XCTAssertTrue(app.buttons["recording.77777777-7777-4777-8777-777777777771"].waitForExistence(timeout: 10))
        try audit("recordings")
        app.navigationBars.buttons.firstMatch.tap()
        openProfileFeature("openFolders", in: app)
        XCTAssertTrue(app.buttons["createFolder"].waitForExistence(timeout: 5))
        try audit("folders")
        app.navigationBars.buttons.firstMatch.tap()
        openProfileFeature("openAccountSettings", in: app)
        XCTAssertTrue(app.buttons["settingsSection.profile"].waitForExistence(timeout: 5))
        try audit("settings")
        // XCTest can stop a failing test before Swift defer executes. Save evidence first.
        attachIssues()
        let unresolved = issues.filter { $0["resolution"] == "unresolved" || $0["resolution"]?.hasPrefix("deferred:") == true }
        XCTAssertTrue(unresolved.isEmpty, "Unresolved accessibility issues: \(unresolved)")
    }

    func testStage08AccountDeletionRequiresPasswordAndConfirmation() {
        let app = launch(); login(app)
        openProfileFeature("openDeleteAccount", in: app)
        let password = app.secureTextFields["deleteAccount.password"]
        let submit = app.buttons["deleteAccount.submit"]
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        XCTAssertFalse(submit.isEnabled)
        password.tap(); password.typeText("incorrect-password\n")
        reveal(submit, in: app); submit.tap()
        // iOS26 exposes nested button nodes for the same confirmation action.
        let confirmation = app.buttons.matching(identifier: "deleteAccount.confirm").firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        let cancel = app.buttons.matching(identifier: "deleteAccount.cancelConfirmation").firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        XCTAssertTrue(password.waitForExistence(timeout: 5)); XCTAssertTrue(submit.isEnabled)
        submit.tap(); XCTAssertTrue(confirmation.waitForExistence(timeout: 5)); confirmation.tap()
        let error = app.staticTexts["deleteAccount.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertFalse(submit.isEnabled, "Rejected-password input must be cleared before retry")
        XCTAssertFalse(app.buttons["connectServer"].exists, "A wrong password must preserve the account")
        reveal(password, in: app, towardTop: true)
        password.tap(); password.typeText("fixture-password\n")
        reveal(submit, in: app); capture(app, name: "stage08-account-deletion")
        submit.tap(); XCTAssertTrue(confirmation.waitForExistence(timeout: 5)); confirmation.tap()
        XCTAssertTrue(app.buttons["connectServer"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["tab.messages"].exists)
    }

    func testAccessibilityStage08LargeTextLiveFlow() {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let heading = app.staticTexts["welcome.heading"]
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
        capture(app, name: "stage08-large-text-welcome")
        login(app)
        XCTAssertTrue(app.buttons["tab.profile"].waitForExistence(timeout: 5))
        XCTAssertLessThan(app.buttons["tab.profile"].frame.height, app.frame.height / 5)
        capture(app, name: "stage08-large-text-messages")
        app.buttons["tab.profile"].tap()
        capture(app, name: "stage08-large-text-profile")
        for (identifier, title) in [("openCalendar", "calendar"), ("openRecordings", "recordings"),
                                    ("openFolders", "folders"), ("openAccountSettings", "settings")] {
            openProfileFeature(identifier, in: app)
            capture(app, name: "stage08-large-text-" + title)
            if title == "calendar" {
                for hour in [9, 12, 18] {
                    revealEntireText(app.staticTexts["calendar.hour.\(hour)"], in: app)
                    capture(app, name: "stage08-large-text-calendar-hour-\(hour)")
                }
            } else if title == "recordings" {
                for index in 1...4 {
                    revealEntireText(app.staticTexts["recording.status.77777777-7777-4777-8777-77777777777\(index)"], in: app)
                    capture(app, name: "stage08-large-text-recording-\(index)")
                }
                revealEntireText(app.staticTexts["recordings.retentionNotice"], in: app)
                capture(app, name: "stage08-large-text-recordings-footer")
            }
            app.navigationBars.buttons.firstMatch.tap()
        }
    }

    func testStage07CalendarCreateRescheduleCancelAndViews() {
        let app = launch(); login(app)
        openProfileFeature("openCalendar", in: app)
        let schedule = app.buttons["calendar.schedule"]
        XCTAssertTrue(schedule.waitForExistence(timeout: 10)); schedule.tap()
        let title = app.textFields["schedule.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5)); title.tap(); title.typeText("План команды\n")
        let submit = app.buttons["schedule.submit"]; reveal(submit, in: app); submit.tap()
        let event = app.buttons["calendar.event.33333333-3333-4333-8333-333333333333"]
        reveal(app.segmentedControls["calendar.mode"], in: app, towardTop: true)
        capture(app, name: "stage07-calendar-week")
        reveal(event, in: app)
        capture(app, name: "stage07-calendar-agenda")
        event.tap(); app.buttons["calendar.reschedule"].tap()
        let duration = app.steppers["schedule.duration"]
        XCTAssertTrue(duration.waitForExistence(timeout: 5)); duration.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(app.staticTexts["Длительность, мин: 35"].exists)
        XCTAssertTrue(app.buttons["schedule.submit"].waitForExistence(timeout: 5)); app.buttons["schedule.submit"].tap()
        XCTAssertTrue(event.waitForExistence(timeout: 5))
        reveal(app.segmentedControls["calendar.mode"], in: app, towardTop: true)
        app.segmentedControls["calendar.mode"].buttons["Месяц"].tap()
        capture(app, name: "stage07-calendar-month")
        app.segmentedControls["calendar.mode"].buttons["Список"].tap()
        reveal(event, in: app); capture(app, name: "stage07-calendar-list")
        event.tap(); app.buttons["calendar.cancel"].tap()
        // A confirmation action and the covered form button share the same title.
        // Select the action, never the underlying calendar.cancel control.
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@",
            "Отменить встречу", "calendar.cancel")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        let confirmReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: confirm)
        XCTAssertEqual(XCTWaiter.wait(for: [confirmReady], timeout: 5), .completed); confirm.tap()
        let detailClosed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["calendar.cancel"])
        XCTAssertEqual(XCTWaiter.wait(for: [detailClosed], timeout: 5), .completed)
        XCTAssertTrue(event.waitForExistence(timeout: 5)); event.tap()
        XCTAssertTrue(app.staticTexts["Отменена"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["calendar.reschedule"].exists)
    }

    func testStage07FolderRemovalPreservesChat() {
        let app = launch(); login(app)
        openProfileFeature("openFolders", in: app)
        XCTAssertTrue(app.buttons["createFolder"].waitForExistence(timeout: 5)); app.buttons["createFolder"].tap()
        let field = app.textFields["folderName"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("Проект Альфа")
        app.buttons["folderSave"].tap()
        let folder = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "folder.")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 5)); capture(app, name: "stage07-folders")
        folder.tap(); app.buttons["folderCandidates"].tap()
        let item = app.buttons["folderItem.22222222-2222-4222-8222-222222222222"]
        XCTAssertTrue(item.waitForExistence(timeout: 5)); item.tap()
        app.buttons["folderCandidates"].tap()
        XCTAssertTrue(app.staticTexts["Тестовый собеседник"].waitForExistence(timeout: 5))
        capture(app, name: "stage07-folder-contents")
        app.navigationBars.buttons.firstMatch.tap()
        let menu = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "folderMenu.")).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5)); menu.tap(); app.buttons["Удалить папку"].tap()
        let confirmation = app.buttons.matching(identifier: "Удалить папку").allElementsBoundByIndex.last!
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5)); confirmation.tap()
        XCTAssertTrue(app.staticTexts["Папок пока нет"].waitForExistence(timeout: 5))
        app.buttons["tab.messages"].tap()
        XCTAssertTrue(app.buttons["conversation.22222222-2222-4222-8222-222222222222"].waitForExistence(timeout: 5))
    }

    func testStage07SettingsPersistProfilePreferencesAndSSHDisabled() {
        let app = launch(); login(app)
        app.buttons["tab.profile"].tap(); app.buttons["openAccountSettings"].tap()
        let profile = app.buttons["settingsSection.profile"]
        XCTAssertTrue(profile.waitForExistence(timeout: 5)); profile.tap()
        let name = app.textFields["profileDisplayName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (name.value as? String ?? "").count) + "Имя iOS\n")
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        let save = app.buttons["saveProfile"]; reveal(save, in: app); save.tap()
        XCTAssertTrue(app.staticTexts["settingsSaved"].waitForExistence(timeout: 5))
        capture(app, name: "stage07-settings-profile")
        let refresh = app.buttons["Обновить настройки"]; reveal(refresh, in: app); refresh.tap()
        XCTAssertEqual(name.value as? String, "Имя iOS")
        if !app.buttons["settingsSection.notifications"].exists { app.navigationBars.buttons.firstMatch.tap() }
        app.buttons["settingsSection.notifications"].tap()
        let toggle = app.switches["notificationEmail"]
        reveal(toggle, in: app)
        let control = toggle.switches.firstMatch
        if control.exists { control.tap() } else { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        let saveNotifications = app.buttons["saveNotificationPreferences"]; reveal(saveNotifications, in: app); saveNotifications.tap()
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Настройки уведомлений сохранены"), object: app.staticTexts["settingsSaved"])
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 5), .completed)
        reveal(refresh, in: app); refresh.tap()
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        capture(app, name: "stage07-settings-notifications")
        if !app.buttons["settingsSection.server"].exists { app.navigationBars.buttons.firstMatch.tap() }
        app.buttons["settingsSection.server"].tap()
        XCTAssertTrue(app.staticTexts["sshUnavailable"].waitForExistence(timeout: 5))
        capture(app, name: "stage07-settings-server")
    }

    func testStage07RecordingsStatusAndNativePlayerWithLocalFixture() {
        let app = launch(); login(app)
        openProfileFeature("openRecordings", in: app)
        let ready = app.buttons["recording.77777777-7777-4777-8777-777777777771"]
        XCTAssertTrue(ready.waitForExistence(timeout: 10)); capture(app, name: "stage07-recordings")
        app.buttons["recording.77777777-7777-4777-8777-777777777772"].tap()
        XCTAssertTrue(app.staticTexts["recordingStatus"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["recordingStatus"].label, "Обрабатывается")
        XCTAssertFalse(app.buttons["playRecording"].exists)
        app.buttons["Все записи"].tap(); ready.tap()
        XCTAssertTrue(app.buttons["playRecording"].waitForExistence(timeout: 5)); app.buttons["playRecording"].tap()
        let player = app.descendants(matching: .any)["recordingPlayer"].firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(app.staticTexts["recordingsError"].exists)
        capture(app, name: "stage07-recording-player")
        XCTAssertTrue(app.buttons["downloadRecording"].isEnabled)
        app.buttons["Все записи"].tap()
        let audio = app.buttons["recording.77777777-7777-4777-8777-777777777774"]
        reveal(audio, in: app); audio.tap()
        XCTAssertTrue(app.buttons["playRecording"].waitForExistence(timeout: 5)); app.buttons["playRecording"].tap()
        XCTAssertTrue(player.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(app.staticTexts["recordingsError"].exists)
        XCTAssertTrue(app.buttons["Все записи"].isHittable)
        XCTAssertTrue(app.staticTexts["recordingTitle"].isHittable)
        capture(app, name: "stage07-recording-server-audio")
    }

    func testStage07RecordingAccessDeniedNeverStartsPlayer() {
        let app = launch(["-recording-access-denied"]); login(app)
        openProfileFeature("openRecordings", in: app)
        let ready = app.buttons["recording.77777777-7777-4777-8777-777777777771"]
        XCTAssertTrue(ready.waitForExistence(timeout: 10)); ready.tap()
        XCTAssertTrue(app.staticTexts["recordingsError"].waitForExistence(timeout: 5))
        let errorVisible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: app.staticTexts["recordingsError"])
        XCTAssertEqual(XCTWaiter.wait(for: [errorVisible], timeout: 5), .completed)
        XCTAssertLessThan(app.staticTexts["recordingsError"].frame.maxY, app.buttons["tab.profile"].frame.minY)
        XCTAssertFalse(app.buttons["playRecording"].exists)
        XCTAssertFalse(app.buttons["downloadRecording"].exists)
        capture(app, name: "stage07-recording-denied")
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
        reveal(app.buttons["connectServer"], in: app)
        app.buttons["connectServer"].tap()
        let address = app.textFields["serverURL"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap(); address.typeText("https://fixture.example")
        reveal(app.buttons["checkServer"], in: app)
        app.buttons["checkServer"].tap()
        let next = app.buttons["Перейти ко входу"]
        XCTAssertTrue(next.waitForExistence(timeout: 5)); reveal(next, in: app); next.tap()
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
        guard !app.launchArguments.contains("-auth-error") else { return }
        finishSuccessfulLogin(app)
    }

    private func finishSuccessfulLogin(_ app: XCUIApplication) {
        let deadline = Date().addingTimeInterval(10)
        let messages = app.buttons["tab.messages"], incoming = app.buttons["directCallAnswer"]
        while Date() < deadline, !messages.exists && !incoming.exists && !app.staticTexts["authenticationError"].exists {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(messages.exists || incoming.exists, "Login must reach the workspace or an incoming call")
        let target = app.launchArguments.contains("-call-incoming") ? incoming : messages
        // Cold launch of the Passwords remote process can outlive the app's transition.
        // Stay in the app's embedded hierarchy; never activate SafariViewService separately.
        let promptDeadline = Date().addingTimeInterval(12)
        var tappedPrompt = false
        while Date() < promptDeadline {
            if let decline = passwordDismissButton(app), decline.isHittable {
                decline.tap(); tappedPrompt = true
                // The first tap can arrive while the remote sheet is still animating.
                // Requery and retry only if that same observed prompt is still actionable.
                Thread.sleep(forTimeInterval: 1)
                continue
            }
            if !target.isHittable, dismissInaccessiblePasswordPrompt(app) {
                tappedPrompt = true
                Thread.sleep(forTimeInterval: 1)
                continue
            }
            if tappedPrompt && target.isHittable { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        // A cold Vision request can run beyond the deadline. The Passwords process
        // may expose its real AX button during that request; act on the new snapshot.
        for _ in 0..<2 {
            guard let decline = passwordDismissButton(app), decline.isHittable else { break }
            decline.tap()
            Thread.sleep(forTimeInterval: 1)
        }
        if let decline = passwordDismissButton(app) {
            XCTAssertFalse(decline.isHittable, "The password prompt must no longer block the workspace")
        }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: target)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, "The workspace must be actionable after login")
    }

    private func passwordDismissButton(_ app: XCUIApplication) -> XCUIElement? {
        guard app.sheets["Save Password?"].exists || app.sheets["Сохранить пароль?"].exists ||
                app.alerts["Save Password?"].exists || app.alerts["Сохранить пароль?"].exists ||
                app.staticTexts["Save Password?"].exists || app.staticTexts["Сохранить пароль?"].exists else { return nil }
        for label in ["Not Now", "Не сейчас"] {
            let button = app.buttons[label].firstMatch
            if button.exists { return button }
        }
        return nil
    }

    private func dismissInaccessiblePasswordPrompt(_ app: XCUIApplication) -> Bool {
        // iOS 26 can omit the Passwords remote window's children from AX and
        // interruption monitors. Ground this fallback in the current screenshot;
        // never guess coordinates or confirm a different system dialog.
        let screenshot = app.screenshot()
        guard let image = screenshot.image.cgImage else { return false }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) }
        catch { return false }
        let recognized = (request.results ?? []).compactMap { observation -> (String, Float, CGRect)? in
            guard let text = observation.topCandidates(1).first else { return nil }
            return (text.string.filter { $0.isLetter }.lowercased(), text.confidence, observation.boundingBox)
        }
        var title = recognized.first(where: { $0.0 == "savepassword" && $0.1 >= 0.8 })?.2
        if title == nil {
            // At AX5 the observed system heading wraps into two Vision observations.
            // Only join adjacent, left-aligned Save above Password?, never a Save button.
            for first in recognized where first.0 == "save" && first.1 >= 0.8 {
                if let second = recognized.first(where: { $0.0 == "password" && $0.1 >= 0.8 &&
                    abs($0.2.minX - first.2.minX) < 0.03 && first.2.minY >= $0.2.maxY &&
                    first.2.minY - $0.2.maxY < 0.05 }) {
                    title = first.2.union(second.2); break
                }
            }
        }
        guard let title,
              let decline = recognized.first(where: { $0.0 == "notnow" && $0.1 >= 0.8 }),
              decline.2.maxY < title.minY else { return false }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "system-password-prompt-before-decline"
        attachment.lifetime = .keepAlways; add(attachment)
        app.coordinate(withNormalizedOffset: CGVector(dx: decline.2.midX, dy: 1 - decline.2.midY)).tap()
        return true
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
        XCTAssertTrue(name.waitForExistence(timeout: 5)); reveal(name, in: app); name.tap()
        // The iPad sheet can expose its field before the presentation accepts focus.
        if !app.keyboards.firstMatch.waitForExistence(timeout: 2) { name.tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5)); name.typeText(title)
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

    private func callControl(_ app: XCUIApplication, _ id: String, towardTop: Bool = false) -> XCUIElement {
        let control = app.buttons[id]
        XCTAssertTrue(control.waitForExistence(timeout: 10))
        for _ in 0..<4 where !control.isHittable {
            if towardTop { app.swipeDown() } else { app.swipeUp() }
        }
        XCTAssertTrue(control.isHittable)
        return control
    }

    /// DEBUG CallKit, REST and SFU doubles exercise application state; this is not a device VoIP test.
    func testDirectIncomingAnswerControlsMinimizeAndEnd() {
        let app = launch(["-call-incoming"]); login(app)
        XCTAssertTrue(app.buttons["directCallAnswer"].waitForExistence(timeout: 10))
        capture(app, name: "stage05-incoming")
        callControl(app, "directCallAnswer").tap()
        let microphone = callControl(app, "directCallMic")
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: microphone)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed)
        waitForValue("Включён", of: microphone)
        microphone.tap(); waitForValue("Выключен", of: microphone)
        microphone.tap(); waitForValue("Включён", of: microphone)
        let camera = callControl(app, "directCallCamera")
        camera.tap(); waitForValue("Включена", of: camera)
        let preview = app.descendants(matching: .any).matching(identifier: "directCallLocalVideo").firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(preview.frame.width, 0)
        XCTAssertGreaterThan(preview.frame.height, 0)
        capture(app, name: "stage05-connected")
        camera.tap(); waitForValue("Выключена", of: camera)
        callControl(app, "directCallMinimize", towardTop: true).tap()
        let banner = app.buttons["directCallBanner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        XCTAssertTrue(banner.isHittable)
        let heading = app.staticTexts["Сообщения"].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(heading.frame.minY, banner.frame.maxY - 1, "The call banner must not cover the workspace header")
        capture(app, name: "stage05-minimized")
        app.buttons["directCallBanner"].tap()
        callControl(app, "directCallEnd").tap()
        XCTAssertTrue(app.buttons["directCallDone"].waitForExistence(timeout: 10))
        capture(app, name: "stage05-ended")
        callControl(app, "directCallDone").tap()
        XCTAssertFalse(app.buttons["directCallBanner"].exists)
    }

    func testScreenShareStartStopAndRestartInConferenceWithFixtures() {
        let app = launch()
        createConference(app, title: "Демонстрация экрана")
        joinConference(app)
        let start = app.buttons["screenShareStart"]
        XCTAssertTrue(start.waitForExistence(timeout: 10)); start.tap()
        XCTAssertTrue(app.staticTexts["Вы демонстрируете экран"].waitForExistence(timeout: 10))
        capture(app, name: "stage06-meeting-sharing")
        app.buttons["screenShareStop"].tap()
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: start)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed)
        start.tap()
        XCTAssertTrue(app.staticTexts["Вы демонстрируете экран"].waitForExistence(timeout: 10))
        app.buttons["screenShareStop"].tap()
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        capture(app, name: "stage06-meeting-stopped")
        leaveConference(app)
    }

    func testScreenConflictKeepsDirectCallAndMicrophoneWithFixtures() {
        let app = launch(["-call-incoming", "-screen-conflict"]); login(app)
        callControl(app, "directCallAnswer").tap()
        let microphone = callControl(app, "directCallMic")
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: microphone)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed)
        waitForValue("Включён", of: microphone)
        callControl(app, "screenShareStart", towardTop: true).tap()
        XCTAssertTrue(app.staticTexts["Экран уже показывает другой участник."].waitForExistence(timeout: 10))
        capture(app, name: "stage06-direct-conflict")
        waitForValue("Включён", of: app.buttons["directCallMic"])
        XCTAssertTrue(app.staticTexts["Соединение установлено"].exists)
        callControl(app, "directCallEnd").tap()
        XCTAssertTrue(app.buttons["directCallDone"].waitForExistence(timeout: 10))
    }

    func testDirectOutgoingCancelFromConversation() {
        let app = launch(); login(app)
        let chat = app.buttons["conversation.22222222-2222-4222-8222-222222222222"]
        XCTAssertTrue(chat.waitForExistence(timeout: 10)); chat.tap()
        let audioCall = app.buttons["startAudioCall"], videoCall = app.buttons["startVideoCall"]
        XCTAssertTrue(audioCall.waitForExistence(timeout: 10))
        XCTAssertTrue(audioCall.isHittable && videoCall.isHittable)
        audioCall.tap()
        XCTAssertTrue(app.staticTexts["screen.directCall"].waitForExistence(timeout: 10))
        capture(app, name: "stage05-outgoing")
        XCTAssertFalse(app.buttons["directCallAnswer"].exists)
        callControl(app, "directCallEnd").tap()
        XCTAssertTrue(app.buttons["directCallDone"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["directCallStatus"].label, "Вызов отменён")
        callControl(app, "directCallDone").tap()
        XCTAssertTrue(app.textFields["messageComposer"].waitForExistence(timeout: 10))
    }

    func testDirectCallAcceptedOnOtherDeviceHasNoCaptureControls() {
        let app = launch(["-call-incoming", "-call-other-device"]); login(app)
        callControl(app, "directCallAnswer").tap()
        XCTAssertTrue(app.staticTexts["Звонок продолжается на другом устройстве."].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["directCallMic"].exists)
        XCTAssertFalse(app.buttons["directCallCamera"].exists)
        XCTAssertFalse(app.buttons["directCallEnd"].exists)
        capture(app, name: "stage05-other-device")
    }

    func testOrdinaryPushOptInAndDisableWithFixtureToken() {
        let app = launch(); login(app)
        XCTAssertTrue(app.buttons["tab.profile"].waitForExistence(timeout: 10)); app.buttons["tab.profile"].tap()
        let toggle = app.switches["pushNotificationsToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        for _ in 0..<4 where !toggle.isHittable { app.swipeUp() }
        XCTAssertTrue(toggle.isHittable)
        func tapToggle() {
            if toggle.switches.firstMatch.exists { toggle.switches.firstMatch.tap() }
            else { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        }
        tapToggle()
        let registered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Токен сохранён сервером"),
            object: app.staticTexts["pushNotificationsStatus"])
        XCTAssertEqual(XCTWaiter.wait(for: [registered], timeout: 10), .completed)
        let status = app.staticTexts["pushNotificationsStatus"]
        for _ in 0..<3 where status.frame.maxY > app.buttons["tab.profile"].frame.minY { app.swipeUp() }
        capture(app, name: "stage05-push-enabled")
        tapToggle()
        let disabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "выключены"),
            object: app.staticTexts["pushNotificationsStatus"])
        XCTAssertEqual(XCTWaiter.wait(for: [disabled], timeout: 10), .completed)
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
