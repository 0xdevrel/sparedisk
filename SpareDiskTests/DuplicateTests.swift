import Foundation
import Testing
@testable import SpareDisk

/// Duplicate-pipeline tests on disposable fixtures (§F07): identical content
/// groups, same-size rejection, hard-link collapse, size floor, cloud skips,
/// and last-copy keeper protection. No user data touched.
struct DuplicateTests {
    private func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpareDiskDupes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: 2_000_000).write(to: root.appendingPathComponent("big1.bin"))
        try Data(repeating: 0x61, count: 2_000_000).write(to: root.appendingPathComponent("big2.bin"))
        try Data(repeating: 0x62, count: 2_000_000).write(to: root.appendingPathComponent("same-size.bin"))
        try Data(repeating: 0x63, count: 100).write(to: root.appendingPathComponent("tiny1.bin"))
        try Data(repeating: 0x63, count: 100).write(to: root.appendingPathComponent("tiny2.bin"))
        try FileManager.default.linkItem(at: root.appendingPathComponent("big1.bin"),
                                         to: root.appendingPathComponent("big1-link.bin"))
        return root
    }

    private func node(_ url: URL, id: String, cloud: Bool = false) -> ScanNode {
        let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let (ino, vol) = ScanEngine.identityNumbers(for: url)
        return ScanNode(id: id, name: url.lastPathComponent, path: cloud ? "/cloud/\(id)" : url.path,
                        isFolder: false, category: .documents,
                        logicalBytes: cloud ? 5_000_000 : Int64(vals?.fileSize ?? 0),
                        modified: vals?.contentModificationDate, childCount: 0,
                        isCloudPlaceholder: cloud, fsFileNumber: ino, fsVolumeNumber: vol)
    }

    @Test func identicalGroupsSameSizeRejectedLinksCollapsed() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = [
            node(root.appendingPathComponent("big1.bin"), id: "a1"),
            node(root.appendingPathComponent("big2.bin"), id: "a2"),
            node(root.appendingPathComponent("same-size.bin"), id: "b"),
            node(root.appendingPathComponent("big1-link.bin"), id: "link"),
            node(root.appendingPathComponent("tiny1.bin"), id: "t1"),
            node(root.appendingPathComponent("tiny2.bin"), id: "t2"),
            node(root.appendingPathComponent("big1.bin"), id: "cloud", cloud: true),
        ]
        let (groups, skipped) = await DuplicateService.findDuplicates(files: files) { _ in }
        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(Set(group.files.map(\.id)) == ["a1", "a2"])
        #expect(group.redundantLogicalBytes == 2_000_000)
        #expect(skipped.contains(where: { $0.id == "cloud" }))
    }

    @Test func protectKeepersHoldsLastCopy() {
        func item(_ id: String) -> ReviewItem {
            let n = ScanNode(id: id, name: id, path: "/tmp/\(id)", isFolder: false,
                             category: .documents, logicalBytes: 10, modified: nil, childCount: 0)
            return ReviewItem(id: id, node: n, source: "T", reason: "T", risk: "T")
        }
        func group(_ ids: String...) -> DuplicateGroup {
            DuplicateGroup(id: "g:\(ids.joined())", digestHex: "x", bytesPerFile: 10,
                           files: ids.map { item($0).node })
        }
        let g = group("a", "b")
        // Staging every copy: keeper stays out and is reported.
        let full = DuplicateService.protectKeepers(plan: [item("a"), item("b"), item("o")],
                                                   groups: [g], keepers: ["g:ab": "b"])
        #expect(full.kept.map(\.id) == ["a", "o"])
        #expect(full.protected.map(\.id) == ["b"])
        // Partial staging passes through untouched.
        let partial = DuplicateService.protectKeepers(plan: [item("a")], groups: [g], keepers: [:])
        #expect(partial.kept.map(\.id) == ["a"])
        #expect(partial.protected.isEmpty)
    }
}
