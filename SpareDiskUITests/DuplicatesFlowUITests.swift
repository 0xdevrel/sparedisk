import XCTest

final class DuplicatesFlowUITests: XCTestCase {
    @MainActor
    func testRepeatedComparisonsAndReview() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestFixture", "-uiTestDuplicates", "-windowSize", "1280x800"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Open"].firstMatch.waitForExistence(timeout: 20))
        app.staticTexts["Duplicates"].firstMatch.click()
        let find = app.buttons["Find Duplicates"]
        XCTAssertTrue(find.waitForExistence(timeout: 10))
        find.click()
        let again = app.buttons["Find Again"]
        XCTAssertTrue(again.waitForExistence(timeout: 20))
        for mode in ["Map", "Sunburst", "List"] {
            app.buttons["Toggle Inspector"].click()
            let view = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", mode)).firstMatch
            XCTAssertTrue(view.waitForExistence(timeout: 5))
            view.click()
            again.click()
            XCTAssertTrue(again.waitForExistence(timeout: 20))
            XCTAssertEqual(app.state, .runningForeground)
        }
        let stage = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Stage the Rest for Review")).firstMatch
        XCTAssertTrue(stage.waitForExistence(timeout: 10))
        stage.click()
        app.staticTexts["Review Cleanup"].firstMatch.click()
        XCTAssertTrue(app.buttons["Move 1 Item to Trash"].waitForExistence(timeout: 10))
    }
}
