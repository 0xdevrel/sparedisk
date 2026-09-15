import AppKit
import SwiftUI
import Testing
@testable import SpareDisk

/// The detail column of the main split view must never report a
/// content-dependent minimum size. When it did, progress ticks during a
/// duplicate scan re-entered AppKit's update-constraints pass and the app
/// aborted in `_postWindowNeedsUpdateConstraints`.
@MainActor
struct DuplicatesLayoutTests {
    @Test func contentChangesDoNotChangeTheColumnsMinimumSize() async throws {
        let app = AppState()
        let host = NSHostingView(rootView: CenterView().environment(app))
        host.frame = CGRect(x: 0, y: 0, width: 380, height: 620)
        host.layoutSubtreeIfNeeded()
        let minimum = host.fittingSize

        app.locations = [SDLocation(id: "/fixture", name: "Fixture", symbol: "folder",
            isExternal: false, access: .available, capacityBytes: 100, availableBytes: 20,
            scannedBytes: 80, scannedAt: Date(), issues: 0)]
        let copies = ["a", "b"].map { id in
            ScanNode(id: id, name: String(repeating: "long filename ", count: 12) + id,
                path: "/fixture/\(id)", isFolder: false, category: .documents,
                logicalBytes: 2_000_000, modified: Date(), childCount: 0)
        }
        for state in 0..<9 {
            // States 0-5 walk the Duplicates screen; 6-8 exercise the other
            // screens and the status bar, which share the same column.
            app.selection = state < 6 ? .duplicates : state == 6 ? .overview : state == 7 ? .location("/fixture") : .review
            app.duplicateRunning = state == 1 || state == 2
            app.duplicateBytesTotal = state == 2 ? 4_000_000 : 0
            app.duplicateBytesDone = state == 2 ? 1_000_000 : 0
            app.duplicateCurrent = copies[0].name
            app.duplicateGroups = state >= 3 && state < 6
                ? [DuplicateGroup(id: "group", digestHex: "digest", bytesPerFile: 2_000_000, files: copies)] : []
            app.viewMode = state == 4 ? .map : state == 5 ? .sunburst : .list
            app.scanningLocationID = state == 6 || state == 7 ? "/fixture" : nil
            app.scanProgress = state == 6 || state == 7
                ? ScanProgress(itemsFound: 123_456 * state, elapsed: 3, currentPath: copies[0].path) : nil
            app.cleanupRunning = state == 8
            app.cleanupCurrent = state == 8 ? copies[1].name : nil
            for width in [380.0, 620.0, 900.0] {
                host.setFrameSize(NSSize(width: width, height: 620))
                // Allow Observation's view update before measuring AppKit's
                // minimum-size proposal, including native List/ProgressView.
                try await Task.sleep(for: .milliseconds(30))
                host.layoutSubtreeIfNeeded()
                #expect(abs(host.fittingSize.width - minimum.width) < 1)
                #expect(abs(host.fittingSize.height - minimum.height) < 1)
            }
        }
    }
}
