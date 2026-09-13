import Foundation
import Testing
@testable import SpareDisk

/// The My Mac picture: one volume at a time, nested locations once,
/// whatever order they were added in.
struct StorageSummaryTests {
    private func loc(_ id: String, capacity: Int64 = 1000, available: Int64 = 400, volume: String? = "A") -> SDLocation {
        SDLocation(id: id, name: (id as NSString).lastPathComponent, symbol: "folder", isExternal: false,
                   access: .available, capacityBytes: capacity, availableBytes: available,
                   volumeUUID: volume, volumeName: nil, scannedBytes: 0, scannedAt: Date(), issues: 0)
    }

    @Test func nestedLocationCountsOnceRegardlessOfOrder() {
        let sizes: [String: Int64] = ["/Users/m/Downloads": 100, "/Users/m": 500]
        let childFirst = StorageSummary.make(locations: [loc("/Users/m/Downloads"), loc("/Users/m")]) { sizes[$0.id] }!
        let parentFirst = StorageSummary.make(locations: [loc("/Users/m"), loc("/Users/m/Downloads")]) { sizes[$0.id] }!
        #expect(childFirst.parts.map(\.id) == ["/Users/m"])
        #expect(parentFirst.parts.map(\.id) == ["/Users/m"])
        #expect(childFirst.other == 600 - 500)
    }

    @Test func otherVolumesStayOutOfTheBar() {
        let sizes: [String: Int64] = ["/Users/m": 500, "/Volumes/SSD/Video": 900]
        let s = StorageSummary.make(locations: [loc("/Users/m"), loc("/Volumes/SSD/Video", capacity: 2000, available: 100, volume: "B")]) { sizes[$0.id] }!
        #expect(s.parts.map(\.id) == ["/Users/m"])
        #expect(s.elsewhere.map(\.id) == ["/Volumes/SSD/Video"])
        #expect(s.parts[0].bytes + s.other == s.used)
    }

    @Test func excessOverUsedSpaceIsReportedNotTruncated() {
        // Scanned totals can exceed the used figure (clones, sparse files, stale scan).
        let s = StorageSummary.make(locations: [loc("/Users/m", capacity: 1000, available: 900)]) { _ in 5000 }!
        #expect(s.parts[0].bytes == 5000)
        #expect(s.other == 0)
        #expect(s.overshoot == 4900)
        #expect(s.scale == 5900)
    }

    private func scan(_ id: String, logical: [String: Int64], allocated: [String: Int64] = [:]) -> ScanResult {
        ScanResult(locationID: id, rootName: id, totalBytes: logical.values.reduce(0, +),
                   totalAllocated: allocated.values.reduce(0, +),
                   categoryBytes: logical, categoryAllocated: allocated, itemCount: 0, topNodes: [],
                   issues: [], startedAt: Date(), finishedAt: Date(), wasCancelled: false)
    }

    @Test func fileTypeTotalsFollowTheSizeBasis() {
        let dev = SDFileCategory.developer.rawValue, doc = SDFileCategory.documents.rawValue
        let locations = [loc("/Users/m")]
        let scans = ["/Users/m": scan("/Users/m", logical: [dev: 1200, doc: 100], allocated: [dev: 300, doc: 100])]
        let logical = StorageSummary.categoryTotals(locations: locations, scans: scans, onDisk: false)
        let onDisk = StorageSummary.categoryTotals(locations: locations, scans: scans, onDisk: true)
        #expect(logical.map { $0.bytes } == [1200, 100])
        #expect(onDisk.map { $0.bytes } == [300, 100])
        #expect(StorageSummary.categoryLogicalExcess(locations: locations, scans: scans) == 900)
    }

    @Test func onDiskTotalsLeaveOutScansWithoutPerKindAllocationAndAskForARescan() {
        let dev = SDFileCategory.developer.rawValue
        let locations = [loc("/Users/m"), loc("/Volumes/SSD", volume: "B")]
        let scans = ["/Users/m": scan("/Users/m", logical: [dev: 1200], allocated: [dev: 300]),
                     "/Volumes/SSD": scan("/Volumes/SSD", logical: [dev: 50])]   // saved before allocation was tracked per kind
        // Logical figures never masquerade as on-disk ones.
        #expect(StorageSummary.categoryTotals(locations: locations, scans: scans, onDisk: true).map { $0.bytes } == [300])
        #expect(StorageSummary.categoryTotalsMissing(locations: locations, scans: scans, onDisk: true).map(\.id) == ["/Volumes/SSD"])
        // Under the logical basis the older scan still counts and is not missing.
        #expect(StorageSummary.categoryTotals(locations: locations, scans: scans, onDisk: false).map { $0.bytes } == [1250])
        #expect(StorageSummary.categoryTotalsMissing(locations: locations, scans: scans, onDisk: false).isEmpty)
        // Only scans that carry both figures speak to the excess.
        #expect(StorageSummary.categoryLogicalExcess(locations: locations, scans: scans) == 900)
    }

    @Test func fileTypeTotalsCountNestedLocationsOnceOnDisk() {
        let dev = SDFileCategory.developer.rawValue
        let locations = [loc("/Users/m/Downloads"), loc("/Users/m")]
        let scans = ["/Users/m": scan("/Users/m", logical: [dev: 1000], allocated: [dev: 400]),
                     "/Users/m/Downloads": scan("/Users/m/Downloads", logical: [dev: 200], allocated: [dev: 100])]
        #expect(StorageSummary.categoryTotals(locations: locations, scans: scans, onDisk: true).map { $0.bytes } == [400])
        #expect(StorageSummary.categoryLogicalExcess(locations: locations, scans: scans) == 600)
    }

    @Test func untrackedAllocationIsNotZero() {
        let old = ScanResult(locationID: "/x", rootName: "x", totalBytes: 500, totalAllocated: 0, itemCount: 1,
                             topNodes: [ScanNode(id: "n", name: "n", path: "/x/n", isFolder: false, category: .other,
                                                 logicalBytes: 500, modified: nil, childCount: 0)],
                             issues: [], startedAt: Date(), finishedAt: Date(), wasCancelled: false)
        #expect(old.allocationTracked == false)
        var fresh = old
        fresh.topNodes[0].allocatedBytes = 0
        #expect(fresh.allocationTracked == true)
    }
}
