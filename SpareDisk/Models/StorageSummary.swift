import Foundation

/// The storage picture behind My Mac: one volume, what each scanned
/// location occupies on it, and how much is used by everything else.
/// Pure functions so the arithmetic is unit-tested.
nonisolated struct StorageSummary: Equatable {
    struct Part: Equatable, Identifiable {
        var id: String
        var name: String
        var bytes: Int64
        /// Position in the location list, which fixes its hue everywhere.
        var rank: Int
    }

    var volume: SDLocation
    var used: Int64
    var parts: [Part]
    /// Used bytes outside every scanned location on this volume.
    var other: Int64
    /// How far the scanned folders exceed what the disk reports as used.
    /// Shown, never hidden: it points at clones, sparse files or a stale
    /// scan.
    var overshoot: Int64
    /// Scanned locations on other volumes, shown separately.
    var elsewhere: [SDLocation]

    /// Length of the whole bar: capacity, or more when the parts do not fit.
    var scale: Int64 { max(volume.capacityBytes, parts.reduce(0) { $0 + $1.bytes } + other + volume.availableBytes) }

    /// Locations that share `volume`'s disk. Falls back to matching capacity
    /// when the UUID is unknown, so older entries still group sensibly.
    static func sameVolume(_ a: SDLocation, _ b: SDLocation) -> Bool {
        if let x = a.volumeUUID, let y = b.volumeUUID { return x == y }
        // Without identity on both sides, only an identical capacity and
        // free-space reading at the same moment is taken as the same disk.
        return a.volumeUUID == nil && b.volumeUUID == nil
            && a.capacityBytes == b.capacityBytes && a.availableBytes == b.availableBytes
    }

    /// Parents before children regardless of the order the user added them,
    /// so a nested location is never counted when its parent is.
    static func topLevel(_ locations: [SDLocation]) -> [SDLocation] {
        var out: [SDLocation] = []
        for loc in locations.sorted(by: { $0.id.count < $1.id.count }) {
            if out.contains(where: { CleanupService.isWithin(loc.id, root: $0.id) }) { continue }
            out.append(loc)
        }
        return out
    }

    static func make(locations: [SDLocation], scanned: (SDLocation) -> Int64?) -> StorageSummary? {
        let withScan = locations.filter { scanned($0) != nil }
        guard let volume = withScan.first(where: { $0.capacityBytes > 0 })
                ?? locations.first(where: { $0.capacityBytes > 0 }) else { return nil }
        let onVolume = withScan.filter { sameVolume($0, volume) }
        let elsewhere = withScan.filter { !sameVolume($0, volume) }
        let used = max(0, volume.capacityBytes - volume.availableBytes)
        var parts: [Part] = []
        var accounted: Int64 = 0
        for loc in topLevel(onVolume) {
            let bytes = scanned(loc) ?? 0
            let rank = locations.firstIndex(where: { $0.id == loc.id }) ?? 0
            parts.append(Part(id: loc.id, name: loc.name, bytes: bytes, rank: rank))
            accounted += bytes
        }
        return StorageSummary(volume: volume, used: used, parts: parts,
                              other: max(0, used - accounted), overshoot: max(0, accounted - used),
                              elsewhere: elsewhere)
    }

    /// Bytes by file kind across scans, nested locations counted once.
    /// `onDisk` sums allocated bytes and leaves out scans that predate
    /// per-kind allocation, so an on-disk bar never quietly carries logical
    /// figures; `categoryTotalsMissing` names those scans instead.
    static func categoryTotals(locations: [SDLocation], scans: [String: ScanResult],
                               onDisk: Bool = false) -> [(category: SDFileCategory, bytes: Int64)] {
        var acc: [SDFileCategory: Int64] = [:]
        for scan in countedScans(locations: locations, scans: scans, onDisk: onDisk) {
            for (k, v) in onDisk ? scan.categoryAllocated : scan.categoryBytes {
                guard let c = SDFileCategory(rawValue: k) else { continue }
                acc[c == .unknown ? .other : c, default: 0] += v
            }
        }
        return acc.map { ($0.key, $0.value) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
    }

    /// How far the logical breakdown overstates what those files occupy:
    /// logical minus allocated, over the scans that track both. Sparse
    /// images, clones and not-downloaded cloud files make it large enough
    /// for a folder's kinds to add up to more than the whole disk.
    static func categoryLogicalExcess(locations: [SDLocation], scans: [String: ScanResult]) -> Int64 {
        var excess: Int64 = 0
        for scan in countedScans(locations: locations, scans: scans, onDisk: true) {
            excess += scan.categoryBytes.values.reduce(0, +) - scan.categoryAllocated.values.reduce(0, +)
        }
        return max(0, excess)
    }

    /// Locations whose scan cannot feed the breakdown under this basis:
    /// saved before category totals existed, or, on disk, before allocation
    /// was tracked per kind. A rescan fills them in.
    static func categoryTotalsMissing(locations: [SDLocation], scans: [String: ScanResult],
                                      onDisk: Bool = false) -> [SDLocation] {
        locations.filter { scans[$0.id].map { !hasBreakdown($0, onDisk: onDisk) } ?? false }
    }

    /// The scans that feed the breakdown: one per top-level location among
    /// those that carry the figures this basis needs.
    private static func countedScans(locations: [SDLocation], scans: [String: ScanResult], onDisk: Bool) -> [ScanResult] {
        topLevel(locations.filter { scans[$0.id].map { hasBreakdown($0, onDisk: onDisk) } ?? false })
            .compactMap { scans[$0.id] }
    }

    private static func hasBreakdown(_ scan: ScanResult, onDisk: Bool) -> Bool {
        !scan.categoryBytes.isEmpty && (!onDisk || !scan.categoryAllocated.isEmpty)
    }
}

extension AppState {
    /// On-disk bytes for a scan, falling back to logical size for results
    /// saved before allocation was tracked.
    func diskBytes(_ scan: ScanResult) -> Int64 {
        scan.allocationTracked ? scan.totalAllocated : scan.totalBytes
    }

    /// A scan's total under the current size basis.
    func total(of scan: ScanResult) -> Int64 {
        sizeBasis == .onDisk && scan.allocationTracked ? scan.totalAllocated : scan.totalBytes
    }

    /// The retained largest files for the current basis. Older scans have
    /// only the logical ranking.
    func largestCandidates(_ scan: ScanResult) -> [ScanNode] {
        sizeBasis == .onDisk && !scan.largestFilesOnDisk.isEmpty ? scan.largestFilesOnDisk : scan.largestFiles
    }

    var storageSummary: StorageSummary? {
        StorageSummary.make(locations: locations) { loc in scans[loc.id].map(diskBytes) }
    }

    /// The file-type breakdown under the current size basis.
    var categoryTotals: [(category: SDFileCategory, bytes: Int64)] {
        StorageSummary.categoryTotals(locations: locations, scans: scans, onDisk: sizeBasis == .onDisk)
    }

    /// Bytes the logical breakdown claims beyond what its files occupy.
    var categoryLogicalExcess: Int64 {
        StorageSummary.categoryLogicalExcess(locations: locations, scans: scans)
    }

    var categoryTotalsMissing: [SDLocation] {
        StorageSummary.categoryTotalsMissing(locations: locations, scans: scans, onDisk: sizeBasis == .onDisk)
    }

    /// The logical excess when it is worth a sentence: shown only under the
    /// logical basis, at least 1 GB, and at least a twentieth of the bar.
    var materialCategoryLogicalExcess: Int64? {
        guard sizeBasis == .logical else { return nil }
        let excess = categoryLogicalExcess
        let total = categoryTotals.reduce(0) { $0 + $1.bytes }
        guard excess >= 1_000_000_000, excess * 20 >= total else { return nil }
        return excess
    }

    /// One sentence explaining a logical breakdown that exceeds disk use.
    var categoryLogicalExcessNote: String? {
        materialCategoryLogicalExcess.map {
            "These add up to \(SDFormat.bytesString($0)) more than they occupy on disk. Sparse disk images, cloned copies and not-downloaded cloud files count in full here. Switch to Size on Disk in Settings to see what they occupy."
        }
    }
}
