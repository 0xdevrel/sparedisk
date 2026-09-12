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
    /// The current scan could not read this item or something inside it,
    /// so a missing or smaller figure is not evidence of deletion.
    var isUnreadable: Bool = false

    var delta: Int64 { isUnreadable ? 0 : (after ?? 0) - (before ?? 0) }
    var kind: String {
        if isUnreadable { return "Unreadable" }
        switch (before, after) {
        case (nil, _): return "Added"
        case (_, nil): return "Removed"
        default: return delta >= 0 ? "Grew" : "Shrank"
        }
    }
}

nonisolated struct ScanDiff: Hashable {
    var previousFinished: Date
    /// Sum of the listed changes. Items the current scan could not read
    /// contribute nothing, so a denied folder never reads as freed space.
    var bytesDelta: Int64
    var itemsDelta: Int
    var changes: [ScanChange]
    var hasUnreadable: Bool { changes.contains(where: \.isUnreadable) }

    static func between(previous: ScanResult, current: ScanResult) -> ScanDiff {
        let old = Dictionary(previous.topNodes.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let new = Dictionary(current.topNodes.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        // An issue on the item, inside it, or on any ancestor (the location
        // root included) means the current scan simply could not see it.
        let unreadable = current.issues.map(\.path)
        func touchedByIssue(_ path: String) -> Bool {
            unreadable.contains { $0 == path || CleanupService.isWithin($0, root: path) || CleanupService.isWithin(path, root: $0) }
        }
        var changes: [ScanChange] = []
        for (path, n) in new {
            let o = old[path]
            if o?.logicalBytes != n.logicalBytes {
                let shrankUnreadable = o != nil && n.logicalBytes < o!.logicalBytes && touchedByIssue(path)
                changes.append(ScanChange(name: n.name, path: path, before: o?.logicalBytes,
                                          after: n.logicalBytes, isFolder: n.isFolder,
                                          isUnreadable: shrankUnreadable || n.isUnreadable))
            }
        }
        for (path, o) in old where new[path] == nil {
            changes.append(ScanChange(name: o.name, path: path, before: o.logicalBytes, after: nil,
                                      isFolder: o.isFolder, isUnreadable: touchedByIssue(path)))
        }
        changes.sort { abs($0.delta) > abs($1.delta) }
        return ScanDiff(previousFinished: previous.finishedAt,
                        bytesDelta: changes.reduce(0) { $0 + $1.delta },
                        itemsDelta: current.itemCount - previous.itemCount,
                        changes: changes)
    }
}
