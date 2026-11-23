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

    func testBetaInstallerNavigationAndValidation() {
        let app = launch(["-installer-fixture"])
        capture(app, name: "beta-welcome")
        let deploy = app.buttons["deployServer"]
        reveal(deploy, in: app); deploy.tap()
        // The wizard owns one explicit scroll surface. Keyboard internals and the
        // presenting welcome screen must not participate in its scrolling geometry.
        func show(_ element: XCUIElement, towardTop: Bool = false) {
            XCTAssertTrue(element.waitForExistence(timeout: 10))
            let scroll = app.scrollViews["installer.scroll"].firstMatch
            XCTAssertTrue(scroll.waitForExistence(timeout: 5))
            for attempt in 0...18 {
                if let decline = passwordDismissButton(app), decline.isHittable {
                    decline.tap()
                    Thread.sleep(forTimeInterval: 0.5)
                    continue
                }
                var viewport = scroll.frame.intersection(app.frame)
                let keyboard = app.keyboards.firstMatch
                if keyboard.exists, keyboard.frame.intersects(viewport) {
                    var keyboardTop = keyboard.frame.minY
                    // The secure keyboard accessory is a sibling of Keyboard in AX.
                    // On iPhone SE it covers y407...451, although Keyboard starts451.
                    // A half-visible SecureField is "hittable", but its center tap
                    // lands on Passwords and leaves the previous field focused.
                    let accessories = app.buttons.matching(NSPredicate(format: "label IN %@", ["Passwords", "Пароли"]))
                    for accessory in accessories.allElementsBoundByIndex where accessory.isHittable {
                        let frame = accessory.frame
                        if frame.maxY <= keyboardTop + 1, keyboardTop - frame.minY <= 100,
                           frame.intersects(viewport) { keyboardTop = min(keyboardTop, frame.minY) }
                    }
                    viewport.size.height = max(0, keyboardTop - viewport.minY)
                }
                let visible = viewport.insetBy(dx: 0, dy: 4)
                let target = element.frame
                let targetVisible = target.height <= visible.height
                    ? visible.contains(target)
                    : visible.contains(CGPoint(x: target.midX, y: target.midY))
                if element.isHittable, targetVisible { return }
                if attempt == 18 { break }
                // The actual iPhone 26 diagnostics capture contains Save Password?,
                // whose remote window can omit its AX buttons. Dismiss only the
                // exact observed prompt, using the existing screenshot-grounded helper.
                if (viewport.intersects(element.frame) || !scroll.isHittable),
                   dismissInaccessiblePasswordPrompt(app) {
                    Thread.sleep(forTimeInterval: 0.5)
                    continue
                }
                viewport = viewport.insetBy(dx: 12, dy: 12)
                XCTAssertGreaterThan(viewport.height, 40, "Installer must expose a scrollable area above the keyboard")
                let delta: CGFloat
                if target.height > viewport.height { delta = target.midY - viewport.midY }
                else if target.minY < viewport.minY { delta = target.minY - viewport.minY }
                else if target.maxY > viewport.maxY { delta = target.maxY - viewport.maxY }
                else { delta = towardTop ? -32 : 32 }
                // Move only the distance still needed to expose the target. Large
                // checkbox labels must not oscillate across a fixed page-sized jump.
                let distance = min(viewport.height * 0.6, max(32, abs(delta)))
                let startY = viewport.midY + (delta < 0 ? -distance / 2 : distance / 2)
                let endY = viewport.midY + (delta < 0 ? distance / 2 : -distance / 2)
                // The iPhone 18 recording shows the midpoint starting inside the
                // host TextField, which consumes the drag without scrolling. Use
                // the observed 24pt content gutter, outside every input/control.
                let gestureX = scroll.frame.intersection(app.frame).minX + 8
                let origin = app.coordinate(withNormalizedOffset: .zero)
                origin.withOffset(CGVector(dx: gestureX, dy: startY)).press(forDuration: 0.1,
                    thenDragTo: origin.withOffset(CGVector(dx: gestureX, dy: endY)),
                    withVelocity: .slow, thenHoldForDuration: 0.2)
            }
            capture(app, name: "beta-installer-unreachable-" + element.identifier)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "beta-installer-unreachable-hierarchy"
            hierarchy.lifetime = .keepAlways; add(hierarchy)
            XCTFail("Installer control must be visible above the keyboard and tappable: \(element.identifier)")
        }
        func tap(_ id: String, towardTop: Bool = false) {
            let button = app.buttons[id]; show(button, towardTop: towardTop); button.tap()
        }
        func fill(_ id: String, _ value: String, secure: Bool = false) {
            let field = secure ? app.secureTextFields[id] : app.textFields[id]
            show(field); field.tap(); field.typeText(value)
            let predicate = secure
                ? NSPredicate(format: "value.length == %d AND value != %@", value.count, field.placeholderValue ?? "")
                : NSPredicate(format: "value == %@", value)
            let entered = XCTNSPredicateExpectation(predicate: predicate, object: field)
            XCTAssertEqual(XCTWaiter.wait(for: [entered], timeout: 5), .completed,
                           "The requested field must contain the complete typed value: \(id)")
        }
        func toggle(_ id: String) {
            let control = app.switches[id]; show(control); control.tap()
        }
        XCTAssertTrue(app.textFields["installer.host"].waitForExistence(timeout: 10))
        capture(app, name: "beta-installer-address")
        fill("installer.host", "203.0.113.10")
        fill("installer.domain", "meet.example.org")
        tap("installer.inspect")
        XCTAssertTrue(app.switches["installer.trust"].waitForExistence(timeout: 10))
        capture(app, name: "beta-installer-fingerprint")
        toggle("installer.trust"); tap("installer.trustContinue")
        fill("installer.password", "12345678", secure: true)
        capture(app, name: "beta-installer-access")
        tap("installer.authenticate")
        XCTAssertTrue(app.buttons["installer.optionsNext"].waitForExistence(timeout: 10))
        capture(app, name: "beta-installer-diagnostics")
        tap("installer.optionsNext")
        XCTAssertTrue(app.textFields["installer.installDomain"].waitForExistence(timeout: 10))
        capture(app, name: "beta-installer-options")
        tap("installer.getPlan")
        fill("installer.adminPassword", "12345678", secure: true)
        fill("installer.adminRepeat", "12345678", secure: true)
        if app.switches["installer.confirmDocker"].exists { toggle("installer.confirmDocker") }
        toggle("installer.confirmACME"); toggle("installer.confirmPlan")
        capture(app, name: "beta-installer-plan")
        tap("installer.apply")
        XCTAssertTrue(app.buttons["installer.finish"].waitForExistence(timeout: 20))
        capture(app, name: "beta-installer-complete")
        // The fixture validates the actual signed plan/parser; it never contacts a VPS.
        tap("installer.close", towardTop: true)
        XCTAssertTrue(app.buttons["deployServer"].waitForExistence(timeout: 5))
    }

    func testBetaChatSelectionAndShare() {
        let app = launch(); login(app)
        let composer = app.textFields["messageComposer"]
        for text in ["Первое сообщение beta", "Второе сообщение beta"] {
            typeMessage(text, into: composer, in: app)
            app.buttons["sendMessage"].tap()
            XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 5))
        }
        app.buttons["chat.menu"].tap()
        app.buttons["message.selectMode"].tap()
        XCTAssertTrue(app.buttons["message.selectAll"].waitForExistence(timeout: 5))
        app.buttons["message.selectAll"].tap()
        XCTAssertTrue(app.buttons["message.shareSelected"].isEnabled)
        if app.frame.width >= 780 {
            let tab = app.buttons["tab.messages"]
            let remove = app.buttons["message.deleteSelected"]
            let keyboard = app.keyboards.firstMatch
            let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: keyboard)
            XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 8), .completed)
            let deadline = Date().addingTimeInterval(5)
            func toolbarGap() -> CGFloat { tab.frame.minY - remove.frame.maxY }
            while !(0...60).contains(toolbarGap()) && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            XCTAssertTrue((0...60).contains(toolbarGap()),
                          "The selection bar should sit above the tabs after the composer keyboard closes")
        }
        capture(app, name: "beta-chat-multiple-selection")
        app.buttons["message.shareSelected"].tap()
        // Copy the synthetic text from the real system sheet; no external recipient is used.
        let activity = app.otherElements["ActivityListView"].firstMatch
        XCTAssertTrue(activity.waitForExistence(timeout: 10))
        let copy = activity.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["Copy", "Скопировать", "Копировать"])).firstMatch
        // The iPhone 18 failure contains only ShareSheet.RemoteContainerView:
        // wait for the remote process to load its actual actions before scrolling.
        let actions = activity.collectionViews["activityCollectionView"].firstMatch
        let actionsDeadline = Date().addingTimeInterval(30)
        while Date() < actionsDeadline, !(copy.exists && copy.isHittable), !(actions.exists && actions.isHittable) {
            Thread.sleep(forTimeInterval: 0.2)
        }
        for _ in 0..<10 {
            if copy.exists && copy.isHittable { break }
            // Offscreen actions may be absent from AX until scrolled into view.
            // Keep this gesture inside the actual share sheet, away from chat history.
            XCTAssertTrue(actions.exists && actions.isHittable, "The system share sheet must load a scrollable activity collection")
            actions.swipeUp()
        }
        XCTAssertTrue(copy.exists && copy.isHittable, "Copy must be visible and tappable in the native share sheet")
        capture(app, name: "beta-chat-system-share")
        copy.tap()
        let shareDismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: activity)
        XCTAssertEqual(XCTWaiter.wait(for: [shareDismissed], timeout: 5), .completed, "Copy must dismiss the actual system share sheet")
        let remove = app.buttons["message.deleteSelected"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: remove)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        remove.tap()
        let confirm = app.buttons["message.confirmLocalDelete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        capture(app, name: "confirm-delete-selected")
        app.buttons["message.cancelLocalDelete"].tap()
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: remove)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed)
        for text in ["Первое сообщение beta", "Второе сообщение beta"] {
            let selected = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                            "message.select.", text)).firstMatch
            XCTAssertTrue(selected.exists)
            XCTAssertTrue((selected.value as? String)?.hasPrefix("Выбрано") == true)
        }
        remove.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.staticTexts["Первое сообщение beta"])
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
        XCTAssertFalse(app.staticTexts["Второе сообщение beta"].exists)
        capture(app, name: "beta-chat-after-local-removal")
    }

    func testWorkspaceMeetingTabs() {
        let app = launch(["-demo"])
        let first = app.buttons["meeting.1"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        capture(app, name: "workspace-meetings")
        let active = app.buttons["Активные"]
        reveal(active, in: app)
        active.tap()
        XCTAssertTrue(app.buttons["meeting.4"].waitForExistence(timeout: 5))
        XCTAssertFalse(first.exists)
        app.buttons["Завершённые"].tap()
        XCTAssertTrue(app.buttons["meeting.5"].waitForExistence(timeout: 5))
        app.buttons["Предстоящие"].tap()
        XCTAssertTrue(first.waitForExistence(timeout: 5))
    }

    func testRecordingLibraryDemoFiltersAndDeletion() {
        let app = launch(["-demo"])
        let library = app.buttons["Записи встреч"]
        XCTAssertTrue(library.waitForExistence(timeout: 5))
        library.tap()
        let count = app.staticTexts["recordings.count"]
        let tracks = app.buttons["recording.4"]
        let video = app.buttons["recording.0"]
        XCTAssertTrue(tracks.waitForExistence(timeout: 5))
        XCTAssertEqual(count.label, "Найдено: 5")
        XCTAssertLessThan(tracks.frame.minY, video.frame.minY)
        XCTAssertFalse(app.buttons["recording.delete.1"].exists)
        capture(app, name: "recordings-library-completed")

        app.buttons["recordings.live"].tap()
        XCTAssertTrue(app.buttons["recording.5"].waitForExistence(timeout: 5))
        XCTAssertEqual(count.label, "Найдено: 1")
        XCTAssertFalse(app.buttons["recording.delete.5"].exists)
        app.buttons["recordings.past"].tap()

        app.buttons["recordings.meeting"].tap()
        app.buttons["Продукт. Следующая глава"].tap()
        XCTAssertEqual(count.label, "Найдено: 2")
        app.buttons["recordings.sort"].tap()
        app.buttons["Сначала старые"].tap()
        XCTAssertLessThan(video.frame.minY, tracks.frame.minY)
        app.buttons["recordings.period"].tap()
        app.buttons["За 7 дней"].tap()
        XCTAssertEqual(count.label, "Найдено: 2")

        let search = app.textFields["recordings.search"]
        search.tap()
        search.typeText("zzzz\n")
        XCTAssertEqual(count.label, "Найдено: 0")
        let reset = app.buttons["recordings.reset"]
        reveal(reset, in: app)
        reset.tap()
        XCTAssertEqual(count.label, "Найдено: 5")

        let remove = app.buttons["recording.delete.3"]
        reveal(remove, in: app)
        remove.tap()
        XCTAssertTrue(app.buttons["Удалить запись"].waitForExistence(timeout: 5))
        app.buttons["Удалить запись"].tap()
        XCTAssertEqual(count.label, "Найдено: 4")
        XCTAssertFalse(app.buttons["recording.3"].exists)
        app.buttons["recordings.back"].tap()
        library.tap()
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertEqual(count.label, "Найдено: 4")
    }

    func testWorkspaceNotificationFiltersKeepTheirLabelsAndToggle() {
        let app = launch(["-demo"])
        let bell = app.buttons["Уведомления"]
        XCTAssertTrue(bell.waitForExistence(timeout: 10))
        bell.tap()
        let unread = app.buttons["workspaceInbox.unread"]
        reveal(unread, in: app)
        XCTAssertEqual(unread.label, "Непрочитанные")
        if app.frame.width >= 375 {
            XCTAssertGreaterThan(unread.frame.width, 105, "The unread filter must reserve room for its full title")
            XCTAssertLessThanOrEqual(unread.frame.height, 50, "The title should fit on one line at the default text size")
        }
        unread.tap()
        XCTAssertTrue(unread.isSelected)
        XCTAssertFalse(app.staticTexts["Вас упомянули в группе"].exists)
        capture(app, name: "workspace-notifications-unread")

        let readAll = app.buttons["workspaceInbox.readAll"]
        XCTAssertTrue(readAll.isHittable && readAll.isEnabled)
        readAll.tap()
        XCTAssertTrue(app.staticTexts["Всё прочитано"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(readAll.isEnabled)
        let all = app.buttons["workspaceInbox.all"]
        all.tap()
        XCTAssertTrue(all.isSelected)
    }

    func testMobileScheduleShowsSeparateDateAndTimeControls() {
        let app = launch()
        login(app)
        let meetings = app.buttons["tab.meetings"]
        XCTAssertTrue(meetings.waitForExistence(timeout: 10))
        meetings.tap()
        let schedule = app.buttons["scheduleMeeting"]
        XCTAssertTrue(schedule.waitForExistence(timeout: 10))
        schedule.tap()

        let close = app.buttons["schedule.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(close.frame.width, 44)
        XCTAssertGreaterThanOrEqual(close.frame.height, 44)
        for identifier in ["schedule.title", "schedule.date", "schedule.time"] {
            let control = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
            XCTAssertTrue(control.exists, "The schedule form must display \(identifier)")
            XCTAssertTrue(app.frame.insetBy(dx: -1, dy: -1).contains(control.frame))
        }
        XCTAssertFalse(app.buttons["schedule.submit"].isEnabled)
        capture(app, name: "workspace-schedule-form")
        close.tap()
        XCTAssertTrue(schedule.isHittable)
    }

    func testMobileDemoPrejoinAndConferenceLayout() {
        let app = launch(["-demo"])
        let profile = app.buttons["tab.profile"]
        XCTAssertTrue(profile.waitForExistence(timeout: 10))
        profile.tap()
        selectAccountSection("appearance", in: app)
        let catalog = app.buttons["profileMenu.demoCatalog"]
        revealEntireText(catalog, in: app)
        catalog.tap()
        let prejoin = app.buttons["Перед встречей"]
        reveal(prejoin, in: app)
        prejoin.tap()
        let join = app.buttons["conferencePreviewJoin"]
        reveal(join, in: app)
        capture(app, name: "demo-prejoin-mobile")
        join.tap()

        let speaker = app.buttons["conferenceLayoutSpeaker"]
        XCTAssertTrue(speaker.waitForExistence(timeout: 5))
        if app.frame.width < 780 { XCTAssertTrue(speaker.isSelected) }
        capture(app, name: "demo-conference-mobile")
        let gallery = app.buttons["conferenceLayoutGallery"]
        gallery.tap()
        XCTAssertTrue(gallery.isSelected)
        for identifier in ["conferenceMic", "conferenceCamera", "conferenceParticipants", "conferenceChat", "conferenceLeave"] {
            let control = app.buttons[identifier]
            XCTAssertTrue(control.isHittable)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44)
        }

        capture(app, name: "demo-conference-gallery")
        app.buttons["conferenceParticipantTile.maria"].tap()
        XCTAssertTrue(speaker.isSelected)
        let unpin = app.buttons["conferenceUnpin"]
        XCTAssertTrue(unpin.waitForExistence(timeout: 5))
        unpin.tap()
        gallery.tap()

        let recording = app.buttons["conferenceRecordings"]
        recording.tap()
        let composite = app.buttons["conferenceRecordingMode.composite"]
        let audio = app.buttons["conferenceRecordingMode.audio_only"]
        let tracks = app.buttons["conferenceRecordingMode.individual_tracks"]
        XCTAssertTrue(composite.waitForExistence(timeout: 5))
        XCTAssertTrue(composite.isSelected)
        if app.frame.width >= 375 {
            XCTAssertEqual(composite.frame.minY, audio.frame.minY, accuracy: 2)
            XCTAssertEqual(composite.frame.minX, tracks.frame.minX, accuracy: 2)
            XCTAssertGreaterThan(tracks.frame.minY, composite.frame.maxY)
        }
        capture(app, name: "demo-conference-recording-formats")
        audio.tap()
        XCTAssertTrue(audio.isSelected)
        let start = app.buttons["startServerRecording"]
        reveal(start, in: app)
        start.tap()
        let stop = app.buttons["conferenceRecordingStop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 6))
        let close = app.buttons["conferenceRecordingClose"]
        close.tap()
        waitForValue("Идёт запись", of: recording)
        recording.tap()
        XCTAssertTrue(app.staticTexts["Записывается: Только аудио"].exists)
        capture(app, name: "demo-conference-recording-active")
        stop.tap()
        app.buttons["conferenceRecordingCancelStop"].tap()
        XCTAssertTrue(stop.isHittable)
        stop.tap()
        app.buttons["conferenceRecordingConfirmStop"].tap()
        let open = app.buttons["conferenceRecordingOpen"]
        XCTAssertTrue(open.waitForExistence(timeout: 6))
        capture(app, name: "demo-conference-recording-ready")
        open.tap()
        let recordingTitle = app.staticTexts["recordingTitle"]
        XCTAssertTrue(recordingTitle.waitForExistence(timeout: 5))
        XCTAssertEqual(recordingTitle.label, "Дизайн-синхронизация")
        XCTAssertEqual(app.staticTexts["recordingKind"].label, "Аудиозапись")
    }

    func testForwardCommentFromAnnaToGroup() {
        let app = launch(["-demo"])
        let chats = app.buttons["tab.messages"]
        XCTAssertTrue(chats.waitForExistence(timeout: 5)); chats.tap()
        app.buttons["chat.0"].tap()
        let first = app.staticTexts["Доброе утро! Материалы к встрече готовы. Посмотрите, когда будет минутка."].firstMatch
        reveal(first, in: app, towardTop: true)
        first.tap()
        let forward = app.buttons["message.forwardAction"]
        XCTAssertFalse(forward.exists)
        first.press(forDuration: 0.6)
        XCTAssertFalse(forward.exists)
        first.press(forDuration: 1.1)
        XCTAssertTrue(forward.waitForExistence(timeout: 5))
        let actionable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: forward)
        XCTAssertEqual(XCTWaiter.wait(for: [actionable], timeout: 5), .completed)
        capture(app, name: "comment-actions")
        forward.tap()
        let group = app.buttons["message.forward.1"]
        XCTAssertTrue(group.waitForExistence(timeout: 5)); group.tap()
        let attribution = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Переслано")).firstMatch
        for _ in 0..<5 where !attribution.isHittable {
            let thread = app.scrollViews.containing(.staticText, identifier: "Сегодня, 16 октября").firstMatch
            if thread.exists { thread.swipeUp() } else { app.swipeUp() }
        }
        XCTAssertTrue(attribution.isHittable)
        capture(app, name: "forwarded-comment-group")
    }

    func testMessageAttachmentAndSelectionHaveIndependentTapTargets() {
        let app = launch(["-demo"])
        app.buttons["tab.messages"].tap()
        app.buttons["chat.0"].tap()

        let attachment = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Обзор продукта.pdf")).firstMatch
        reveal(attachment, in: app, towardTop: true)
        attachment.tap()
        XCTAssertTrue(app.staticTexts["Демонстрационная карточка вложения."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["message.forwardAction"].exists)
        app.buttons["Закрыть"].tap()

        let message = app.staticTexts["Доброе утро! Материалы к встрече готовы. Посмотрите, когда будет минутка."].firstMatch
        reveal(message, in: app, towardTop: true)
        message.press(forDuration: 1.1)
        let select = app.buttons["Выбрать"]
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        select.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                   "message.select.", "Обзор продукта.pdf")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(row.value as? String, "Выбрано")
        row.tap()
        XCTAssertEqual(row.value as? String, "Не выбрано")
        XCTAssertFalse(app.buttons["message.forwardAction"].exists)
        XCTAssertFalse(app.staticTexts["Демонстрационная карточка вложения."].exists)
    }

    func testAccountVideoSettingsLayoutAndPreferences() {
        let app = launch(); login(app)
        openProfile(in: app)
        selectAccountSection("video", in: app)
        let camera = app.buttons["video.camera"]
        XCTAssertTrue(camera.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["video.preview"].firstMatch.exists)
        capture(app, name: "account-video")
        camera.tap()
        app.buttons["Основная камера"].tap()
        let ownVideo = app.switches["video.selfVideo"]
        revealEntireText(ownVideo, in: app)
        let original = ownVideo.value as? String
        XCTAssertTrue(["0", "1"].contains(original ?? ""))
        ownVideo.tap()
        XCTAssertEqual(ownVideo.value as? String, original == "1" ? "0" : "1")
        XCTAssertTrue(app.switches["video.cameraOff"].exists)
        XCTAssertTrue(app.switches["video.hideVideo"].exists)
        selectAccountSection("video", in: app)
        XCTAssertEqual(camera.value as? String, "Основная камера")
        revealEntireText(ownVideo, in: app)
        XCTAssertEqual(ownVideo.value as? String, original == "1" ? "0" : "1")
        ownVideo.tap()
        reveal(camera, in: app, towardTop: true)
        camera.tap()
        app.buttons["По умолчанию"].tap()
        XCTAssertFalse(app.staticTexts["Настройки применяются автоматически."].exists)
    }

    func testDemoConnectionValidatesAndKeepsAddress() {
        let app = launch(["-demo"])
        openProfile(in: app)
        selectAccountSection("connection", in: app)
        let address = app.textFields["accountConnectionAddress"]
        let save = app.buttons["accountConnectionSave"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled)
        capture(app, name: "account-connection-demo")
        func replaceAddress(with text: String) {
            address.tap()
            let value = address.value as? String ?? ""
            address.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count) + text)
        }
        replaceAddress(with: "http://team.example.org")
        XCTAssertFalse(save.isEnabled)
        XCTAssertTrue(app.staticTexts["accountConnectionError"].exists)
        replaceAddress(with: "https://team.example.org/")
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.staticTexts["accountConnectionSaved"].waitForExistence(timeout: 5))
        selectAccountSection("connection", in: app)
        XCTAssertEqual(address.value as? String, "https://team.example.org")
        XCTAssertFalse(save.isEnabled)
    }

    func testBetaAudioSettingsLayout() {
        let app = launch(); login(app)
        openProfile(in: app)
        capture(app, name: "account-settings-menu")
        let version = app.staticTexts["account.version"]
        revealEntireText(version, in: app)
        XCTAssertNotNil(version.label.range(of: #"^Версия [0-9]+(?:[.][0-9]+)+ · сборка [0-9]+$"#, options: .regularExpression))
        XCTAssertGreaterThanOrEqual(version.frame.minY, app.buttons["account.logout"].frame.maxY)
        for extra in ["openCalendar", "openRecordings", "openFolders", "openAccountSettings", "openDeleteAccount", "openComponentLicenses"] {
            XCTAssertFalse(app.buttons[extra].exists)
        }
        XCTAssertFalse(app.switches["pushNotificationsToggle"].exists)
        capture(app, name: "account-settings-version")
        let audio = app.buttons["profileMenu.audio"]
        revealEntireText(audio, in: app); audio.tap()
        XCTAssertTrue(app.staticTexts["Микрофон"].firstMatch.waitForExistence(timeout: 5))
        capture(app, name: "beta-audio-microphone")
        for identifier in ["audio.mutedOnJoin", "audio.noiseSuppression"] {
            let toggle = app.switches[identifier]
            revealEntireText(toggle, in: app)
            XCTAssertGreaterThanOrEqual(toggle.frame.height, 44)
            let original = toggle.value as? String
            XCTAssertTrue(original == "1" || original == "0")
            // The track is compact and tapping the text should work as well.
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
            XCTAssertEqual(toggle.value as? String, original == "1" ? "0" : "1")
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
            XCTAssertEqual(toggle.value as? String, original)
        }
        capture(app, name: "beta-audio-compact-switches")
        let signals = app.staticTexts["Звонки и уведомления"].firstMatch
        revealEntireText(signals, in: app)
        XCTAssertFalse(app.staticTexts["Настройки применяются автоматически."].exists)
        capture(app, name: "beta-audio-speaker-signals")
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

    private func openMeetingsFeature(_ identifier: String, in app: XCUIApplication) {
        let link = app.buttons[identifier]
        tapAfterLogin(app.buttons["tab.meetings"], in: app, expecting: link, unchanged: { !link.exists })
        revealEntireText(link, in: app)
        XCTAssertGreaterThanOrEqual(link.frame.height, 44)
        link.tap()
    }

    private func selectAccountSection(_ section: String, in app: XCUIApplication) {
        let back = app.buttons["profileMenu.back"]
        if back.exists { back.tap() }
        let row = app.buttons["profileMenu." + section]
        revealEntireText(row, in: app)
        row.tap()
    }

    private func openProfile(in app: XCUIApplication) {
        let tab = app.buttons["tab.profile"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tapAfterLogin(tab, in: app, expecting: app.buttons["profileMenu.profile"],
                      unchanged: { !app.buttons["profileMenu.profile"].exists })
    }

    /// iOS 26 can present Passwords during XCTest's 60-second event-synthesis wait.
    /// Retry only an observed, unapplied navigation/answer action after that exact sheet.
    /// Never use this helper for send/delete/toggle or other repeatable server mutations.
    private func tapAfterLogin(_ control: XCUIElement, in app: XCUIApplication,
                               expecting target: XCUIElement, unchanged: () -> Bool) {
        control.tap()
        if target.waitForExistence(timeout: 10) { return }
        if unchanged(), let decline = passwordDismissButton(app), decline.isHittable {
            capture(app, name: "late-password-prompt-before-unapplied-action-retry")
            decline.tap()
            let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: decline)
            XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 10), .completed)
            // Recheck state after dismissal: a delayed successful action must not repeat.
            if !target.exists && unchanged() { control.tap() }
        }
        XCTAssertTrue(target.waitForExistence(timeout: 10), "The requested transition must complete")
    }

    private func contentViewport(for element: XCUIElement, in app: XCUIApplication) -> CGRect {
        contentViewport(identifier: element.identifier, label: element.label, in: app)
    }

    private func contentViewport(identifier id: String, label: String, in app: XCUIApplication) -> CGRect {
        var frame = app.frame
        if app.navigationBars.firstMatch.exists {
            let top = app.navigationBars.firstMatch.frame.maxY
            frame = frame.intersection(CGRect(x: frame.minX, y: top, width: frame.width, height: max(0, frame.maxY - top)))
        }
        if app.buttons["tab.profile"].exists {
            frame.size.height = max(0, min(frame.maxY, app.buttons["tab.profile"].frame.minY) - frame.minY)
        }
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

    private struct AuditFinding {
        let auditType: XCUIAccessibilityAuditType
        let summary: String
        let detail: String
        let identifier: String
        let label: String
        let frame: CGRect?
    }

    func testAccessibilityStage08CoreScreens() throws {
        let app = launch()
        var issues: [[String: String]] = []
        var attempts: [[String: Any]] = []
        var passID = 0
        func attachAttempts() {
            guard let data = try? JSONSerialization.data(withJSONObject:
                ["schemaVersion": 1, "attempts": attempts], options: [.prettyPrinted, .sortedKeys]) else { return }
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "stage08-audit-attempts"; attachment.lifetime = .keepAlways; add(attachment)
        }
        func reviewedCase(_ issue: AuditFinding, screen: String, viewport: CGRect?) -> String? {
            let id = issue.identifier
            let label = issue.label
            if screen == "settings", issue.auditType == .contrast, id == "saveProfile",
               app.buttons["saveProfile"].exists, !app.buttons["saveProfile"].isEnabled {
                return "reviewed: unchanged profile; disabled save action (inactive-control contrast exemption)"
            }
            if screen == "calendar", issue.auditType == .contrast,
               ["calendar.weekday.0", "calendar.weekday.4"].contains(id),
               let frame = issue.frame, viewport?.contains(frame) == true {
                return "reviewed: actual opaque glyph/background pixels; ACCESSIBILITY_CONTRAST_REVIEW.md"
            }
            if issue.auditType == .contrast, let frame = issue.frame, viewport?.contains(frame) == true {
                let statusIDs = Set((1...4).map { "recording.status.77777777-7777-4777-8777-77777777777\($0)" })
                if (screen == "welcome" && (id == "welcome.deploySubtitle" ||
                    (label == "Создать пространство на своём VPS" && app.buttons["deployServer"].frame.contains(frame)))) ||
                    (screen == "calendar" && id == "calendar.weekSummaryHeading") ||
                    (screen == "folders" && id == "folders.subtitle") ||
                    (screen == "recordings" && statusIDs.contains(id)) {
                    return "reviewed: opaque glyph cores exceed 4.5:1 in actual PNG; ACCESSIBILITY_IPAD_CONTRAST.md"
                }
                if screen == "messages", label == "Выберите чат", app.frame.width >= 800,
                   frame.minX > 340, frame.height > 50 {
                    return "reviewed: native empty-state node groups decorative icon with high-contrast title"
                }
                if screen == "settings", label == "ПЕ", abs(frame.width - 40) < 1,
                   abs(frame.height - 40) < 1, frame.maxX < 300,
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
            if screen == "messages", label == "ТЕ", let frame = issue.frame,
               abs(frame.width - 44) < 1, abs(frame.height - 44) < 1,
               issue.auditType == .contrast || issue.auditType == .dynamicType {
                let row = app.buttons["conversation.22222222-2222-4222-8222-222222222222"]
                if row.exists, row.frame.contains(frame), row.label.contains("Тестовый собеседник") {
                    return "reviewed: decorative avatar initials; accessible row has the full name"
                }
            }
            guard issue.auditType == .dynamicType,
                  issue.summary == "Dynamic Type font sizes are partially unsupported" else { return nil }
            let menus: [String: [String: String]] = [
                "calendar": ["Все встречи": "calendar.scope", "GMT": "calendar.timeZone"]]
            if let controlID = menus[screen]?[label], let frame = issue.frame,
               app.buttons[controlID].exists, app.buttons[controlID].frame.contains(frame) {
                return "reviewed: menu title inside exact control; measured font scaling and AX5 multiline layout"
            }
            let exact: [String: Set<String>] = [
                "messages": ["messages.connectionStatus"],
                "calendar": ["calendar.heading", "calendar.periodTitle", "calendar.today", "calendar.scopeTitle", "calendar.timeZoneTitle"],
                "folders": ["folders.subtitle"]]
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
            if let tabID = tabs[label], let frame = issue.frame,
               app.buttons[tabID].frame.contains(frame) {
                return "reviewed: measured custom-font scaling; uncapped multiline tab label"
            }
            return nil
        }
        func record(_ issue: AuditFinding, screen: String, resolution: String?) {
            issues.append(["screen": screen, "type": String(issue.auditType.rawValue),
                           "summary": issue.summary, "detail": issue.detail,
                           "element": issue.identifier, "label": issue.label,
                           "frame": issue.frame.map { String(describing: $0) } ?? "",
                           "resolution": resolution ?? "unresolved"])
        }
        func collect(_ category: XCUIAccessibilityAuditType, screen: String) throws -> [AuditFinding] {
            passID += 1
            let names: [(XCUIAccessibilityAuditType, String)] = [(.contrast, "contrast"),
                (.elementDetection, "elementDetection"), (.hitRegion, "hitRegion"),
                (.sufficientElementDescription, "sufficientElementDescription"), (.trait, "trait"),
                (.dynamicType, "dynamicType"), (.textClipped, "textClipped")]
            let categoryName = names.first { $0.0 == category }?.1 ?? "unknown"
            for attempt in 1...2 {
                var findings: [AuditFinding] = []
                var callbackCount = 0
                let startedAt = ISO8601DateFormatter().string(from: Date())
                let started = ProcessInfo.processInfo.systemUptime
                var receipt: [String: Any] = ["passID": passID, "screen": screen,
                    "categoryRawValue": category.rawValue, "categoryName": categoryName,
                    "phase": screen.hasSuffix("-visible-retest") ? "visibleRetest" : "initial", "attempt": attempt,
                    "startedAtUTC": startedAt, "settleSecondsBeforeAttempt": attempt == 1 ? 0 : 2]
                do {
                    try XCTContext.runActivity(named: "Audit \(screen) \(categoryName) attempt \(attempt)") { _ in
                        try app.performAccessibilityAudit(for: category) { issue in
                            callbackCount += 1
                            // One immutable snapshot; never traverse the app or evaluate
                            // review predicates while the audit engine waits for its callback.
                            let snapshot = try? issue.element?.snapshot()
                            findings.append(AuditFinding(auditType: issue.auditType,
                                summary: issue.compactDescription, detail: issue.detailedDescription,
                                identifier: snapshot?.identifier ?? "", label: snapshot?.label ?? "",
                                frame: snapshot?.frame))
                            return true
                        }
                    }
                    receipt.merge(["outcome": "completed", "callbackCount": callbackCount,
                        "findingsCount": findings.count, "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
                        "retryDecision": "none"]) { _, value in value }
                    attempts.append(receipt)
                    return findings
                } catch {
                    let engineError = error as NSError
                    // CI14 proved a Dynamic Type timeout can leave trait changes in
                    // flight; immediately starting another such audit is not a reset.
                    // Preserve that error and fail instead of overlapping those passes.
                    let retry = attempt == 1 && category == .elementDetection && callbackCount == 0 && findings.isEmpty &&
                        engineError.domain == "com.apple.xcode.xctest.accessibilityAudit" && engineError.code == -56
                    receipt.merge(["outcome": "engineError", "callbackCount": callbackCount,
                        "findingsCount": findings.count, "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
                        "error": ["domain": engineError.domain, "code": engineError.code,
                                  "description": engineError.localizedDescription],
                        "retryDecision": retry ? "retryAfterSettle" : "throw"]) { _, value in value }
                    attempts.append(receipt)
                    attachAttempts()
                    if retry {
                        // CI10/14 timed out inside Apple's element-detection engine
                        // before any callback. Repeat that same pass once, preserving
                        // the failed attempt; never waive a finding or change the viewport.
                        Thread.sleep(forTimeInterval: 2)
                        continue
                    }
                    for finding in findings { record(finding, screen: screen, resolution: nil) }
                    attachIssues()
                    throw error
                }
            }
            preconditionFailure("Every audit attempt returns findings or throws")
        }
        func contrastViewport(_ issue: AuditFinding) -> CGRect? {
            guard issue.auditType == .contrast, issue.frame != nil else { return nil }
            return self.contentViewport(identifier: issue.identifier, label: issue.label, in: app)
        }
        func audit(_ screen: String) throws {
            var deferred: [(Int, String)] = []
            capture(app, name: "stage08-accessibility-" + screen)
            // Audit contrast before the engine changes Dynamic Type. Keep the categories
            // separate so each pass sees a settled layout after the preceding trait change.
            let categories: [XCUIAccessibilityAuditType] = [.contrast, .elementDetection, .hitRegion,
                .sufficientElementDescription, .trait, .dynamicType, .textClipped]
            for category in categories {
                let findings = try collect(category, screen: screen)
                Thread.sleep(forTimeInterval: 0.5)
                // Resolve frozen fields only after Apple's audit has returned. Hierarchy
                // lookups here cannot hold the audit callback open.
                for issue in findings {
                    let viewport = contrastViewport(issue)
                    var resolution = reviewedCase(issue, screen: screen, viewport: viewport)
                    if issue.auditType == .contrast, let frame = issue.frame,
                       !issue.identifier.isEmpty, viewport?.contains(frame) != true {
                        resolution = "deferred: outside scroll viewport; requires fully visible retest"
                        deferred.append((issues.count, issue.identifier))
                    }
                    record(issue, screen: screen, resolution: resolution)
                }
            }
            // Contrast cannot be measured from pixels clipped by a scroll container or
            // covered by persistent chrome. Revisit each identified initial finding in view.
            for (index, identifier) in deferred {
                let target = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
                revealEntireText(target, in: app)
                capture(app, name: "stage08-accessibility-\(screen)-visible-\(identifier)")
                var targetFailed = false, targetSeen = false
                let findings = try collect(.contrast, screen: screen + "-visible-retest")
                Thread.sleep(forTimeInterval: 0.5)
                for issue in findings {
                    let isTarget = issue.identifier == identifier
                    if isTarget { targetSeen = true }
                    let viewport = contrastViewport(issue)
                    var resolution = reviewedCase(issue, screen: screen, viewport: viewport)
                    if isTarget && resolution == nil { targetFailed = true }
                    if !isTarget, let frame = issue.frame, viewport?.contains(frame) != true {
                        resolution = "outside retest viewport: no contrast measurement"
                    }
                    record(issue, screen: screen + "-visible-retest", resolution: resolution)
                }
                issues[index]["resolution"] = targetFailed ? "retest failed; see unresolved finding" :
                    targetSeen ? "reviewed: fully visible retest produced a reviewed finding" :
                    "verified: fully visible contrast retest produced no target finding"
            }
            if let data = try? JSONSerialization.data(withJSONObject: issues, options: [.prettyPrinted, .sortedKeys]) {
                let progress = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                progress.name = "stage08-audit-progress-" + screen; progress.lifetime = .keepAlways; add(progress)
            }
            attachAttempts()
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
        openProfile(in: app)
        XCTAssertTrue(app.buttons["profileMenu.accounts"].waitForExistence(timeout: 5))
        try audit("profile")
        openMeetingsFeature("meetingsCalendar", in: app)
        XCTAssertTrue(app.segmentedControls["calendar.mode"].waitForExistence(timeout: 10))
        try audit("calendar")
        app.navigationBars.buttons.firstMatch.tap()
        openMeetingsFeature("meetingsRecordings", in: app)
        XCTAssertTrue(app.buttons["recording.77777777-7777-4777-8777-777777777771"].waitForExistence(timeout: 10))
        try audit("recordings")
        app.buttons["recordings.back"].tap()
        openMeetingsFeature("meetingsFolders", in: app)
        XCTAssertTrue(app.buttons["createFolder"].waitForExistence(timeout: 5))
        try audit("folders")
        app.navigationBars.buttons.firstMatch.tap()
        openProfile(in: app)
        selectAccountSection("profile", in: app)
        XCTAssertTrue(app.textFields["profileDisplayName"].waitForExistence(timeout: 5))
        try audit("settings")
        // XCTest can stop a failing test before Swift defer executes. Save evidence first.
        attachIssues()
        let unresolved = issues.filter { $0["resolution"] == "unresolved" || $0["resolution"]?.hasPrefix("deferred:") == true }
        XCTAssertTrue(unresolved.isEmpty, "Unresolved accessibility issues: \(unresolved)")
    }

    func testStage08AccountDeletionRequiresPasswordAndConfirmation() {
        let app = launch(); login(app)
        openProfile(in: app)
        selectAccountSection("accounts", in: app)
        let remove = app.buttons["openDeleteAccount"]
        revealEntireText(remove, in: app)
        remove.tap()
        let password = app.secureTextFields["deleteAccount.password"]
        let submit = app.buttons["deleteAccount.submit"]
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        XCTAssertFalse(submit.isEnabled)
        func enterPassword(_ value: String) {
            password.tap()
            let keyboard = app.keyboards.firstMatch
            XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
            // The app is Russian, while these fixtures contain Latin letters. CI's
            // Russian secure keyboard silently discarded synthetic Latin typeText
            // events. Select the real Latin keyboard and tap its actual keys.
            let latinLayout = keyboard.keys.matching(NSPredicate(format:
                "label == %@", "Переключиться с латинских клавиш")).firstMatch
            if !keyboard.keys["f"].exists && latinLayout.exists {
                // CI15/16 iPad secure keyboards expose a separate visible “abc” key
                // with this exact AX label; the emoji button only cycled RU/Emoji.
                latinLayout.tap()
                XCTAssertTrue(keyboard.keys["f"].waitForExistence(timeout: 5))
            } else {
                for _ in 0..<4 where !keyboard.keys["f"].exists {
                    // On iOS 26 this system button is a sibling of Keyboard, not its child.
                    let next = app.buttons.matching(NSPredicate(format:
                        "identifier == %@ OR label IN %@", "emoji", ["Следующая клавиатура", "Next keyboard"])).firstMatch
                    XCTAssertTrue(next.waitForExistence(timeout: 5)); next.tap()
                }
            }
            XCTAssertTrue(keyboard.keys["f"].waitForExistence(timeout: 5))
            capture(app, name: "stage08-account-deletion-keyboard-" + (value == "fixture-password" ? "retry" : "initial"))
            // Use XCTest's native typing only after observing the Latin layout.
            // Manual numeric-mode taps triggered an iPad tutorial whose visible
            // text was absent from optimized AX queries in CI15. This still enters
            // the unchanged password through the real SecureField and strict fixture.
            password.typeText(value)
            let entered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: submit)
            XCTAssertEqual(XCTWaiter.wait(for: [entered], timeout: 5), .completed)
            let done = keyboard.buttons.matching(identifier: "Done").firstMatch
            XCTAssertTrue(done.waitForExistence(timeout: 5)); done.tap()
        }
        enterPassword("incorrect-password")
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
        enterPassword("fixture-password")
        reveal(submit, in: app); capture(app, name: "stage08-account-deletion")
        submit.tap(); XCTAssertTrue(confirmation.waitForExistence(timeout: 5)); confirmation.tap()
        // Ending the session keeps the configured server and returns to its login form.
        XCTAssertTrue(app.buttons["authenticationSubmit"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Аккаунт удалён на сервере."].waitForExistence(timeout: 5))
        XCTAssertFalse(password.exists)
        XCTAssertFalse(app.buttons["tab.messages"].exists)
        capture(app, name: "stage08-account-deletion-success")
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
        revealEntireText(app.buttons["conversation.22222222-2222-4222-8222-222222222222"], in: app)
        capture(app, name: "stage08-large-text-messages-conversation")
        app.buttons["tab.profile"].tap()
        capture(app, name: "stage08-large-text-profile")
        for (identifier, title) in [("meetingsCalendar", "calendar"), ("meetingsRecordings", "recordings"),
                                    ("meetingsFolders", "folders")] {
            openMeetingsFeature(identifier, in: app)
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
            if title == "recordings" { app.buttons["recordings.back"].tap() }
            else { app.navigationBars.buttons.firstMatch.tap() }
        }
        openProfile(in: app)
        selectAccountSection("profile", in: app)
        capture(app, name: "stage08-large-text-settings")
    }

    func testStage07CalendarCreateRescheduleCancelAndViews() {
        let app = launch(); login(app)
        openMeetingsFeature("meetingsCalendar", in: app)
        let schedule = app.buttons["calendar.schedule"]
        XCTAssertTrue(schedule.waitForExistence(timeout: 10)); schedule.tap()
        let title = app.textFields["schedule.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let close = app.buttons["schedule.close"]
        XCTAssertTrue(close.isHittable)
        XCTAssertGreaterThanOrEqual(close.frame.width, 44)
        XCTAssertTrue(app.descendants(matching: .any)["schedule.date"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["schedule.time"].firstMatch.exists)
        capture(app, name: "workspace-phone-schedule-form")
        title.tap(); title.typeText("План команды\n")
        let submit = app.buttons["schedule.submit"]; reveal(submit, in: app); submit.tap()
        let event = app.buttons["calendar.event.33333333-3333-4333-8333-333333333333"]
        reveal(app.segmentedControls["calendar.mode"], in: app, towardTop: true)
        capture(app, name: "stage07-calendar-week")
        reveal(event, in: app)
        capture(app, name: "stage07-calendar-agenda")
        event.tap(); app.buttons["calendar.reschedule"].tap()
        let duration = app.steppers["schedule.duration"]
        XCTAssertTrue(duration.waitForExistence(timeout: 5)); duration.buttons.element(boundBy: 1).tap()
        waitForValue("35", of: duration)
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
        openMeetingsFeature("meetingsFolders", in: app)
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
        openProfile(in: app)
        selectAccountSection("profile", in: app)
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
        selectAccountSection("notifications", in: app)
        XCTAssertTrue(app.switches["notificationInvitation"].waitForExistence(timeout: 5))
        capture(app, name: "account-notifications")
        let sound = app.buttons["notificationTestSound"]
        let soundSwitch = app.switches["notificationSound"]
        revealEntireText(sound, in: app)
        if soundSwitch.value as? String == "0" { soundSwitch.tap() }
        sound.tap()
        XCTAssertTrue(sound.label.contains("Воспроизводится"))
        soundSwitch.tap()
        XCTAssertFalse(sound.isEnabled)
        let toggle = app.switches["notificationEmail"]
        reveal(toggle, in: app)
        let control = toggle.switches.firstMatch
        if control.isHittable { control.tap() } else { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        let saveNotifications = app.buttons["saveNotificationPreferences"]; reveal(saveNotifications, in: app); saveNotifications.tap()
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Настройки уведомлений сохранены"), object: app.staticTexts["settingsSaved"])
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 5), .completed)
        selectAccountSection("notifications", in: app)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        XCTAssertEqual(soundSwitch.value as? String, "0")
        revealEntireText(soundSwitch, in: app); soundSwitch.tap()
        capture(app, name: "stage07-settings-notifications")
        selectAccountSection("connection", in: app)
        let address = app.textFields["accountConnectionAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        XCTAssertEqual(address.value as? String, "https://fixture.example")
        XCTAssertFalse(app.buttons["accountConnectionSave"].isEnabled)
        capture(app, name: "account-connection")
        let details = app.buttons["accountConnectionDetails"]
        revealEntireText(details, in: app); details.tap()
        XCTAssertTrue(app.staticTexts["installerAvailable"].waitForExistence(timeout: 5))
        capture(app, name: "stage07-settings-server")
    }

    func testStage07RecordingsStatusAndNativePlayerWithLocalFixture() {
        let app = launch(); login(app)
        openMeetingsFeature("meetingsRecordings", in: app)
        let ready = app.buttons["recording.77777777-7777-4777-8777-777777777771"]
        XCTAssertTrue(ready.waitForExistence(timeout: 10)); capture(app, name: "stage07-recordings")
        let processing = app.buttons["recording.77777777-7777-4777-8777-777777777772"]
        reveal(processing, in: app); processing.tap()
        XCTAssertTrue(app.staticTexts["recordingStatus"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["recordingStatus"].label, "Обрабатывается")
        XCTAssertFalse(app.buttons["playRecording"].exists)
        capture(app, name: "recording-detail-processing")
        app.buttons["Все записи"].tap()
        reveal(ready, in: app, towardTop: true); ready.tap()
        XCTAssertTrue(app.staticTexts["recordingKind"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["recordingKind"].label, "Видеозапись")
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
        XCTAssertTrue(app.staticTexts["recordingKind"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["recordingKind"].label, "Аудиозапись")
        capture(app, name: "recording-detail-audio")
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
        openMeetingsFeature("meetingsRecordings", in: app)
        let ready = app.buttons["recording.77777777-7777-4777-8777-777777777771"]
        reveal(ready, in: app); ready.tap()
        XCTAssertTrue(app.staticTexts["recordingsError"].waitForExistence(timeout: 5))
        let errorVisible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: app.staticTexts["recordingsError"])
        XCTAssertEqual(XCTWaiter.wait(for: [errorVisible], timeout: 5), .completed)
        XCTAssertLessThan(app.staticTexts["recordingsError"].frame.maxY, app.buttons["tab.profile"].frame.minY)
        XCTAssertFalse(app.buttons["playRecording"].exists)
        XCTAssertFalse(app.buttons["downloadRecording"].exists)
        XCTAssertTrue(app.buttons["recording.retry"].isEnabled)
        app.buttons["recording.retry"].tap()
        XCTAssertTrue(app.staticTexts["recordingsError"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["downloadRecording"].exists)
        capture(app, name: "stage07-recording-denied")
    }

    func testRecordingDetailDemoTracksAndMaterials() {
        let app = launch(["-demo"])
        let library = app.buttons["meetingsRecordings"]
        reveal(library, in: app)
        library.tap()
        let tracks = app.buttons["recording.4"]
        reveal(tracks, in: app)
        tracks.tap()
        let title = app.staticTexts["recordingTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "Продукт. Следующая глава")
        XCTAssertEqual(app.staticTexts["recordingKind"].label, "Дорожки участников")
        XCTAssertTrue(app.staticTexts["Отдельная дорожка каждого участника"].isHittable)
        XCTAssertFalse(app.buttons["playRecording"].exists)
        capture(app, name: "recording-detail-tracks")
        let summary = app.buttons["recording.shareDetails"]
        reveal(summary, in: app)
        XCTAssertTrue(app.staticTexts["Архив дорожек"].isHittable)
        XCTAssertFalse(app.buttons["downloadRecording"].exists)
        capture(app, name: "recording-detail-materials")
        app.buttons["recordings.back"].tap()
        XCTAssertTrue(tracks.waitForExistence(timeout: 5))
    }

    func testFirstLaunchDoesNotImplyAuthentication() {
        let app = launch()
        XCTAssertTrue(app.buttons["connectServer"].waitForExistence(timeout: 10))
        capture(app, name: "welcome-light")
        XCTAssertFalse(app.staticTexts["demoBanner"].exists)
        let demo = revealDemoLink(app)
        XCTAssertTrue(demo.isHittable); demo.tap()
        XCTAssertTrue(app.buttons["meetingsCalendar"].waitForExistence(timeout: 5))
        capture(app, name: "meetings-light")
        app.buttons["tab.messages"].tap()
        XCTAssertTrue(app.buttons["chat.0"].waitForExistence(timeout: 5))
        capture(app, name: "messages-light")
        app.buttons["tab.profile"].tap()
        XCTAssertTrue(app.buttons["profileMenu.accounts"].waitForExistence(timeout: 5))
        capture(app, name: "profile-light")
        let exit = app.buttons["exitDemo"]
        reveal(exit, in: app)
        exit.tap()
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
        XCTAssertFalse(app.staticTexts["Адрес сервера"].exists)
        XCTAssertFalse(app.staticTexts["fixture.example"].exists)
        XCTAssertFalse(app.staticTexts["Подключено"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["messages.connectionStatus"].exists)
        let unreadFilter = app.buttons["messages.filter.unread"]
        XCTAssertTrue(unreadFilter.exists)
        XCTAssertTrue(unreadFilter.label.contains("0"))
        let invitation = app.buttons["messages.invite"]
        XCTAssertTrue(invitation.exists)
        // XCTest can report only the centered label inside the prototype's 52-point filter bar.
        let filterBarBottom = unreadFilter.frame.midY + 26
        XCTAssertEqual(invitation.frame.minY - filterBarBottom, 16, accuracy: 3)
        capture(app, name: "stage03-live-chats")
        let composer = app.textFields["messageComposer"]
        typeMessage("Проверка сообщения", into: composer, in: app)
        app.buttons["sendMessage"].tap()
        let sent = app.staticTexts["Проверка сообщения"]
        XCTAssertTrue(sent.waitForExistence(timeout: 5))
        capture(app, name: "stage03-live-thread")
        sent.tap()
        let closeActions = app.buttons["Закрыть действия с сообщением"]
        XCTAssertFalse(closeActions.exists)
        sent.press(forDuration: 1.1)
        XCTAssertTrue(closeActions.waitForExistence(timeout: 5))
        for action in ["Ответить", "Переслать", "Редактировать", "Удалить для всех"] {
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", action)).firstMatch.exists, action)
        }
        closeActions.tap()
        XCTAssertTrue(closeActions.waitForNonExistence(timeout: 5))
        if !app.buttons["tab.profile"].isHittable { app.buttons["chat.back"].tap() }
        app.buttons["tab.profile"].tap()
        XCTAssertTrue(app.buttons["profileMenu.accounts"].waitForExistence(timeout: 5))
        capture(app, name: "stage03-live-profile")
        let signOut = app.buttons["account.logout"]
        reveal(signOut, in: app)
        signOut.tap()
        let logout = app.buttons["Выйти"]
        XCTAssertTrue(logout.waitForExistence(timeout: 5)); logout.tap()
        XCTAssertTrue(app.secureTextFields["Пароль"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["tab.messages"].exists)
    }

    private func openFixtureChatForTyping(in app: XCUIApplication) -> XCUIElement {
        let chat = app.buttons["conversation.22222222-2222-4222-8222-222222222222"]
        let composer = app.textFields["messageComposer"]
        let keyboard = app.keyboards.firstMatch
        let deadline = Date().addingTimeInterval(30)
        var tappedRow = false, tappedComposer = false
        while Date() < deadline {
            // The cold Passwords process can appear after login has returned:
            // iPhone 18 intercepts the row tap, iPhone 26 intercepts composer focus.
            // Retry a tap only after declining that exact observed system prompt.
            if let decline = passwordDismissButton(app), decline.isHittable {
                decline.tap(); tappedRow = false; tappedComposer = false
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }
            if composer.exists && composer.isHittable {
                if tappedComposer && keyboard.exists { return composer }
                if !tappedComposer {
                    composer.tap(); tappedComposer = true
                    continue
                }
            } else if !tappedRow && chat.exists && chat.isHittable {
                chat.tap(); tappedRow = true
                continue
            }
            if dismissInaccessiblePasswordPrompt(app) {
                tappedRow = false; tappedComposer = false
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        capture(app, name: "chat-navigation-or-focus-blocked")
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "chat-navigation-or-focus-hierarchy"
        hierarchy.lifetime = .keepAlways; add(hierarchy)
        XCTFail("The fixture conversation must open and its composer must show the keyboard")
        return composer
    }

    private func typeMessage(_ text: String, into composer: XCUIElement, in app: XCUIApplication) {
        // Sending may dismiss the keyboard; focus the real field for each message.
        _ = openFixtureChatForTyping(in: app)
        XCTAssertTrue(composer.isHittable)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "The composer must have opened the keyboard before typing")
        composer.typeText(text)
        let entered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", text), object: composer)
        XCTAssertEqual(XCTWaiter.wait(for: [entered], timeout: 5), .completed,
                       "The composer must contain the complete message before sending")
    }

    func testCreateGroupWithSelectedMember() {
        let app = launch(); login(app)
        let newChat = app.buttons["newChat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 10)); newChat.tap()
        let group = app.buttons["newConversation.group"]
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        let close = app.buttons["newConversation.close"]
        XCTAssertTrue(close.isHittable)
        XCTAssertGreaterThanOrEqual(close.frame.width, 44)
        capture(app, name: "workspace-phone-new-conversation")
        group.tap()
        let name = app.textFields["newConversation.groupName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Команда iOS")
        let peer = app.buttons["peer.11111111-1111-4111-8111-111111111113"]
        reveal(peer, in: app); peer.tap()
        let create = app.buttons["createConversation"]
        reveal(create, in: app); create.tap()
        XCTAssertTrue(app.staticTexts["Команда iOS"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["messageComposer"].waitForExistence(timeout: 10))
        app.buttons["chat.menu"].tap()
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
        // SwiftUI on iPadOS 27 can expose nested AX representations of the same action.
        let confirm = app.buttons["conferenceConfirmLeave"].firstMatch
        let confirmationReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: confirm)
        XCTAssertEqual(XCTWaiter.wait(for: [confirmationReady], timeout: 8), .completed)
        confirm.tap()
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

        let gallery = app.buttons["conferenceLayoutGallery"]
        let speaker = app.buttons["conferenceLayoutSpeaker"]
        reveal(gallery, in: app)
        XCTAssertTrue(speaker.exists)
        gallery.tap()
        XCTAssertTrue(gallery.isSelected)
        capture(app, name: "conference-gallery")
        speaker.tap()
        XCTAssertTrue(speaker.isSelected)
        capture(app, name: "conference-speaker")

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
        // Closing the chat moves the media controls as the keyboard disappears.
        // Wait for that transition before resolving the camera's tap position.
        let chatClosed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: heading)
        let keyboardClosed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [chatClosed, keyboardClosed], timeout: 10), .completed)
        XCTAssertTrue(camera.isEnabled && camera.isHittable)
        camera.tap(); waitForValue("Выключен", of: camera)
        leaveConference(app)
    }

    func testConferenceRecordingOffersServerFormatsAndStopsWithConfirmation() {
        let app = launch()
        createConference(app, title: "Дизайн-синхронизация")
        joinConference(app)
        let recording = app.buttons["conferenceRecordings"]
        XCTAssertTrue(recording.waitForExistence(timeout: 10))
        recording.tap()
        let composite = app.buttons["conferenceRecordingMode.composite"]
        let audio = app.buttons["conferenceRecordingMode.audio_only"]
        XCTAssertTrue(composite.waitForExistence(timeout: 10))
        XCTAssertTrue(composite.isSelected)
        XCTAssertFalse(app.buttons["conferenceRecordingMode.individual_tracks"].exists)
        audio.tap()
        XCTAssertTrue(audio.isSelected)
        capture(app, name: "conference-recording-server-formats")
        app.buttons["startServerRecording"].tap()
        let stop = app.buttons["conferenceRecordingStop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        stop.tap()
        let confirm = app.buttons["conferenceRecordingConfirmStop"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let status = app.staticTexts["conferenceRecordingStatus"]
        let processing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS[c] %@", "обрабат"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [processing], timeout: 10), .completed)
        app.buttons["conferenceRecordingClose"].tap()
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

    private func answerIncomingCall(_ app: XCUIApplication, acceptedElsewhere: Bool = false) {
        let answer = callControl(app, "directCallAnswer")
        let target = acceptedElsewhere ? app.staticTexts["Звонок продолжается на другом устройстве."] : app.buttons["directCallMic"]
        tapAfterLogin(answer, in: app, expecting: target, unchanged: { answer.exists && answer.isEnabled })
    }

    /// DEBUG CallKit, REST and SFU doubles exercise application state; this is not a device VoIP test.
    func testDirectIncomingAnswerControlsMinimizeAndEnd() {
        let app = launch(["-call-incoming"]); login(app)
        XCTAssertTrue(app.buttons["directCallAnswer"].waitForExistence(timeout: 10))
        capture(app, name: "stage05-incoming")
        answerIncomingCall(app)
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
        let heading = app.staticTexts["Чаты"].firstMatch
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
        app.buttons["conferenceReconnect"].tap()
        let mediaOptions = app.buttons["conferenceMediaOptions"]
        XCTAssertTrue(mediaOptions.waitForExistence(timeout: 5)); mediaOptions.tap()
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
        app.buttons["conferenceMediaOptionsClose"].tap()
        leaveConference(app)
    }

    func testScreenConflictKeepsDirectCallAndMicrophoneWithFixtures() {
        let app = launch(["-call-incoming", "-screen-conflict"]); login(app)
        answerIncomingCall(app)
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
        XCTAssertTrue(audioCall.isHittable)
        audioCall.tap()
        XCTAssertTrue(app.staticTexts["screen.directCall"].waitForExistence(timeout: 10))
        capture(app, name: "stage05-outgoing")
        XCTAssertFalse(app.buttons["directCallAnswer"].exists)
        callControl(app, "directCallEnd").tap()
        XCTAssertTrue(app.buttons["directCallDone"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["directCallStatus"].label, "Вызов отменён")
        callControl(app, "directCallDone").tap()
        XCTAssertTrue(app.textFields["messageComposer"].waitForExistence(timeout: 10))
        app.buttons["chat.menu"].tap()
        XCTAssertTrue(videoCall.waitForExistence(timeout: 5) && videoCall.isHittable)
    }

    func testDirectCallAcceptedOnOtherDeviceHasNoCaptureControls() {
        let app = launch(["-call-incoming", "-call-other-device"]); login(app)
        answerIncomingCall(app, acceptedElsewhere: true)
        XCTAssertTrue(app.staticTexts["Звонок продолжается на другом устройстве."].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["directCallMic"].exists)
        XCTAssertFalse(app.buttons["directCallCamera"].exists)
        XCTAssertFalse(app.buttons["directCallEnd"].exists)
        capture(app, name: "stage05-other-device")
    }

    func testOrdinaryPushOptInAndDisableWithFixtureToken() {
        let app = launch(); login(app)
        openProfile(in: app)
        if app.frame.width >= 780 {
            XCTAssertTrue(app.staticTexts["Ваш профиль"].firstMatch.waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["profileMenu.back"].exists)
        }
        capture(app, name: app.frame.width >= 780 ? "account-home-tablet" : "account-home-phone")
        selectAccountSection("notifications", in: app)
        let devices = app.buttons["notificationDevicesDetails"]
        revealEntireText(devices, in: app); devices.tap()
        let toggle = app.switches["pushNotificationsToggle"]
        revealEntireText(toggle, in: app)
        XCTAssertTrue(toggle.isHittable)
        func tapToggle() {
            if toggle.switches.firstMatch.isHittable { toggle.switches.firstMatch.tap() }
            else { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        }
        tapToggle()
        let registered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Токен сохранён сервером"),
            object: app.staticTexts["pushNotificationsStatus"])
        XCTAssertEqual(XCTWaiter.wait(for: [registered], timeout: 10), .completed)
        let status = app.staticTexts["pushNotificationsStatus"]
        revealEntireText(status, in: app)
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
        XCTAssertTrue(app.buttons["tab.profile"].waitForExistence(timeout: 5))
        XCTAssertLessThan(app.buttons["tab.profile"].frame.height,
                          app.frame.height / 4, "Persistent controls must leave space for large-text content")
        app.buttons["tab.profile"].tap()
        let appearance = app.buttons["profileMenu.appearance"]
        for _ in 0..<4 where !appearance.isHittable { app.swipeUp() }
        XCTAssertTrue(appearance.isHittable); appearance.tap()
        let dark = app.buttons["appearance.dark"]
        XCTAssertTrue(dark.waitForExistence(timeout: 5))
        for _ in 0..<4 where !dark.isHittable { app.swipeUp() }
        XCTAssertTrue(dark.isHittable); dark.tap()
        XCTAssertTrue(dark.isSelected)
        capture(app, name: "appearance-dark-large-text")
        let back = app.buttons["profileMenu.back"]
        XCTAssertTrue(back.isHittable)
        XCTAssertGreaterThanOrEqual(back.frame.height, 44)
        back.tap()
        XCTAssertTrue(app.buttons["profileMenu.profile"].waitForExistence(timeout: 5))
    }
}
