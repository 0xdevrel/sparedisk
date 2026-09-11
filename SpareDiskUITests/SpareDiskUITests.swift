import XCTest

/// End-to-end flow on a disposable fixture: open a location from the
/// sidebar, select a file, stage it for review, and see it in the queue.
final class SpareDiskUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSelectFileAndAddToReview() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestFixture"]
        app.launch()

        // Overview lists the location too; open it through its Open button,
        // which exists only once the scan has finished.
        let open = app.buttons["Open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 20), "fixture location scanned and listed on Overview")
        open.click()

        let bigFile = app.staticTexts["big.bin"].firstMatch
        XCTAssertTrue(bigFile.waitForExistence(timeout: 15), "scanned rows appear")
        bigFile.click()

        // Inspector shows the selection.
        XCTAssertTrue(app.staticTexts["3 MB"].firstMatch.waitForExistence(timeout: 5))

        let add = app.buttons["Add to Review"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5), "inspector offers Add to Review")
        add.click()
        XCTAssertTrue(app.buttons["Remove"].firstMatch.waitForExistence(timeout: 5), "inspector flips to Remove")

        app.staticTexts["Review Cleanup"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["big.bin"].firstMatch.waitForExistence(timeout: 5), "queued item listed")
        XCTAssertTrue(app.buttons["Move 1 Item to Trash…"].firstMatch.exists)
    }
}
