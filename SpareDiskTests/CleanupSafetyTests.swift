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

    @Test func unknownIdentityFallsBackWithoutFalseConfirm() {
        let n = node("f", "/tmp/scope/a.txt")
        #expect(CleanupService.identityMatches(node: n, fileNumber: 111, volumeNumber: 7))
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
