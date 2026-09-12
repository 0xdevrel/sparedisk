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

    @Test func missingKeeperBlocksTheWholeGroup() {
        func file(_ id: String, _ path: String) -> ScanNode {
            ScanNode(id: id, name: (path as NSString).lastPathComponent, path: path, isFolder: false,
                     category: .documents, logicalBytes: 10, modified: nil, childCount: 0)
        }
        let a = file("a", "/tmp/nowhere/a.pdf"), b = file("b", "/tmp/nowhere/b.pdf")
        let g = DuplicateGroup(id: "g", digestHex: "x", bytesPerFile: 10, files: [a, b])
        let plan = [ReviewItem(id: a.id, node: a, source: "T", reason: "T", risk: "T")]
        let out = DuplicateService.requireKeepers(plan: plan, groups: [g], keepers: ["g": "b"])
        #expect(out.kept.isEmpty)
        #expect(out.blocked.map(\.id) == ["a"])
    }

    @Test func protectKeepersSeesThroughFoldersAndOtherIDs() {
        func file(_ id: String, _ path: String) -> ScanNode {
            ScanNode(id: id, name: (path as NSString).lastPathComponent, path: path, isFolder: false,
                     category: .documents, logicalBytes: 10, modified: nil, childCount: 0)
        }
        let a = file("a", "/tmp/scope/a.pdf"), b = file("b", "/tmp/scope/Dir/b.pdf")
        let g = DuplicateGroup(id: "g", digestHex: "x", bytesPerFile: 10, files: [a, b])
        let folder = ScanNode(id: "/tmp/scope/Dir", name: "Dir", path: "/tmp/scope/Dir", isFolder: true,
                              category: .other, logicalBytes: 10, modified: nil, childCount: 1)
        // A staged folder that holds the keeper is blocked, the other copy proceeds.
        let viaFolder = DuplicateService.protectKeepers(
            plan: [ReviewItem(id: a.id, node: a, source: "T", reason: "T", risk: "T"),
                   ReviewItem(id: folder.id, node: folder, source: "T", reason: "T", risk: "T")],
            groups: [g], keepers: ["g": "b"])
        #expect(viaFolder.kept.map(\.id) == ["a"])
        #expect(viaFolder.protected.map(\.id) == ["/tmp/scope/Dir"])
        // The keeper staged from Browse under another id is still the keeper.
        let browseB = ScanNode(id: "/tmp/scope/Dir/b.pdf", name: "b.pdf", path: b.path, isFolder: false,
                               category: .documents, logicalBytes: 10, modified: nil, childCount: 0)
        let viaID = DuplicateService.protectKeepers(
            plan: [ReviewItem(id: a.id, node: a, source: "T", reason: "T", risk: "T"),
                   ReviewItem(id: browseB.id, node: browseB, source: "T", reason: "T", risk: "T")],
            groups: [g], keepers: ["g": "b"])
        #expect(viaID.kept.map(\.id) == ["a"])
        #expect(viaID.protected.count == 1)
    }
}

/// Large-file paths: identical multi-megabyte files group, files that differ
/// only in the middle do not, and the run does not pin the file in memory.
struct DuplicateLargeFileTests {
    @Test func identicalLargeFilesGroupAndMiddleDifferenceIsCaught() async throws {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = base.appendingPathComponent("SpareDiskTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var payload = Data(count: 24 * 1024 * 1024)
        payload.withUnsafeMutableBytes { buf in for i in stride(from: 0, to: buf.count, by: 4099) { buf[i] = UInt8(i % 251) } }
        try payload.write(to: root.appendingPathComponent("a.bin"))
        try payload.write(to: root.appendingPathComponent("b.bin"))
        var altered = payload
        altered[altered.count / 2] ^= 0xFF
        try altered.write(to: root.appendingPathComponent("c.bin"))

        let before = residentBytes()
        let result = await ScanEngine.scan(locationID: root.path, rootName: "T", root: root) { _ in }
        let found = await DuplicateService.findDuplicates(files: result.largestFiles) { _ in }
        let after = residentBytes()

        #expect(found.groups.count == 1)
        #expect(Set(found.groups[0].files.map(\.name)) == ["a.bin", "b.bin"])
        // Three 24 MB files read twice must not leave their contents resident.
        #expect(after - before < 60 * 1024 * 1024, "resident grew by \((after - before) / 1_048_576) MB")
    }

    private func residentBytes() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int64(info.resident_size) : 0
    }
}
