import Foundation

// Phase 1 scanner (§F02): metadata-only walk. Never reads file contents,
// never follows symlinks, never hydrates cloud content to draw a map.
// Streams batches so the UI is usable before completion — no fake %.
struct ScanProgress: Hashable {
    var itemsFound: Int
    var elapsed: TimeInterval
    var currentPath: String
}

struct ScanIssue: Hashable, Identifiable {
    let id = UUID()
    var path: String
    var message: String
}

struct ScanResult: Hashable {
    var locationID: String
    var rootName: String
    var totalBytes: Int64
    var itemCount: Int
    var topNodes: [ScanNode]
    var largestFiles: [ScanNode] = []
    var oldestFiles: [ScanNode] = []
    var issues: [ScanIssue]
    var startedAt: Date
    var finishedAt: Date
    var wasCancelled: Bool

    var elapsed: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
}

enum ScanEngine {
    static let batchSize = 2000
    private static let candidateCap = 200
    /// Extensions whose interiors are never individual cleanup candidates (§F08/F09).
    private static let interiorExtensions: Set<String> = [
        "app", "appex", "framework", "bundle", "photoslibrary",
        "mailbundle", "mbox", "qlgenerator", "mdimporter",
    ]

    /// Async shell: runs wherever the caller puts it (detached worker in the
    /// app). The walk itself is synchronous (see below) so no async-context
    /// enumerator use and no MainActor hops inside the loop.
    static func scan(locationID: String, rootName: String, root: URL,
                     onProgress: @escaping (ScanProgress) -> Void) async -> ScanResult {
        let started = Date()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
                                      .fileSizeKey, .totalFileAllocatedSizeKey,
                                      .contentModificationDateKey, .ubiquitousItemDownloadingStatusKey]
        var state = WalkState()
        guard let enumerator = FileManager.default.enumerator(at: root,
                                                              includingPropertiesForKeys: keys,
                                                              options: [],
                                                              errorHandler: { url, error -> Bool in
            state.issues.append(ScanIssue(path: url.path, message: (error as NSError).localizedDescription))
            return true // continue after ordinary per-item failures
        }) else {
            return ScanResult(locationID: locationID, rootName: rootName, totalBytes: 0,
                              itemCount: 0, topNodes: [], issues: state.issues,
                              startedAt: started, finishedAt: Date(), wasCancelled: false)
        }

        let rootComps = root.standardizedFileURL.pathComponents
        walk(enumerator: enumerator, keys: Set(keys), rootComps: rootComps,
             locationID: locationID, started: started,
             state: &state,
             shouldStop: { Task.isCancelled },
             onBatch: { count, name in
            // Called on the worker thread; the handler must be thread-safe
            // (the app yields into an AsyncStream here — no UI work).
            onProgress(ScanProgress(itemsFound: count,
                                    elapsed: Date().timeIntervalSince(started),
                                    currentPath: name))
        })

        // Two-level tree: top entries with their immediate children.
        // Deeper content is rolled into the child totals (see `sub`).
        let kids = state.agg.map { name, e -> ScanNode in
            let children = state.sub
                .filter { $0.key.hasPrefix(name + "/") }
                .map { key, s -> ScanNode in
                    let second = String(key.dropFirst(name.count + 1))
                    return ScanNode(id: "\(locationID)/\(name)/\(second)",
                                    name: second,
                                    path: root.appendingPathComponent(name).appendingPathComponent(second).path,
                                    isFolder: s.isDir, isPackage: s.isPkg, category: s.cat,
                                    logicalBytes: s.bytes, modified: s.own,
                                    childCount: max(s.count - 1, s.isDir ? 1 : 0),
                                    allocatedBytes: s.allocMeasured ? s.alloc : nil)
                }
                .sorted { $0.logicalBytes > $1.logicalBytes }
            return ScanNode(id: "\(locationID)/\(name)", name: name,
                            path: root.appendingPathComponent(name).path,
                            isFolder: e.isDir, isPackage: e.isPkg, category: e.cat,
                            logicalBytes: e.bytes, modified: e.own,
                            childCount: max(e.count - 1, e.isDir ? 1 : 0),
                            children: children.isEmpty ? nil : children,
                            allocatedBytes: e.allocMeasured ? e.alloc : nil)
        }.sorted { $0.logicalBytes > $1.logicalBytes }

        return ScanResult(locationID: locationID, rootName: rootName, totalBytes: state.total,
                          itemCount: state.count, topNodes: kids,
                          largestFiles: state.largest, oldestFiles: state.oldest,
                          issues: state.issues,
                          startedAt: started, finishedAt: Date(),
                          wasCancelled: Task.isCancelled)
    }

    // MARK: - Synchronous walk

    /// Mutable walk accumulation, kept in one struct so the sync walker can
    /// take it inout without touching actor state.
    private struct Agg {
        var bytes: Int64 = 0
        var count = 0
        var mod: Date?
        var own: Date?
        var isDir = true
        var isPkg = false
        var cat: SDFileCategory = .other
        var alloc: Int64 = 0
        var allocMeasured = false
    }

    /// Stable (device, inode) identity for hard-link dedup.
    private struct FileIdentity: Hashable {
        var dev: UInt64
        var ino: UInt64
    }

    /// Fold one visit into an aggregate. `own` is set only on the entry's
    /// own visit (P1: directory mtime is never a descendant summary).
    private static func accumulate(_ e: Agg, bytes: Int64, date: Date?,
                                   isOwnVisit: Bool, isDir: Bool, url: URL,
                                   isPkg: Bool, allocated: Int64?) -> Agg {
        var e = e
        e.bytes += bytes
        e.count += 1
        if let m = date, e.mod == nil || m > e.mod! { e.mod = m }
        if isOwnVisit {
            e.isDir = isDir
            e.isPkg = isPkg
            e.cat = category(for: url, isDir: isDir)
            e.own = date
        }
        if let a = allocated {
            e.alloc += a
            e.allocMeasured = true
        }
        return e
    }

    private struct WalkState {
        var total: Int64 = 0
        var count = 0
        var issues: [ScanIssue] = []
        /// Top-level aggregates by first component.
        var agg: [String: Agg] = [:]
        /// Second-level aggregates by "top/second", giving real drill-down
        /// one level deep (bounded by depth-2 fanout, typically thousands).
        /// Deeper content rolls into these totals; individual deep files
        /// surface only via the largest/oldest rankings.
        var sub: [String: Agg] = [:]
        var seenFiles = Set<FileIdentity>()
        var largest: [ScanNode] = []
        var smallestTracked: Int64 = 0
        var oldest: [ScanNode] = []
        var newestTracked: Date = .distantFuture
    }

    /// Plain synchronous iteration: `nextObject()` never crosses an await, so
    /// there is no async-context enumerator use (Swift 6 clean).
    private static func walk(enumerator: FileManager.DirectoryEnumerator,
                             keys: Set<URLResourceKey>,
                             rootComps: [String],
                             locationID: String,
                             started: Date,
                             state: inout WalkState,
                             shouldStop: () -> Bool,
                             onBatch: (Int, String) -> Void) {
        while let url = enumerator.nextObject() as? URL {
            if shouldStop() { break }
            do {
                let vals = try url.resourceValues(forKeys: keys)
                if vals.isSymbolicLink == true { continue } // record-link-don't-follow comes with full model; skip for totals
                let isDir = vals.isDirectory ?? false
                // Residency, not membership: only not-downloaded placeholders
                // are excluded from bulk cleanup. Downloaded iCloud files are
                // local files (P2 accounting finding).
                let isCloud = Self.cloudPlaceholder(status: vals.ubiquitousItemDownloadingStatus)
                // Logical basis for v1 (allocated shown independently in inspector when available).
                let bytes: Int64 = isDir ? 0 : Int64(vals.fileSize ?? 0) // folders aggregate from descendants
                let allocated: Int64? = isDir ? nil : vals.totalFileAllocatedSize.map { Int64($0) }
                // Stable identity + link count (one stat per file). Repeat
                // sightings of a hard link contribute no bytes anywhere:
                // totals count unique content, like du (P2 accounting).
                var linkCount = 1
                var identity: (file: UInt64?, volume: UInt64?) = (nil, nil)
                var isDuplicateLink = false
                if !isDir {
                    let idn = fileIdentity(for: url)
                    identity = (idn.file, idn.volume)
                    linkCount = idn.links
                    if linkCount > 1, let f = idn.file, let v = idn.volume {
                        let key = FileIdentity(dev: v, ino: f)
                        if state.seenFiles.contains(key) {
                            isDuplicateLink = true
                        } else {
                            state.seenFiles.insert(key)
                        }
                    }
                }
                let countedBytes = isDuplicateLink ? 0 : bytes
                let countedAlloc: Int64? = isDuplicateLink ? nil : allocated
                let stdComps = url.standardizedFileURL.pathComponents
                let relComps = Array(stdComps.dropFirst(rootComps.count))
                let top = relComps.first ?? url.lastPathComponent
                state.agg[top, default: Agg()] = accumulate(state.agg[top] ?? Agg(),
                                                            bytes: countedBytes, date: vals.contentModificationDate,
                                                            isOwnVisit: relComps.count <= 1,
                                                            isDir: isDir, url: url,
                                                            isPkg: vals.isPackage ?? false,
                                                            allocated: countedAlloc)
                if relComps.count >= 2 {
                    let key = relComps[0] + "/" + relComps[1]
                    state.sub[key, default: Agg()] = accumulate(state.sub[key] ?? Agg(),
                                                               bytes: countedBytes, date: vals.contentModificationDate,
                                                               isOwnVisit: relComps.count == 2,
                                                               isDir: isDir, url: url,
                                                               isPkg: vals.isPackage ?? false,
                                                               allocated: countedAlloc)
                }
                state.total += countedBytes
                state.count += 1

                // File-level candidates (never package/library/git interiors).
                if !isDir, var node = candidate(locationID: locationID, url: url, relComps: relComps,
                                                bytes: bytes, date: vals.contentModificationDate, cloud: isCloud) {
                    let wantsLargest = bytes > state.smallestTracked || state.largest.count < candidateCap
                    let wantsOldest = node.modified != nil
                        && (node.modified! < state.newestTracked || state.oldest.count < candidateCap)
                    if wantsLargest || wantsOldest {
                        // Stamp stable identity once, only for retained candidates (P1).
                        node.fsFileNumber = identity.file
                        node.fsVolumeNumber = identity.volume
                        node.hardLinkCount = linkCount
                        node.allocatedBytes = allocated
                    }
                    if wantsLargest {
                        state.largest.append(node)
                        state.largest.sort { $0.logicalBytes > $1.logicalBytes }
                        if state.largest.count > candidateCap { state.largest.removeLast() }
                        state.smallestTracked = state.largest.last?.logicalBytes ?? 0
                    }
                    if wantsOldest {
                        state.oldest.append(node)
                        state.oldest.sort { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }
                        if state.oldest.count > candidateCap { state.oldest.removeLast() }
                        state.newestTracked = state.oldest.last?.modified ?? .distantFuture
                    }
                }

                if state.count % batchSize == 0 {
                    onBatch(state.count, url.lastPathComponent)
                }
            } catch {
                state.issues.append(ScanIssue(path: url.path, message: (error as NSError).localizedDescription))
            }
        }
    }

    /// Placeholder test from download status alone. `nil` (non-cloud or
    /// unknown) is not a placeholder — membership without residency evidence
    /// never excludes a file. Pure function, unit-tested.
    static func cloudPlaceholder(status: URLUbiquitousItemDownloadingStatus?) -> Bool {
        status == .notDownloaded
    }

    /// Filesystem + volume numbers (ino/dev) for replacement detection at
    /// cleanup time. Metadata-only, follows no content.
    static func identityNumbers(for url: URL) -> (UInt64?, UInt64?) {
        let idn = fileIdentity(for: url)
        return (idn.file, idn.volume)
    }

    /// One stat yielding identity triple. Unknown stays nil/1 — callers
    /// fall back, never fabricate.
    private static func fileIdentity(for url: URL) -> (file: UInt64?, volume: UInt64?, links: Int) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return (nil, nil, 1)
        }
        let file = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
        let vol = (attrs[.systemNumber] as? NSNumber)?.uint64Value
        let links = (attrs[.referenceCount] as? NSNumber)?.intValue ?? 1
        return (file, vol, max(1, links))
    }

    private static func candidate(locationID: String, url: URL, relComps: [String],
                                  bytes: Int64, date: Date?, cloud: Bool) -> ScanNode? {
        // Skip interiors: any ancestor directory (including a packaged top level)
        // carrying a managed extension, plus .git.
        for comp in relComps.dropLast() {
            if comp == ".git" { return nil }
            let ext = (comp as NSString).pathExtension.lowercased()
            if !ext.isEmpty, interiorExtensions.contains(ext) { return nil }
        }
        return ScanNode(id: "\(locationID)#\(url.path)", name: url.lastPathComponent, path: url.path,
                        isFolder: false, category: category(for: url, isDir: false),
                        logicalBytes: bytes, modified: date, childCount: 0, isCloudPlaceholder: cloud)
    }

    private static func category(for url: URL, isDir: Bool) -> SDFileCategory {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "mp4", "mov", "mkv", "heic", "jpg", "jpeg", "png", "mp3", "wav": return .media
        case "zip", "dmg", "pkg", "tar", "gz", "iso": return .archives
        case "xcodeproj", "swift", "js", "ts", "py", "rs", "json": return .developer
        case "app": return .apps
        default: break
        }
        if isDir {
            let n = url.lastPathComponent.lowercased()
            if n == "library" || n == "system" { return .system }
            if n == "developer" || n == "node_modules" || n == "build" { return .developer }
            if n == "movies" || n == "music" || n == "photos" || n == "pictures" { return .media }
            if n == "downloads" { return .archives }
            if n == "documents" || n == "desktop" { return .documents }
        }
        return isDir ? .other : .documents
    }
}
