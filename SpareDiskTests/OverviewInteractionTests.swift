import Foundation
import CoreGraphics
import Testing
@testable import SpareDisk

struct OverviewInteractionTests {
    private func location(_ id: String) -> SDLocation {
        SDLocation(id: id, name: "Test", symbol: "folder", isExternal: false, access: .available,
                   capacityBytes: 100, availableBytes: 20, scannedBytes: 0, scannedAt: Date(), issues: 0)
    }

    @Test @MainActor func overviewLabelsFollowScanCoverage() {
        let app = AppState()
        #expect(app.overviewScanTitle == "Scan My Mac…")
        app.locations = [location("/test")]
        #expect(app.overviewScanTitle == "Scan")
        app.scans["/test"] = ScanResult(locationID: "/test", rootName: "Test", totalBytes: 0, itemCount: 0,
                                       topNodes: [], issues: [], startedAt: Date(), finishedAt: Date(), wasCancelled: false)
        #expect(app.overviewScanTitle == "Rescan")
        app.locations.append(location("/other"))
        #expect(app.overviewScanTitle == "Scan")
    }

    @Test @MainActor func individualScanQueuesWithoutInterruptingAnotherLocation() {
        let app = AppState()
        app.locations = [location("/a"), location("/b")]
        app.scanningLocationID = "/a"
        app.scanLocation(id: "/b")
        app.scanLocation(id: "/b")
        #expect(app.scanningLocationID == "/a")
        #expect(app.scanQueue == ["/b"])
        app.cancelAllScans()
        #expect(app.scanQueue.isEmpty)
    }

    @Test @MainActor func overviewScansAllSavedGrants() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("OverviewTest-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let app = AppState()
        for name in ["a", "b"] {
            let url = root.appendingPathComponent(name)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            _ = LocationAccessService.grantTransient(url)
            app.locations.append(location(url.path))
        }
        await app.scanOverview()
        while app.isScanning { await app.scanTask?.value }
        #expect(app.scans.count == 2)
        #expect(app.scanQueue.isEmpty)
        #expect(app.overviewScanTitle == "Rescan")
        for loc in app.locations { ScanStore.remove(locationID: loc.id) }
    }

    @Test func donutHitTestingTracksClockwiseSegmentsAndExcludesHole() {
        let box = CGRect(x: 10, y: 20, width: 200, height: 200)
        #expect(StorageDonutHitTest.index(at: CGPoint(x: 200, y: 120), in: box, weights: [50, 50]) == 0)
        #expect(StorageDonutHitTest.index(at: CGPoint(x: 20, y: 120), in: box, weights: [50, 50]) == 1)
        #expect(StorageDonutHitTest.index(at: CGPoint(x: 110, y: 120), in: box, weights: [50, 50]) == nil)
        #expect(StorageDonutHitTest.index(at: CGPoint(x: 220, y: 120), in: box, weights: [50, 50]) == nil)
        #expect(StorageDonutHitTest.index(at: CGPoint(x: 200, y: 120), in: box, weights: [0, 0]) == nil)
    }
}
