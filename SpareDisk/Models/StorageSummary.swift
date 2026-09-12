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
        return a.capacityBytes == b.capacityBytes
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

    /// Logical bytes by file kind across scans, nested locations counted
    /// once. Scans saved before category totals existed contribute nothing.
    static func categoryTotals(locations: [SDLocation], scans: [String: ScanResult]) -> [(category: SDFileCategory, bytes: Int64)] {
        let counted = topLevel(locations.filter { !(scans[$0.id]?.categoryBytes.isEmpty ?? true) })
        var acc: [SDFileCategory: Int64] = [:]
        for loc in counted {
            for (k, v) in scans[loc.id]?.categoryBytes ?? [:] {
                guard let c = SDFileCategory(rawValue: k) else { continue }
                acc[c == .unknown ? .other : c, default: 0] += v
            }
        }
        return acc.map { ($0.key, $0.value) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
    }

    static func categoryTotalsMissing(locations: [SDLocation], scans: [String: ScanResult]) -> [SDLocation] {
        locations.filter { scans[$0.id]?.categoryBytes.isEmpty ?? false }
    }
}

extension AppState {
    /// On-disk bytes for a scan, falling back to logical size for results
    /// saved before allocation was tracked.
    func diskBytes(_ scan: ScanResult) -> Int64 {
        scan.allocationTracked ? scan.totalAllocated : scan.totalBytes
    }

    var storageSummary: StorageSummary? {
        StorageSummary.make(locations: locations) { loc in scans[loc.id].map(diskBytes) }
    }

    var categoryTotals: [(category: SDFileCategory, bytes: Int64)] {
        StorageSummary.categoryTotals(locations: locations, scans: scans)
    }

    var categoryTotalsMissing: [SDLocation] {
        StorageSummary.categoryTotalsMissing(locations: locations, scans: scans)
    }
}
