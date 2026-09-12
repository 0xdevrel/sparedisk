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
    @MainActor
    func testMapKeyboardSelectionReplacesClickedCell() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestFixture"]
        app.launch()
        let open = app.buttons["Open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 20))
        open.click()
        let map = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Map")).firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 5))
        map.click()

        let big = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "map-cell-", "/big.bin")).firstMatch
        let folder = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "map-cell-", "/Nested")).firstMatch
        XCTAssertTrue(big.waitForExistence(timeout: 5))
        big.click()
        waitForSelection(big, "Selected")
        // Keep the pointer over the clicked cell while navigating by keyboard.
        app.typeKey(.rightArrow, modifierFlags: [])
        waitForSelection(folder, "Selected")
        waitForSelection(big, "Not selected")
        app.typeKey(.leftArrow, modifierFlags: [])
        waitForSelection(big, "Selected")
        waitForSelection(folder, "Not selected")
        app.typeKey(.rightArrow, modifierFlags: [])
        // Return must open the newly selected folder, not the clicked file.
        app.typeKey(.return, modifierFlags: [])
        let medium = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "map-cell-", "/medium.bin")).firstMatch
        XCTAssertTrue(medium.waitForExistence(timeout: 5))
        XCTAssertFalse(big.exists)
    }

    @MainActor
    private func waitForSelection(_ element: XCUIElement, _ value: String) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }

}
