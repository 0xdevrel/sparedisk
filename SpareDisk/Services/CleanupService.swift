import Foundation

// Only CleanupService mutates user files (§9.2). UI submits a reviewed plan;
// the scanner exposes no delete function. Trash-only: no permanent-delete
// fallback, no auto-retry, batch is not atomic, cancellation between items.
//
// Fail-closed policy: anything the revalidation cannot positively confirm
// (identity, scope, type, metadata) is refused with a reason — never trashed.
nonisolated enum CleanupOutcome: Hashable {
    case moved(trashURL: URL)
    case skippedChanged(String)
    case blocked(String)
    case failed(String)
    case missing
}

nonisolated struct CleanupResult: Identifiable, Hashable {
    let id: String
    var name: String
    var path: String
    var bytes: Int64
    var outcome: CleanupOutcome

    var didMove: Bool {
        if case .moved = outcome { return true }
        return false
    }
    var message: String? {
        switch outcome {
        case .moved: return nil
        case .skippedChanged(let s), .blocked(let s), .failed(let s): return s
        case .missing: return "This item no longer exists."
        }
    }
}

nonisolated enum CleanupService {
    /// Never trash these, even inside an authorized scope.
    private static let blockedPrefixes = [
        "/System", "/Library", "/private", "/bin", "/sbin",
        "/usr", "/etc", "/var", "/dev", "/cores", "/opt",
    ]
    /// Whole-unit managed data: hand off to the owning app, never generic-trash.
    private static let managedExtensions: Set<String> = [
        "photoslibrary", "mailbundle", "mbox",
    ]
    private static let backupMarkers = ["Backups.backupdb", ".timemachine"]
    /// Bounded search for managed units nested inside a reviewed folder.
    /// Beyond the cap we rely on the review copy, not a silent pass.
    private static let managedSearchCap = 50_000

    // MARK: - Plan normalization (overlap + identity, §F10)

    /// Descendants of a selected folder count once; same identity counts once.
    static func normalize(_ items: [ReviewItem]) -> [ReviewItem] {
        var seen = Set<String>()
        var kept: [ReviewItem] = []
        let folders = items.filter { $0.node.isFolder }.map { standardized($0.node.path) }
        for item in items {
            guard seen.insert(item.node.id).inserted else { continue }
            let p = standardized(item.node.path)
            let nested = folders.contains { f in f != p && isWithin(p, root: f) }
            if nested { continue }
            kept.append(item)
        }
        return kept
    }

    // MARK: - Execution

    /// `plan` pairs each item with its authorized scope root. Runs wherever
    /// the caller puts it (detached worker in the app); `onEvent` must be
    /// thread-safe and non-blocking — no MainActor hops here.
    static func execute(plan: [(ReviewItem, URL)],
                        onEvent: @escaping (String) -> Void) async -> [CleanupResult] {
        var out: [CleanupResult] = []
        for (item, scope) in plan {
            if Task.isCancelled { break }
            onEvent(item.node.name)
            out.append(trashOne(item, scope: scope))
        }
        return out
    }

    private static func trashOne(_ item: ReviewItem, scope: URL) -> CleanupResult {
        let base = CleanupResult(id: item.id, name: item.node.name,
                                 path: item.node.path, bytes: item.node.logicalBytes,
                                 outcome: .missing)
        let url = URL(fileURLWithPath: item.node.path)
        switch revalidate(url: url, node: item.node, scope: scope) {
        case .ok: break
        case .blocked(let reason):
            var r = base; r.outcome = .blocked(reason); return r
        case .changed(let reason):
            var r = base; r.outcome = .skippedChanged(reason); return r
        case .gone:
            return base
        }

        do {
            var resulting: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            var r = base
            if let t = resulting as? URL {
                r.outcome = .moved(trashURL: t)
            } else {
                r.outcome = .moved(trashURL: url)
            }
            return r
        } catch {
            // Unsupported Trash never becomes permanent deletion.
            var r = base
            r.outcome = .failed((error as NSError).localizedDescription)
            return r
        }
    }

    // MARK: - Revalidation (identity, scope, type, metadata — just before op)

    private enum Revalidation { case ok, blocked(String), changed(String), gone }

    private static func revalidate(url: URL, node: ScanNode, scope: URL) -> Revalidation {
        // Resolve symlinked ancestors on both sides: lexical normalization
        // alone does not establish containment (P1).
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        let root = scope.standardizedFileURL.resolvingSymlinksInPath()

        // Scope containment (component-aware, never string-prefix).
        guard isWithin(target.path, root: root.path), target.path != root.path else {
            return .blocked("Outside the authorized location. Choose the folder again.")
        }
        if target.path == root.path {
            return .blocked("The location itself cannot be moved. Choose items inside it.")
        }
        for prefix in blockedPrefixes where target.path == prefix || isWithin(target.path, root: prefix) {
            return .blocked("Protected system location. SpareDisk doesn't clean system data.")
        }
        for marker in backupMarkers where target.path.contains(marker) {
            return .blocked("Backup storage. SpareDisk never touches backups.")
        }
        if managedExtensions.contains(target.pathExtension.lowercased()) {
            return .blocked("Managed by another app. Open that app to remove it.")
        }

        let vals: URLResourceValues
        do {
            vals = try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey,
                                                       .fileSizeKey, .contentModificationDateKey,
                                                       .isUbiquitousItemKey])
        } catch {
            return .gone
        }

        // Fail closed on links: the scanner never queues symlinks, so one here
        // means substitution since review — never trash through it (P1).
        if vals.isSymbolicLink == true {
            return .blocked("Became a link after review, so it was left alone. Remove it in Finder if intended.")
        }

        if vals.isUbiquitousItem == true {
            return .blocked("Not downloaded. Use Finder to delete it or remove the download.")
        }

        let isDir = vals.isDirectory ?? false
        if isDir != node.isFolder {
            return .changed("Changed type after review. Review it again.")
        }
        if node.isFolder {
            // `modified` is the directory's own mtime (scanner invariant, P1):
            // comparable with the live directory's own mtime.
            if let old = node.modified, let now = vals.contentModificationDate, old != now {
                return .changed("This folder changed after you added it. Review its updated contents.")
            }
            if let hit = firstManagedDescendant(in: target) {
                return .blocked("Contains \(hit), which is managed by another app.")
            }
        } else {
            let (fnum, vnum) = ScanEngine.identityNumbers(for: target)
            if !identityMatches(node: node, fileNumber: fnum, volumeNumber: vnum) {
                return .changed("Replaced after review by a different file with the same name.")
            }
            let sizeChanged = Int64(vals.fileSize ?? 0) != node.logicalBytes
            let dateChanged = (node.modified != nil && vals.contentModificationDate != nil
                               && node.modified != vals.contentModificationDate)
            if sizeChanged || dateChanged {
                return .changed("Changed after review. Review it again.")
            }
        }
        return .ok
    }

    /// Stable-identity comparison (ino/dev). Unknown stored identity falls
    /// back to size/date checks by the caller — never a false confirm.
    /// Pure function, unit-tested.
    static func identityMatches(node: ScanNode, fileNumber: UInt64?, volumeNumber: UInt64?) -> Bool {
        guard let stored = node.fsFileNumber, let live = fileNumber else { return true }
        guard stored == live else { return false }
        if let sv = node.fsVolumeNumber, let lv = volumeNumber, sv != lv { return false }
        return true
    }

    /// Bounded search for managed units nested in a reviewed folder.
    /// Returns the first hit's name, or nil (including cap exhaustion, which
    /// is a documented residual, not a silent guarantee).
    private static func firstManagedDescendant(in root: URL) -> String? {
        guard let e = FileManager.default.enumerator(at: root,
                                                     includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsPackageDescendants],
                                                     errorHandler: { _, _ in true }) else { return nil }
        var seen = 0
        while let u = e.nextObject() as? URL {
            seen += 1
            if seen > managedSearchCap { break }
            if managedExtensions.contains(u.pathExtension.lowercased()) {
                return u.lastPathComponent
            }
        }
        return nil
    }

    // MARK: - Path helpers

    static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Component-aware containment. `..` and sibling-prefix (`/Foo` vs
    /// `/Foobar`) can never false-positive. Pure function, unit-tested.
    static func isWithin(_ path: String, root: String) -> Bool {
        let a = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        let b = URL(fileURLWithPath: root).standardizedFileURL.pathComponents
        return a.count > b.count && Array(a.prefix(b.count)) == b
    }
}
