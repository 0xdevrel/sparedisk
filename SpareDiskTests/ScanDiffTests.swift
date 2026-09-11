import Foundation
import Testing
@testable import SpareDisk

struct ScanDiffTests {
    private func node(_ name: String, _ bytes: Int64) -> ScanNode {
        ScanNode(id: "/r/\(name)", name: name, path: "/r/\(name)", isFolder: true, category: .other,
                 logicalBytes: bytes, modified: nil, childCount: 1)
    }
    private func result(_ nodes: [ScanNode], items: Int, at: Date) -> ScanResult {
        ScanResult(locationID: "/r", rootName: "r", totalBytes: nodes.reduce(0) { $0 + $1.logicalBytes },
                   itemCount: items, topNodes: nodes, issues: [], startedAt: at, finishedAt: at, wasCancelled: false)
    }

    @Test func diffReportsGrowthShrinkageAdditionsAndRemovals() {
        let prev = result([node("a", 100), node("b", 200), node("gone", 50)], items: 10, at: Date(timeIntervalSince1970: 0))
        let cur = result([node("a", 300), node("b", 150), node("new", 25)], items: 12, at: Date(timeIntervalSince1970: 60))
        let d = ScanDiff.between(previous: prev, current: cur)
        #expect(d.bytesDelta == 475 - 350)
        #expect(d.itemsDelta == 2)
        #expect(d.changes.map(\.name) == ["a", "b", "gone", "new"])
        #expect(d.changes.map(\.kind) == ["Grew", "Shrank", "Removed", "Added"])
        #expect(d.changes[0].delta == 200)
        #expect(d.changes[2].after == nil)
    }
}
