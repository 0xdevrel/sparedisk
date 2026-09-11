import Foundation

// Saved-scan comparison (§F11, first step): the previous completed scan of
// a location is kept alongside the current one, and the two are compared
// by top-level path. Logical sizes are compared; unreadable folders are
// reported as such, not as removed.
nonisolated struct ScanChange: Identifiable, Hashable {
    var id: String { path }
    var name: String
    var path: String
    var before: Int64?
    var after: Int64?
    var isFolder: Bool

    var delta: Int64 { (after ?? 0) - (before ?? 0) }
    var kind: String {
        switch (before, after) {
        case (nil, _): "Added"
        case (_, nil): "Removed"
        default: delta >= 0 ? "Grew" : "Shrank"
        }
    }
}

nonisolated struct ScanDiff: Hashable {
    var previousFinished: Date
    var bytesDelta: Int64
    var itemsDelta: Int
    var changes: [ScanChange]

    static func between(previous: ScanResult, current: ScanResult) -> ScanDiff {
        let old = Dictionary(previous.topNodes.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let new = Dictionary(current.topNodes.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var changes: [ScanChange] = []
        for (path, n) in new {
            let o = old[path]
            if o?.logicalBytes != n.logicalBytes {
                changes.append(ScanChange(name: n.name, path: path, before: o?.logicalBytes,
                                          after: n.logicalBytes, isFolder: n.isFolder))
            }
        }
        for (path, o) in old where new[path] == nil {
            changes.append(ScanChange(name: o.name, path: path, before: o.logicalBytes, after: nil, isFolder: o.isFolder))
        }
        changes.sort { abs($0.delta) > abs($1.delta) }
        return ScanDiff(previousFinished: previous.finishedAt,
                        bytesDelta: current.totalBytes - previous.totalBytes,
                        itemsDelta: current.itemCount - previous.itemCount,
                        changes: changes)
    }
}
