import Foundation
import Testing
@testable import SpareDisk

/// Safety-contract tests for the cleanup path (P1/P2 review findings).
/// Pure logic only — no filesystem mutation, no fixtures on disk.
struct CleanupSafetyTests {
    private func node(_ id: String, _ path: String, folder: Bool = false, bytes: Int64 = 100) -> ScanNode {
        ScanNode(id: id, name: (path as NSString).lastPathComponent, path: path,
                 isFolder: folder, category: .documents, logicalBytes: bytes,
                 modified: nil, childCount: folder ? 2 : 0)
    }

    private func item(_ id: String, _ path: String, folder: Bool = false, bytes: Int64 = 100) -> ReviewItem {
        ReviewItem(id: id, node: node(id, path, folder: folder, bytes: bytes),
                   source: "Test", reason: "Test", risk: "Test")
    }

    // MARK: - Overlap normalization

    @Test func normalizeDropsDescendantsAndDuplicates() {
        let parent = item("p", "/tmp/scope/Big", folder: true, bytes: 900)
        let child = item("c", "/tmp/scope/Big/inside.txt", bytes: 100)
        let dup = item("p", "/tmp/scope/Big", folder: true, bytes: 900)
        let other = item("o", "/tmp/scope/Other.txt", bytes: 50)
        let plan = CleanupService.normalize([parent, child, dup, other])
        #expect(plan.map(\.id) == ["p", "o"])
    }

    @Test func normalizeCountsSamePathOnceAcrossSources() {
        // Browse ids look like "loc/name", Find ids like "loc#/full/path".
        let browse = item("/tmp/scope/big.mov", "/tmp/scope/big.mov")
        let find = item("/tmp/scope#/tmp/scope/big.mov", "/tmp/scope/big.mov")
        let plan = CleanupService.normalize([browse, find])
        #expect(plan.count == 1)
    }

    @Test func normalizeKeepsSiblingPrefixAsSeparate() {
        // "/tmp/scope/Big" must not swallow "/tmp/scope/Bigger".
        let plan = CleanupService.normalize([
            item("p", "/tmp/scope/Big", folder: true),
            item("s", "/tmp/scope/Bigger/file.txt"),
        ])
        #expect(plan.count == 2)
    }

    // MARK: - Containment

    @Test func isWithinRejectsTraversalAndSiblings() {
        #expect(CleanupService.isWithin("/tmp/scope/a/b", root: "/tmp/scope"))
        #expect(!CleanupService.isWithin("/tmp/scope", root: "/tmp/scope"))
        #expect(!CleanupService.isWithin("/tmp/scope-evil/x", root: "/tmp/scope"))
        #expect(!CleanupService.isWithin("/tmp/scope/../evil", root: "/tmp/scope"))
        #expect(!CleanupService.isWithin("/other", root: "/tmp/scope"))
    }

    // MARK: - Stable identity

    @Test func identityMatchesComparesFileAndVolume() {
        var n = node("f", "/tmp/scope/a.txt")
        n.fsFileNumber = 111
        n.fsVolumeNumber = 7
        #expect(CleanupService.identityMatches(node: n, fileNumber: 111, volumeNumber: 7))
        #expect(!CleanupService.identityMatches(node: n, fileNumber: 222, volumeNumber: 7))
        #expect(!CleanupService.identityMatches(node: n, fileNumber: 111, volumeNumber: 9))
    }

    @Test func unknownIdentityNeverConfirms() {
        let n = node("f", "/tmp/scope/a.txt")
        #expect(!CleanupService.identityMatches(node: n, fileNumber: 111, volumeNumber: 7))
        var stamped = n
        stamped.fsFileNumber = 111
        #expect(!CleanupService.identityMatches(node: stamped, fileNumber: nil, volumeNumber: nil))
    }

    @Test @MainActor func staleQueueEntryCanBeRemoved() {
        let app = AppState()
        let n = node("gone", "/tmp/scope/old.bin")
        app.reviewItems = [ReviewItem(id: n.id, node: n, source: "T", reason: "T", risk: "T")]
        // Not in any index, not in any location: still removable.
        app.removeFromReview(id: n.id)
        #expect(app.reviewItems.isEmpty)
        app.reviewItems = [ReviewItem(id: n.id, node: n, source: "T", reason: "T", risk: "T")]
        app.toggleReview(n, source: "T")
        #expect(app.reviewItems.isEmpty)
    }

    @Test @MainActor func searchReturnsOneRowPerPath() {
        let app = AppState()
        var tree = node("/tmp/scope/Duplicate A.bin", "/tmp/scope/Duplicate A.bin")
        tree.logicalBytes = 2_100_000
        var ranked = node("/tmp/scope#/tmp/scope/Duplicate A.bin", "/tmp/scope/Duplicate A.bin")
        ranked.logicalBytes = 2_100_000
        app.nodeIndex = [tree.id: tree, ranked.id: ranked]
        let hits = app.searchNodes(in: "/tmp/scope", matching: "Duplicate A")
        #expect(hits.count == 1)
        #expect(hits.first?.id == tree.id)
    }

    @Test @MainActor func forgettingAnotherLocationLeavesTheRunningScanAlone() {
        let app = AppState()
        app.locations = [
            SDLocation(id: "/tmp/A", name: "A", symbol: "folder", isExternal: false, access: .available,
                       capacityBytes: 1, availableBytes: 1, scannedBytes: 0, scannedAt: Date(), issues: 0),
            SDLocation(id: "/tmp/B", name: "B", symbol: "folder", isExternal: false, access: .available,
                       capacityBytes: 1, availableBytes: 1, scannedBytes: 0, scannedAt: Date(), issues: 0),
        ]
        app.scanningLocationID = "/tmp/A"
        app.scanQueue = ["/tmp/B"]
        app.forgetLocation(id: "/tmp/B")
        #expect(app.scanningLocationID == "/tmp/A")
        #expect(app.scanQueue.isEmpty)
        #expect(app.locations.map(\.id) == ["/tmp/A"])
    }

    // MARK: - Plan drives totals

    @Test @MainActor func reviewPlanCountsOverlapOnce() {
        let app = AppState()
        app.reviewItems = [
            item("p", "/tmp/scope/Big", folder: true, bytes: 900),
            item("c", "/tmp/scope/Big/inside.txt", bytes: 100),
        ]
        #expect(app.reviewPlan.map(\.id) == ["p"])
        #expect(app.reviewPlanBytes == 900)
    }

    // MARK: - Cloud residency (membership is not placeholder status)

    @Test func onlyNotDownloadedIsPlaceholder() {
        #expect(ScanEngine.cloudPlaceholder(status: .notDownloaded))
        #expect(!ScanEngine.cloudPlaceholder(status: .downloaded))
        #expect(!ScanEngine.cloudPlaceholder(status: .current))
        #expect(!ScanEngine.cloudPlaceholder(status: nil))
    }
}

/// Revalidation must accept an item exactly as the scanner recorded it,
/// otherwise nothing can ever be moved to the Trash.
struct CleanupRevalidationTests {
    @Test func freshlyScannedItemsPassRevalidation() async throws {
        // Not the temp directory: it resolves under /private, which the
        // cleanup policy refuses on purpose.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = base.appendingPathComponent("SpareDiskTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Bundle.app")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 2048).write(to: folder.appendingPathComponent("Contents/bin"))
        try Data(repeating: 2, count: 4096).write(to: root.appendingPathComponent("loose.bin"))

        let result = await ScanEngine.scan(locationID: root.path, rootName: "T", root: root) { _ in }
        let bundle = try #require(result.topNodes.first(where: { $0.name == "Bundle.app" }))
        let loose = try #require(result.topNodes.first(where: { $0.name == "loose.bin" }))

        #expect(CleanupService.revalidate(url: URL(fileURLWithPath: bundle.path), node: bundle, scope: root) == .ok)
        #expect(CleanupService.revalidate(url: URL(fileURLWithPath: loose.path), node: loose, scope: root) == .ok)

        // A real change is still caught.
        try Data(repeating: 3, count: 10).write(to: root.appendingPathComponent("loose.bin"))
        #expect(CleanupService.revalidate(url: URL(fileURLWithPath: loose.path), node: loose, scope: root) != .ok)
    }

    @Test func nestedChangeInsideFolderIsCaught() async throws {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = base.appendingPathComponent("SpareDiskTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let deep = root.appendingPathComponent("Project/src/lib")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 2048).write(to: deep.appendingPathComponent("a.bin"))

        let result = await ScanEngine.scan(locationID: root.path, rootName: "T", root: root) { _ in }
        let project = try #require(result.topNodes.first(where: { $0.name == "Project" }))
        // The reference is the scan start, so an untouched folder passes.
        #expect(CleanupService.revalidate(url: URL(fileURLWithPath: project.path), node: project, scope: root, verifiedAt: result.startedAt) == .ok)

        // Two levels down, before anyone stages it: the folder's own date
        // does not move, and the staging click must not reset the clock.
        try await Task.sleep(for: .milliseconds(20))
        try Data(repeating: 9, count: 10).write(to: deep.appendingPathComponent("a.bin"))
        let after = CleanupService.revalidate(url: URL(fileURLWithPath: project.path), node: project, scope: root, verifiedAt: result.startedAt)
        guard case .changed = after else { Issue.record("expected .changed, got \(after)"); return }
    }

    @Test func mutationDuringScanCannotPassFolderReview() async throws {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = base.appendingPathComponent("SpareDiskTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let deep = root.appendingPathComponent("Project/src")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10).write(to: deep.appendingPathComponent("file.bin"))
        try await Task.sleep(for: .milliseconds(20))

        // The file changes while the walk is still running: whichever size
        // was recorded, the modification lands after the scan began.
        let result = await ScanEngine.scan(locationID: root.path, rootName: "T", root: root) { _ in
            try? Data(repeating: 2, count: 50_000).write(to: deep.appendingPathComponent("file.bin"))
        }
        let project = try #require(result.topNodes.first(where: { $0.name == "Project" }))
        let verdict = CleanupService.revalidate(url: URL(fileURLWithPath: project.path), node: project, scope: root, verifiedAt: result.startedAt)
        guard case .changed = verdict else { Issue.record("expected .changed, got \(verdict)"); return }
    }

    @Test func farFutureDatesSurviveSaveAndLoadWithoutTrapping() throws {
        let odd = Date(timeIntervalSince1970: 16_725_225_600) // year 2500
        let ancient = Date(timeIntervalSince1970: -1_000_000_000)
        let node = ScanNode(id: "n", name: "n", path: "/x/n", isFolder: false, category: .other,
                            logicalBytes: 1, modified: odd, childCount: 0)
        let result = ScanResult(locationID: "/x", rootName: "x", totalBytes: 1, itemCount: 1, topNodes: [node],
                                issues: [], startedAt: ancient, finishedAt: odd, wasCancelled: false)
        let data = try #require(ScanStore.encode(result))
        let back = try #require(ScanStore.decode(data))
        #expect(back.topNodes[0].modified == odd)
        #expect(back.startedAt == ancient)
    }

    @Test func movedFileLeavesQueueUnderEveryID() {
        func item(_ id: String, _ path: String) -> ReviewItem {
            let n = ScanNode(id: id, name: (path as NSString).lastPathComponent, path: path, isFolder: false,
                             category: .documents, logicalBytes: 100, modified: nil, childCount: 0)
            return ReviewItem(id: id, node: n, source: "T", reason: "T", risk: "T")
        }
        let browse = item("/tmp/scope/big.mov", "/tmp/scope/big.mov")
        let find = item("/tmp/scope#/tmp/scope/big.mov", "/tmp/scope/big.mov")
        let inside = item("/tmp/scope/Dir/x.txt", "/tmp/scope/Dir/x.txt")
        let other = item("o", "/tmp/scope/Other.txt")
        let moved = [
            CleanupResult(id: find.id, name: "big.mov", path: "/tmp/scope/big.mov", bytes: 100, outcome: .moved(trashURL: URL(fileURLWithPath: "/tmp/T/big.mov"))),
            CleanupResult(id: "d", name: "Dir", path: "/tmp/scope/Dir", bytes: 100, outcome: .moved(trashURL: URL(fileURLWithPath: "/tmp/T/Dir"))),
        ]
        let left = CleanupService.remaining([browse, find, inside, other], afterMoving: moved)
        #expect(left.map(\.id) == ["o"])
    }

    @Test func unreadableDescendantBlocksTheMove() async throws {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = base.appendingPathComponent("SpareDiskTest-\(UUID().uuidString)")
        let locked = root.appendingPathComponent("Project/locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 64).write(to: locked.appendingPathComponent("x.bin"))
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }
        let result = await ScanEngine.scan(locationID: root.path, rootName: "T", root: root) { _ in }
        let project = try #require(result.topNodes.first(where: { $0.name == "Project" }))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        let verdict = CleanupService.revalidate(url: URL(fileURLWithPath: project.path), node: project, scope: root, verifiedAt: Date())
        guard case .blocked = verdict else { Issue.record("expected .blocked, got \(verdict)"); return }
    }

    @Test func savedScanKeepsSubSecondDatesAndBrowseIdentity() async throws {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = base.appendingPathComponent("SpareDiskTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 4096).write(to: root.appendingPathComponent("loose.bin"))

        let result = await ScanEngine.scan(locationID: root.path, rootName: "T", root: root) { _ in }
        let data = try #require(ScanStore.encode(result))
        let reloaded = try #require(ScanStore.decode(data))
        let loose = try #require(reloaded.topNodes.first(where: { $0.name == "loose.bin" }))

        // Browse nodes carry inode identity like Find candidates do.
        #expect(loose.fsFileNumber != nil)
        // Unchanged after a relaunch means unchanged.
        #expect(CleanupService.revalidate(url: URL(fileURLWithPath: loose.path), node: loose, scope: root) == .ok)
        let original = try #require(result.topNodes.first(where: { $0.name == "loose.bin" }))
        #expect(CleanupService.sameInstant(original.modified!, loose.modified!))
    }
}
