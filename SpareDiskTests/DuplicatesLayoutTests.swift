import AppKit
import SwiftUI
import Testing
@testable import SpareDisk

@MainActor
struct DuplicatesLayoutTests {
    @Test func contentChangesDoNotChangeTheColumnsMinimumSize() async throws {
        let app = AppState()
        let host = NSHostingView(rootView: DuplicatesView().environment(app))
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
        for state in 0..<6 {
            app.duplicateRunning = state == 1 || state == 2
            app.duplicateBytesTotal = state == 2 ? 4_000_000 : 0
            app.duplicateBytesDone = state == 2 ? 1_000_000 : 0
            app.duplicateCurrent = copies[0].name
            app.duplicateGroups = state >= 3
                ? [DuplicateGroup(id: "group", digestHex: "digest", bytesPerFile: 2_000_000, files: copies)] : []
            app.viewMode = state == 4 ? .map : state == 5 ? .sunburst : .list
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
