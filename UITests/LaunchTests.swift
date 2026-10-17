import XCTest

final class LaunchTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testEmptyServerShowsSetupAndDisablesConnect() {
        let app = XCUIApplication()
        app.launchArguments = ["-brokerAddress", "", "-interfaceLanguage", "ru"]
        app.launch()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 15))
        let connect = app.buttons["Подключить Apple TV"]
        XCTAssertTrue(connect.exists)
        XCTAssertFalse(connect.isEnabled)
        recordScreenshot(app, name: "server-setup")
    }

    func testRestoredHTTPAddressReturnsToSetupWithError() {
        let app = XCUIApplication()
        app.launchArguments = ["-brokerAddress", "http://insecure.invalid", "-interfaceLanguage", "ru"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Проверьте введённые данные."].waitForExistence(timeout: 15))
        XCTAssertTrue(app.textFields.firstMatch.exists)
        XCTAssertTrue(app.buttons["Подключить Apple TV"].exists)
        recordScreenshot(app, name: "http-address-rejected")
    }

    func testBackFromServerSetupReturnsHome() {
        let app = XCUIApplication()
        app.launchArguments = ["-brokerAddress", "", "-interfaceLanguage", "ru"]
        app.launch()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 15))
        XCUIRemote.shared.press(.menu)
        let background = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state != .runningForeground
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [background], timeout: 5), .completed)
    }

}

extension XCTestCase {
    func recordScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
