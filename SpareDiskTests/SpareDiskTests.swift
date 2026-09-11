import AppKit
import Testing
@testable import SpareDisk

@MainActor
struct SpareDiskTests {
    @Test func navigationRestoresLocationAndInvalidatesForwardHistory() {
        let app = AppState()
        app.selection = .location("/tmp/fixture")
        app.selection = .largeFiles
        app.goBack()
        #expect(app.selection == .location("/tmp/fixture"))
        #expect(app.activeLocationID == "/tmp/fixture")
        #expect(app.canGoForward)
        app.selection = .olderFiles
        #expect(!app.canGoForward)
        app.goBack()
        app.goBack()
        #expect(app.selection == .overview)
    }

    @Test func sampleItemsCannotEnterCleanupQueue() {
        let app = AppState()
        let sample = MockData.largeFiles[0]
        app.toggleReview(sample, source: "Test")
        #expect(app.reviewItems.isEmpty)
        app.locations = MockData.locations
        app.toggleReview(sample, source: "Test")
        #expect(app.reviewItems.isEmpty)
    }

    @Test func inspectorRequiresSelectionAndOpensOnSelection() {
        let app = AppState()
        #expect(app.inspectedNode == nil)
        #expect(!app.showInspector)
        app.inspectedNodeID = MockData.topLevel[0].id
        #expect(app.inspectedNode?.id == MockData.topLevel[0].id)
        #expect(app.showInspector)
        app.selection = .olderFiles
        #expect(app.inspectedNode == nil)
    }

    @Test func largeFilesSymbolExistsOnSupportedSystem() {
        #expect(NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: nil) != nil)
    }
}
