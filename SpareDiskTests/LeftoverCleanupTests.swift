import Foundation
import Testing
@testable import SpareDisk

struct LeftoverCleanupTests {
    @Test @MainActor func freshlyMeasuredLeftoversUseTheirOwnBaselineAndBatchReportsEveryItem() async throws {
        let fm = FileManager.default
        let root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LeftoverCleanupTest-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let folders = ["one", "two"].map { root.appendingPathComponent($0) }
        for folder in folders {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 100).write(to: folder.appendingPathComponent("cache.bin"))
        }
        let started = Date()
        var nodes: [ScanNode] = []
        for folder in folders {
            let st = try #require(ScanEngine.lstat(path: folder.path))
            let scan = await ScanEngine.scan(locationID: folder.path, rootName: "Test", root: folder) { _ in }
            nodes.append(ScanNode(id: "leftover#" + folder.path, name: folder.lastPathComponent, path: folder.path,
                                  isFolder: true, category: .system, logicalBytes: scan.totalBytes, modified: st.modified,
                                  childCount: scan.itemCount, fsFileNumber: st.ino, fsVolumeNumber: st.dev))
        }
        let app = AppState()
        app.locations = [SDLocation(id: root.path, name: "Test", symbol: "folder", isExternal: false,
                                    access: .available, capacityBytes: 1000, availableBytes: 500,
                                    scannedBytes: 200, scannedAt: Date(), issues: 0)]
        _ = LocationAccessService.grantTransient(root)
        app.scans[root.path] = ScanResult(locationID: root.path, rootName: "Test", totalBytes: 200,
                                         itemCount: 2, topNodes: [], issues: [],
                                         startedAt: started.addingTimeInterval(-3600), finishedAt: started.addingTimeInterval(-3500), wasCancelled: false)
        #expect(CleanupService.revalidate(url: folders[0], node: nodes[0], scope: root,
                                         verifiedAt: app.verificationTime(for: nodes[0])) != .ok)
        app.focusedScans[AppState.leftoverKey] = ScanResult(locationID: AppState.leftoverKey, rootName: "Leftovers",
                                                          totalBytes: 200, itemCount: 2, topNodes: nodes, issues: [],
                                                          startedAt: started, finishedAt: Date(), wasCancelled: false)
        #expect(app.verificationTime(for: nodes[0]) == started)
        #expect(CleanupService.revalidate(url: folders[0], node: nodes[0], scope: root,
                                         verifiedAt: app.verificationTime(for: nodes[0])) == .ok)
        var blocked = ScanNode(id: "blocked", name: "restricted", path: root.appendingPathComponent("restricted").path,
                               isFolder: false, category: .system, logicalBytes: 1, modified: nil, childCount: 0)
        blocked.ownedByOthers = true
        app.leftoverGroups = [LeftoverGroup(bundleID: "com.test.orphan", items: nodes + [blocked])]
        app.rebuildIndex()
        app.nodeIndex[blocked.id] = blocked
        app.requestTrash(nodes + [blocked])
        #expect(app.directTrashItems.count == 2)
        #expect(app.directTrashSkipped.count == 1)
        app.confirmDirectTrash()
        await app.cleanupTask?.value
        #expect(app.cleanupResults.count == 3)
        let moved = app.cleanupResults.filter(\.didMove)
        #expect(moved.count == 2)
        #expect(app.leftoverGroups.flatMap(\.items).map(\.id) == [blocked.id])
        #expect(app.cleanupResults.first(where: { $0.id == blocked.id })?.message != nil)
        for result in moved {
            if case .moved(let trashURL) = result.outcome {
                try fm.moveItem(at: trashURL, to: URL(fileURLWithPath: result.path))
            }
        }
        // A later real change remains blocked; a fresh measurement is not a bypass.
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                             ofItemAtPath: folders[0].appendingPathComponent("cache.bin").path)
        #expect(CleanupService.revalidate(url: folders[0], node: nodes[0], scope: root, verifiedAt: started) != .ok)
    }

    @Test @MainActor func entirelyIneligibleRequestStillExplainsEverySkip() {
        let app = AppState()
        let node = ScanNode(id: "gone", name: "gone", path: "/review/gone", isFolder: false,
                            category: .other, logicalBytes: 100, modified: nil, childCount: 0)
        app.requestTrash([node])
        #expect(app.directTrashItems.isEmpty)
        #expect(app.cleanupResults.count == 1)
        #expect(app.cleanupResults[0].message != nil)
        #expect(app.lastCleanupSummary != nil)
    }
}
