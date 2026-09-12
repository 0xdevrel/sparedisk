import Foundation
import Testing
@testable import SpareDisk

/// Scanner-contract tests on disposable fixtures (P1/P2 review findings):
/// two-level hierarchy, own-mtime invariant, totals, stable identity.
struct ScanEngineTests {
    /// root/alpha/{one.txt 100B, two.txt 200B}, root/beta.txt 50B
    private func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpareDiskTest-\(UUID().uuidString)")
        let alpha = root.appendingPathComponent("alpha")
        try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: 100).write(to: alpha.appendingPathComponent("one.txt"))
        try Data(repeating: 0x62, count: 200).write(to: alpha.appendingPathComponent("two.txt"))
        try Data(repeating: 0x63, count: 50).write(to: root.appendingPathComponent("beta.txt"))
        return root
    }

    @Test func scanBuildsTwoLevelTreeWithHonestTotals() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = await ScanEngine.scan(locationID: "t", rootName: "T", root: root) { _ in }

        #expect(!result.wasCancelled)
        #expect(result.totalBytes == 350)
        #expect(result.issues.isEmpty)
        #expect(result.topNodes.map(\.name) == ["alpha", "beta.txt"])

        let alpha = result.topNodes[0]
        #expect(alpha.isFolder)
        #expect(alpha.logicalBytes == 300)
        #expect(alpha.modified != nil) // own mtime, never a descendant summary
        #expect(alpha.children?.map(\.name) == ["two.txt", "one.txt"])
        #expect(alpha.children?.map(\.logicalBytes) == [200, 100])
        #expect(alpha.children?.allSatisfy { !$0.isFolder } == true)

        let beta = result.topNodes[1]
        #expect(!beta.isFolder && beta.logicalBytes == 50)
        // .txt files are documents; every byte lands in exactly one category.
        #expect(result.categoryBytes[SDFileCategory.documents.rawValue] == 350)
        #expect(result.categoryBytes.values.reduce(0, +) == result.totalBytes)
    }

    @Test func scanStampsStableIdentityOnCandidates() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = await ScanEngine.scan(locationID: "t", rootName: "T", root: root) { _ in }
        #expect(!result.largestFiles.isEmpty)
        for file in result.largestFiles {
            #expect(file.fsFileNumber != nil)
            #expect(file.fsVolumeNumber != nil)
        }
        // Identity round-trips through cleanup's comparison.
        let one = try #require(result.largestFiles.first(where: { $0.name == "one.txt" }))
        let live = ScanEngine.identityNumbers(for: URL(fileURLWithPath: one.path))
        #expect(CleanupService.identityMatches(node: one, fileNumber: live.0, volumeNumber: live.1))
    }

    @Test func drillScanReadsFocusedFolder() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let alpha = root.appendingPathComponent("alpha")
        let result = await ScanEngine.scan(locationID: "t#\(alpha.path)", rootName: "alpha", root: alpha) { _ in }
        #expect(!result.wasCancelled)
        #expect(result.topNodes.map(\.name) == ["two.txt", "one.txt"])
        #expect(result.totalBytes == 300)
    }

    @Test func hardLinksCountOnceAndCarryLinkCount() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        // Second directory entry for one.txt: same content, new name.
        try FileManager.default.linkItem(at: root.appendingPathComponent("alpha/one.txt"),
                                         to: root.appendingPathComponent("alpha/one-link.txt"))

        let result = await ScanEngine.scan(locationID: "t", rootName: "T", root: root) { _ in }
        // 350 unique bytes, not 450: totals count content once, like du.
        #expect(result.totalBytes == 350)
        let names = result.largestFiles.map(\.name)
        #expect(names.contains("one-link.txt"))
        let linked = try #require(result.largestFiles.first(where: { $0.name == "one.txt" }))
        #expect(linked.hardLinkCount == 2)
        #expect(linked.allocatedBytes != nil)
    }

    @Test func scanReportsProgressWithCounts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpareDiskTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for d in 0..<4 {
            let dir = root.appendingPathComponent("d\(d)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for f in 0..<200 {
                try Data([UInt8(f & 0xff)]).write(to: dir.appendingPathComponent("f\(f).bin"))
            }
        }
        let lock = NSLock()
        var seen: [Int] = []
        let result = await ScanEngine.scan(locationID: "t", rootName: "T", root: root) { p in
            lock.lock(); seen.append(p.itemsFound); lock.unlock()
        }
        #expect(result.itemCount == 804)
        #expect(!seen.isEmpty)
        #expect(seen.contains { $0 > 0 })
        #expect(seen.max()! <= 804)
    }
}
