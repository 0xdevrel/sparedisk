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
        XCTAssertTrue(app.buttons["Move 1 Item to Trash"].firstMatch.exists)
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

    @MainActor
    func testMyMacOffersRescanAndKeepsOverviewVisible() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestFixture"]
        app.launch()
        let rescan = app.windows.firstMatch.buttons["overview-scan"]
        XCTAssertTrue(rescan.waitForExistence(timeout: 20))
        XCTAssertEqual(rescan.label, "Rescan")
        let donut = app.windows.firstMatch.descendants(matching: .any).matching(identifier: "storage-donut").firstMatch
        XCTAssertTrue(donut.exists)
        let initialLabel = donut.label
        donut.coordinate(withNormalizedOffset: CGVector(dx: 0.84, dy: 0.5)).hover()
        let hovered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "Other used,"), object: donut)
        XCTAssertEqual(XCTWaiter.wait(for: [hovered], timeout: 5), .completed)
        donut.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        let cleared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", initialLabel), object: donut)
        XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 5), .completed)
        rescan.click()
        XCTAssertTrue(rescan.waitForExistence(timeout: 20))
        XCTAssertEqual(rescan.label, "Rescan")
        XCTAssertTrue(app.buttons["Open"].firstMatch.exists)
    }

    @MainActor
    func testFirstRunScanRequiresFolderChoiceAndCancelIsSafe() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestFixture", "-uiTestFirstLaunch"]
        app.launch()
        let scan = app.windows.firstMatch.buttons["overview-scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 10))
        XCTAssertEqual(scan.label, "Scan My Mac")
        XCTAssertFalse(app.windows.firstMatch.buttons["overview-cancel-scans"].exists)
        scan.click()
        let cancel = app.windows.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.click()
        XCTAssertTrue(scan.waitForExistence(timeout: 10))
        XCTAssertEqual(scan.label, "Scan My Mac")
        XCTAssertFalse(app.windows.firstMatch.buttons["overview-cancel-scans"].exists)
    }

    /// Direct Move to Trash from the inspector: confirm the alert and the
    /// status bar must report a move, not silence.
    @MainActor
    func testDirectTrashFromInspectorMovesFile() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestFixture"]
        app.launch()
        let open = app.buttons["Open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 20))
        open.click()
        let small = app.staticTexts["small.txt"].firstMatch
        XCTAssertTrue(small.waitForExistence(timeout: 15))
        small.click()
        let trash = app.buttons["Move to Trash"].firstMatch
        XCTAssertTrue(trash.waitForExistence(timeout: 5))
        trash.click()
        let confirm = app.sheets.firstMatch.buttons["Move to Trash"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "confirmation alert appears")
        confirm.click()
        // The status bar exposes its text as the element's value. The runner
        // is sandboxed, so the fixture folder itself cannot be inspected here.
        let moved = app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@ OR label BEGINSWITH %@", "Moved 1 item", "Moved 1 item")).firstMatch
        XCTAssertTrue(moved.waitForExistence(timeout: 15), "status bar reports the move")
    }
}
