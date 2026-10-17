import XCTest

final class ParityTests: XCTestCase {
    private var application: XCUIApplication?

    override func tearDownWithError() throws {
        if let application, (testRun?.failureCount ?? 0) > 0 {
            recordScreenshot(application, name: "parity-failure")
        }
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        let ready = expectation(description: "Fixture broker has a trusted HTTPS connection")
        var available = false
        #if UI_FIXTURE_HOST
        let session = FixtureProtocol.session()
        #else
        let session = URLSession.shared
        #endif
        session.dataTask(with: URL(string: "https://localhost:18765/health")!) { data, response, _ in
            available = (response as? HTTPURLResponse)?.statusCode == 200 && data != nil
            ready.fulfill()
        }.resume()
        wait(for: [ready], timeout: 10)
        guard available else { throw XCTSkip("Run ./scripts/test-ui.sh to start the local HTTPS fixtures.") }
    }

    func testReaderBackRestoresTheSelectedCard() {
        let app = linkedApplication()
        let card = app.buttons["post:flight-academy:p-reader"]
        activate(card, in: app)
        XCTAssertTrue(app.descendants(matching: .any)["post-reader"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Remote reading"].exists)
        recordScreenshot(app, name: "reader")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.descendants(matching: .any)["library-root"].waitForExistence(timeout: 10))
        XCTAssertTrue(card.exists)
        XCTAssertTrue(card.hasFocus, "Returning from the reader should restore the selected post.")
    }

    func testArticleLinksAndFilesOpenPhoneQR() {
        let app = linkedApplication()
        activate(app.buttons["post:flight-academy:p-reader"], in: app)
        activate(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Mission handbook")).firstMatch, in: app)
        XCTAssertTrue(app.descendants(matching: .any)["phone-link-qr"].waitForExistence(timeout: 10))
        recordScreenshot(app, name: "phone-link")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.descendants(matching: .any)["post-reader"].waitForExistence(timeout: 10))
        activate(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Flight checklist.pdf")).firstMatch, in: app)
        XCTAssertTrue(app.descendants(matching: .any)["phone-link-qr"].waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.descendants(matching: .any)["post-reader"].waitForExistence(timeout: 10))
    }

    func testReaderScrollsPastTopLinksThroughTheWholeArticle() {
        let app = linkedApplication()
        activate(app.buttons["post:flight-academy:p-reader"], in: app)
        let middle = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Telemetry checkpoint 09.")).firstMatch
        XCTAssertTrue(middle.waitForExistence(timeout: 10))
        XCTAssertLessThan(middle.frame.height, app.frame.height - 120,
                          "Each reading focus target must fit on screen instead of trapping focus on an oversized text block.")
        for _ in 0..<24 {
            if middle.hasFocus { break }
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(middle.hasFocus, "Down must reach the middle of an article after the links.")
        recordScreenshot(app, name: "reader-middle")
        let end = app.staticTexts["End of mission reading notes."]
        for _ in 0..<12 {
            if end.hasFocus { break }
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(end.hasFocus)
        XCTAssertTrue(app.frame.contains(end.frame))
        recordScreenshot(app, name: "reader-end")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.descendants(matching: .any)["library-root"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["post:flight-academy:p-reader"].hasFocus)
    }

    func testChapterPreviewAndPlaybackNavigation() {
        let app = linkedApplication()
        activate(app.buttons["post:flight-academy:p-video"], in: app)
        let chapter = app.buttons["chapter:orbital-video:30"]
        focus(chapter, in: app)
        let preview = app.descendants(matching: .any)["frame-preview"]
        XCTAssertTrue(preview.images.firstMatch.waitForExistence(timeout: 10))
        recordScreenshot(app, name: "chapter-preview")
        XCUIRemote.shared.press(.select)
        openPlayerTools(in: app)
        XCTAssertTrue(app.staticTexts["Launch sequence"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Orbit insertion"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Return home"].firstMatch.exists)
        recordScreenshot(app, name: "named-timeline-segments")
        let toggle = app.buttons["player-toggle"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            toggle.exists && toggle.isEnabled
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        if toggle.label == "Resume" { activate(toggle, in: app) }
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            toggle.isEnabled && toggle.label == "Pause"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 30), .completed)
        XCUIRemote.shared.press(.playPause)
        let paused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", "Pause"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 5), .completed)
        let pausedLabel = toggle.label
        activate(app.buttons["player-quality"], in: app)
        let quality = app.descendants(matching: .any)["player-quality:high"]
        XCTAssertTrue(quality.waitForExistence(timeout: 5), app.debugDescription)
        activate(quality, in: app)
        XCTAssertTrue(app.staticTexts["720p"].waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.label, pausedLabel)
        XCTAssertTrue(app.buttons["player-scrub"].waitForExistence(timeout: 10))
        activate(app.buttons["player-scrub"], in: app)
        activate(app.buttons["scrub-forward"], in: app)
        XCTAssertTrue(app.descendants(matching: .any)["frame-preview"].waitForExistence(timeout: 10))
        recordScreenshot(app, name: "scrub-preview")
        XCUIRemote.shared.press(.menu)
        let cancelled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["scrub-confirm"])
        XCTAssertEqual(XCTWaiter.wait(for: [cancelled], timeout: 3), .completed,
                       "Back cancels the selected position without leaving playback.")
        if !app.buttons["player-close"].exists { openPlayerTools(in: app) }
        XCTAssertTrue(app.buttons["player-close"].exists)
        activate(app.buttons["player-close"], in: app)
        XCTAssertTrue(app.descendants(matching: .any)["post-reader"].waitForExistence(timeout: 10))
    }

    func testAutomaticPaginationAndBackKeepTheLastLoadedCard() {
        let app = linkedApplication()
        let card = app.buttons["post:deep-space-lab:p-note-24"]
        focus(card, in: app)
        recordScreenshot(app, name: "paginated-library")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.descendants(matching: .any)["post-reader"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Mission log 24"].exists)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(card.hasFocus)
    }

    func testLanguageSwitchKeepsTheLibrary() {
        let app = linkedApplication()
        activate(app.buttons["library-account"], in: app)
        let russian = app.descendants(matching: .any)["language-ru"]
        XCTAssertTrue(russian.waitForExistence(timeout: 5), app.debugDescription)
        activate(russian, in: app)
        XCTAssertTrue(app.staticTexts["Публикации ваших авторов"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["library-root"].exists)
        XCTAssertTrue(app.buttons["post:flight-academy:p-video"].exists)
        activate(app.buttons["library-account"], in: app)
        let english = app.descendants(matching: .any)["language-en"]
        XCTAssertTrue(english.waitForExistence(timeout: 5), app.debugDescription)
        activate(english, in: app)
        XCTAssertTrue(app.staticTexts["Posts from your creators"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["library-root"].exists)
        XCTAssertTrue(app.buttons["post:flight-academy:p-video"].exists)
    }

    func testBackFromLibraryReturnsHomeWithoutDisconnecting() {
        let app = linkedApplication()
        XCUIRemote.shared.press(.menu)
        let background = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state != .runningForeground
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [background], timeout: 5), .completed)
        app.activate()
        XCTAssertTrue(app.descendants(matching: .any)["library-root"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields.firstMatch.exists)
    }

    func testProfileHasExplicitServerDisconnectWithConfirmation() {
        let app = linkedApplication()
        activate(app.buttons["library-account"], in: app)
        let disconnect = app.descendants(matching: .any)["library-disconnect"]
        XCTAssertTrue(disconnect.waitForExistence(timeout: 5))
        activate(disconnect, in: app)
        activate(app.buttons["disconnect-cancel"], in: app)
        XCTAssertTrue(app.descendants(matching: .any)["library-root"].exists)
        XCTAssertFalse(app.textFields.firstMatch.exists)
        activate(app.buttons["library-account"], in: app)
        activate(disconnect, in: app)
        activate(app.buttons["disconnect-confirm"], in: app)
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Connect Apple TV"].exists)
    }

    private func linkedApplication() -> XCUIApplication {
        let app = XCUIApplication()
        application = app
        app.launchArguments = ["-brokerAddress", "https://localhost:18765", "-interfaceLanguage", "en"]
        app.launch()
        let library = app.descendants(matching: .any)["library-root"]
        let confirmation = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "my profile")).firstMatch
        if !library.waitForExistence(timeout: 3) {
            XCTAssertTrue(confirmation.waitForExistence(timeout: 15), app.debugDescription)
            activate(confirmation, in: app)
        }
        XCTAssertTrue(library.waitForExistence(timeout: 15), app.debugDescription)
        recordScreenshot(app, name: "library")
        return app
    }

    private func activate(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in element.isEnabled }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 30), .completed,
                       "Control must finish preparing before it can be activated: \(element.identifier)")
        focus(element, in: app)
        XCUIRemote.shared.press(.select)
    }

    private func openPlayerTools(in app: XCUIApplication) {
        let tools = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ OR label == %@", "player-controls", "Video controls")).firstMatch
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(tools.waitForExistence(timeout: 10), app.debugDescription)
        XCUIRemote.shared.press(.up)
        recordScreenshot(app, name: "native-transport")
        activate(tools, in: app)
        XCTAssertTrue(app.buttons["player-scrub"].waitForExistence(timeout: 10))
        recordScreenshot(app, name: "player-tools")
    }

    private func focus(_ element: XCUIElement, in app: XCUIApplication) {
        var previousFocus = ""
        var previousDirection: XCUIRemote.Button?
        for _ in 0..<45 {
            if element.exists && (element.hasFocus || element.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch.exists) { return }
            let focusedButton = app.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch
            let focusedCell = app.cells.matching(NSPredicate(format: "hasFocus == true")).firstMatch
            let current = focusedButton.exists ? focusedButton : focusedCell.exists ? focusedCell : app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
            guard element.exists, current.exists else {
                XCUIRemote.shared.press(.down)
                continue
            }
            if current.elementType == .cell || current.elementType == .button,
               !element.identifier.isEmpty,
               current.descendants(matching: .any)[element.identifier].exists { return }
            let destination = element.frame
            let origin = current.frame
            if element.elementType == .cell, current.elementType == .other {
                XCUIRemote.shared.press(.up)
                continue
            }
            if origin.isEmpty {
                XCUIRemote.shared.press(.up)
                continue
            }
            let dx = destination.midX - origin.midX
            let dy = destination.midY - origin.midY
            let focusID = "\(current.identifier)|\(current.label)|\(origin)"
            var direction: XCUIRemote.Button
            if abs(dy) > max(origin.height, destination.height) * 0.6 {
                direction = dy > 0 ? .down : .up
            } else {
                direction = dx > 0 ? .right : .left
            }
            if focusID == previousFocus, previousDirection == direction {
                direction = direction == .up || direction == .down
                    ? (dx > 0 ? .right : .left) : (dy > 0 ? .down : .up)
            }
            previousFocus = focusID
            previousDirection = direction
            XCUIRemote.shared.press(direction)
        }
        XCTFail("Unable to focus the requested control: \(app.debugDescription)")
    }
}
