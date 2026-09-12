import Foundation

// Phase 1 scanner (§F02): metadata-only walk. Never reads file contents,
// never follows symlinks, never hydrates cloud content to draw a map.
//
// Performance model (measured on ~/Library, 867k items, warm cache):
//   FileManager enumerator + resourceValues with 7 keys ......... 115 s
//   ... the iCloud download-status key alone accounted for ....... 70 s
//   ... standardizedFileURL.pathComponents per item .............. 16 s
//   ... attributesOfItem per file for link counts ................ 47 s
//   enumerator with no keys + one lstat per item ................. 34 s
// One lstat yields type, size, allocation, mtime, link count, inode,
// device and the dataless flag, so nothing else is asked per item. The walk
// runs one worker per core over a shared directory queue.
nonisolated struct ScanProgress: Hashable {
    var itemsFound: Int
    var elapsed: TimeInterval
    var currentPath: String
    /// Top-level aggregates so far, largest first. Sizes only grow.
    var partialTop: [ScanNode] = []
    var partialBytes: Int64 = 0
    var partialAllocated: Int64 = 0
}

nonisolated struct ScanIssue: Hashable, Identifiable, Codable {
    var id = UUID()
    var path: String
    var message: String
}

nonisolated struct ScanResult: Hashable, Codable {
    var locationID: String
    var rootName: String
    /// Logical bytes of unique content.
    var totalBytes: Int64
    /// Bytes actually allocated on disk. Not-downloaded cloud files, sparse
    /// files and clones make this smaller than the logical total, which is
    /// why a folder can "contain" more than its volume holds.
    var totalAllocated: Int64 = 0
    /// Logical bytes of files by category, keyed by SDFileCategory rawValue.
    var categoryBytes: [String: Int64] = [:]
    var itemCount: Int
    var topNodes: [ScanNode]
    var largestFiles: [ScanNode] = []
    /// The same ranking by allocated size, so switching to sizes on disk
    /// never hides a dense file behind sparse ones that only look large.
    var largestFilesOnDisk: [ScanNode] = []
    var oldestFiles: [ScanNode] = []
    var issues: [ScanIssue]
    var startedAt: Date
    var finishedAt: Date
    var wasCancelled: Bool

    var elapsed: TimeInterval { finishedAt.timeIntervalSince(startedAt) }

    /// Whether this scan recorded allocation at all. Results saved before
    /// allocation was tracked have none, and must not be mistaken for a
    /// folder that genuinely occupies nothing on disk.
    var allocationTracked: Bool { totalAllocated > 0 || topNodes.contains { $0.allocatedBytes != nil } }

    init(locationID: String, rootName: String, totalBytes: Int64, totalAllocated: Int64 = 0,
         categoryBytes: [String: Int64] = [:], itemCount: Int,
         topNodes: [ScanNode], largestFiles: [ScanNode] = [], largestFilesOnDisk: [ScanNode] = [],
         oldestFiles: [ScanNode] = [], issues: [ScanIssue],
         startedAt: Date, finishedAt: Date, wasCancelled: Bool) {
        self.locationID = locationID; self.rootName = rootName; self.totalBytes = totalBytes
        self.totalAllocated = totalAllocated; self.categoryBytes = categoryBytes
        self.itemCount = itemCount; self.topNodes = topNodes
        self.largestFiles = largestFiles; self.largestFilesOnDisk = largestFilesOnDisk
        self.oldestFiles = oldestFiles; self.issues = issues
        self.startedAt = startedAt; self.finishedAt = finishedAt; self.wasCancelled = wasCancelled
    }

    /// Tolerant decoding so saved scans from earlier builds still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        locationID = try c.decode(String.self, forKey: .locationID)
        rootName = try c.decode(String.self, forKey: .rootName)
        totalBytes = try c.decode(Int64.self, forKey: .totalBytes)
        totalAllocated = try c.decodeIfPresent(Int64.self, forKey: .totalAllocated) ?? 0
        categoryBytes = try c.decodeIfPresent([String: Int64].self, forKey: .categoryBytes) ?? [:]
        itemCount = try c.decode(Int.self, forKey: .itemCount)
        topNodes = try c.decode([ScanNode].self, forKey: .topNodes)
        largestFiles = try c.decodeIfPresent([ScanNode].self, forKey: .largestFiles) ?? []
        largestFilesOnDisk = try c.decodeIfPresent([ScanNode].self, forKey: .largestFilesOnDisk) ?? []
        oldestFiles = try c.decodeIfPresent([ScanNode].self, forKey: .oldestFiles) ?? []
        issues = try c.decodeIfPresent([ScanIssue].self, forKey: .issues) ?? []
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        finishedAt = try c.decode(Date.self, forKey: .finishedAt)
        wasCancelled = try c.decodeIfPresent(Bool.self, forKey: .wasCancelled) ?? false
    }
}

/// Explicitly nonisolated: the app target defaults every type to the main
/// actor, which would run the whole walk on the UI thread.
nonisolated enum ScanEngine {
    static let batchSize = 2000
    /// Progress is also emitted on time so slow folders (network, cloud
    /// providers) keep the counter moving.
    static let batchInterval: TimeInterval = 0.25
    private static let candidateCap = 200

    /// Directory extensions that are packages (opaque to the user). Their
    /// interiors are never individual cleanup candidates (§F08/F09) and the
    /// map never nests into them. A name test replaces the LaunchServices
    /// `isPackageKey` lookup, which is per-item expensive.
    static let packageExtensions: Set<String> = [
        "app", "appex", "framework", "bundle", "plugin", "kext", "xpc",
        "qlgenerator", "mdimporter", "prefpane", "saver", "wdgt",
        "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle",
        "mailbundle", "mbox", "xcodeproj", "xcworkspace", "playground",
        "pkg", "mpkg", "rtfd", "key", "pages", "numbers", "band", "sparsebundle",
        "scptd", "textclipping", "download", "pvm", "vmwarevm", "utm",
    ]

    /// Async shell: runs wherever the caller puts it (detached worker in the
    /// app). The walk itself is synchronous and parallel: a shared queue of
    /// directories feeds one worker per core, each with private aggregation
    /// state that is merged at the end. No MainActor hops inside the loop.
    static func scan(locationID: String, rootName: String, root: URL,
                     onProgress: @escaping (ScanProgress) -> Void) async -> ScanResult {
        let started = Date()
        let rootPath = root.standardizedFileURL.path
        let cancel = CancelFlag()
        let walker = ParallelWalk(rootPath: rootPath, locationID: locationID, started: started,
                                  cancel: cancel, onProgress: onProgress)
        let (state, issues) = await withTaskCancellationHandler {
            walker.run()
        } onCancel: {
            cancel.set()
        }
        return ScanResult(locationID: locationID, rootName: rootName, totalBytes: state.total,
                          totalAllocated: state.totalAlloc,
                          categoryBytes: Dictionary(uniqueKeysWithValues: state.byCategory.map { ($0.key.rawValue, $0.value) }),
                          itemCount: state.count,
                          topNodes: buildTree(state: state, locationID: locationID, rootPath: rootPath),
                          largestFiles: state.largest, largestFilesOnDisk: state.largestDisk, oldestFiles: state.oldest,
                          issues: issues,
                          startedAt: started, finishedAt: Date(),
                          wasCancelled: cancel.isSet || Task.isCancelled)
    }

    static var workerCount: Int { max(2, min(8, ProcessInfo.processInfo.activeProcessorCount)) }

    // MARK: - Aggregation state

    private final class IssueBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [ScanIssue] = []
        func append(_ i: ScanIssue) { lock.lock(); storage.append(i); lock.unlock() }
        var items: [ScanIssue] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    /// Mutable per-entry accumulation.
    fileprivate struct Agg {
        var bytes: Int64 = 0
        var alloc: Int64 = 0
        var count = 0
        var own: Date?
        var isDir = true
        var isPkg = false
        var cat: SDFileCategory = .other
        var dataless = false
        var ownedByOthers = false
        /// Inode and device of the entry itself, so Browse nodes carry the
        /// same identity as Find candidates and cleanup can detect replacement.
        var ino: UInt64 = 0
        var dev: UInt64 = 0
    }

    fileprivate struct FileIdentity: Hashable {
        var dev: UInt64
        var ino: UInt64
    }

    fileprivate struct WalkState {
        var total: Int64 = 0
        var totalAlloc: Int64 = 0
        var count = 0
        /// Logical bytes of regular files by category.
        var byCategory: [SDFileCategory: Int64] = [:]
        /// Top-level aggregates by first component.
        var agg: [String: Agg] = [:]
        /// Second-level aggregates by "top/second". Deeper content rolls into
        /// these totals; deep files surface via the largest/oldest rankings
        /// and via focused drill-down scans.
        var sub: [String: Agg] = [:]
        /// Hard-linked files this worker counted, for cross-worker reconciliation.
        var links: [FileIdentity: LinkHit] = [:]
        var largest: [ScanNode] = []
        var smallestTracked: Int64 = 0
        var largestDisk: [ScanNode] = []
        var smallestTrackedDisk: Int64 = 0
        var oldest: [ScanNode] = []
        var newestTracked: Date = .distantFuture
    }

    /// One lstat's worth of facts.
    struct Stat {
        var isDir: Bool
        var isLink: Bool
        var isRegular: Bool
        var size: Int64
        var allocated: Int64
        var modified: Date?
        var links: Int
        var ino: UInt64
        var dev: UInt64
        var dataless: Bool
        var uid: uid_t
    }

    static let currentUID = getuid()

    static func lstat(path: String) -> Stat? {
        var st = Darwin.stat()
        guard Darwin.lstat(path, &st) == 0 else { return nil }
        let mode = st.st_mode & S_IFMT
        let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)
                         + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000)
        return Stat(isDir: mode == S_IFDIR, isLink: mode == S_IFLNK, isRegular: mode == S_IFREG,
                    size: Int64(st.st_size), allocated: Int64(st.st_blocks) * 512,
                    // Dates before 1980 are placeholders left by archives and
                    // copies, not real history; they read as unknown.
                    modified: st.st_mtimespec.tv_sec < 315_532_800 ? nil : mtime,
                    links: Int(st.st_nlink), ino: UInt64(st.st_ino), dev: UInt64(UInt32(bitPattern: st.st_dev)),
                    dataless: isDataless(flags: st.st_flags), uid: st.st_uid)
    }

    /// Not-downloaded placeholder for iCloud Drive and File Provider volumes
    /// alike. Pure function, unit-tested.
    static func isDataless(flags: UInt32) -> Bool {
        flags & UInt32(SF_DATALESS) != 0
    }

    // MARK: - Parallel walk

    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// A hard-linked file seen by one worker; used to reconcile links that
    /// different workers counted independently.
    fileprivate struct LinkHit {
        var top: String
        var sub: String?
        var bytes: Int64
        var alloc: Int64
        var cat: SDFileCategory
    }

    fileprivate final class ParallelWalk: @unchecked Sendable {
        let rootPath: String
        let locationID: String
        let started: Date
        let cancel: CancelFlag
        let onProgress: (ScanProgress) -> Void

        private let cond = NSCondition()
        private var queue: [String] = [""]
        private var inFlight = 0

        private let progressLock = NSLock()
        private var sharedCount = 0
        private var lastEmitCount = 0
        private var lastEmit = Date.distantPast
        private var snapshots: [[String: Agg]]
        private var snapshotTotals: [(Int64, Int64)]
        private let issues = IssueBox()

        init(rootPath: String, locationID: String, started: Date, cancel: CancelFlag,
             onProgress: @escaping (ScanProgress) -> Void) {
            self.rootPath = rootPath; self.locationID = locationID; self.started = started
            self.cancel = cancel; self.onProgress = onProgress
            snapshots = Array(repeating: [:], count: ScanEngine.workerCount)
            snapshotTotals = Array(repeating: (0, 0), count: ScanEngine.workerCount)
        }

        func run() -> (WalkState, [ScanIssue]) {
            let n = ScanEngine.workerCount
            var states = Array(repeating: WalkState(), count: n)
            let statesLock = NSLock()
            DispatchQueue.concurrentPerform(iterations: n) { index in
                var local = WalkState()
                var links: [FileIdentity: LinkHit] = [:]
                var sinceSnapshot = 0
                while let dir = nextDirectory() {
                    let added = process(dir: dir, state: &local, links: &links)
                    finished(dir: dir)
                    sinceSnapshot += added
                    if sinceSnapshot >= 256 {
                        publish(index: index, state: local, added: sinceSnapshot)
                        sinceSnapshot = 0
                    }
                }
                publish(index: index, state: local, added: sinceSnapshot, force: true)
                local.links = links
                statesLock.lock(); states[index] = local; statesLock.unlock()
            }
            return (merge(states), issues.items)
        }

        // MARK: Queue

        private func nextDirectory() -> String? {
            cond.lock()
            defer { cond.unlock() }
            while queue.isEmpty && inFlight > 0 && !cancel.isSet { cond.wait() }
            if cancel.isSet || queue.isEmpty { return nil }
            inFlight += 1
            return queue.removeLast()
        }

        private func finished(dir: String) {
            cond.lock()
            inFlight -= 1
            cond.broadcast()
            cond.unlock()
        }

        private func enqueue(_ dirs: [String]) {
            guard !dirs.isEmpty else { return }
            cond.lock()
            queue.append(contentsOf: dirs)
            cond.broadcast()
            cond.unlock()
        }

        // MARK: Work

        /// Reads one directory, folds its children, queues subdirectories.
        /// Returns the number of items folded.
        private func process(dir: String, state: inout WalkState, links: inout [FileIdentity: LinkHit]) -> Int {
            let full = dir.isEmpty ? rootPath : rootPath + "/" + dir
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: full)
            } catch {
                issues.append(ScanIssue(path: full, message: (error as NSError).localizedDescription))
                return 0
            }
            var subdirs: [String] = []
            var added = 0
            for name in names {
                if cancel.isSet { break }
                let rel = dir.isEmpty ? name : dir + "/" + name
                let path = rootPath + "/" + rel
                guard let st = ScanEngine.lstat(path: path) else { continue }
                if st.isLink { continue } // never followed, never counted (§F02)

                // Components without allocating an array: top, optional second, depth.
                var top = Substring(rel)
                var second: Substring?
                var depth = 0
                if let i = rel.firstIndex(of: "/") {
                    top = rel[..<i]
                    depth = 1
                    let after = rel.index(after: i)
                    if let j = rel[after...].firstIndex(of: "/") {
                        second = rel[after..<j]
                        depth = 2
                    } else {
                        second = rel[after...]
                    }
                }
                let ext = (name as NSString).pathExtension.lowercased()
                let isPkg = st.isDir && !ext.isEmpty && ScanEngine.packageExtensions.contains(ext)

                // Hard links: one inode contributes bytes once per worker;
                // cross-worker repeats are reconciled in `merge`.
                var duplicateLink = false
                if !st.isDir, st.links > 1 {
                    let key = FileIdentity(dev: st.dev, ino: st.ino)
                    if links[key] != nil {
                        duplicateLink = true
                    } else {
                        links[key] = LinkHit(top: String(top), sub: second.map { String(top) + "/" + String($0) },
                                             bytes: st.size, alloc: st.allocated,
                                             cat: ScanEngine.category(name: name, ext: ext, isDir: false, size: st.size))
                    }
                }
                let bytes = st.isDir || duplicateLink ? 0 : st.size
                let alloc = st.isDir || duplicateLink ? 0 : st.allocated

                state.agg[String(top), default: Agg()].fold(bytes: bytes, alloc: alloc, own: depth == 0 ? st : nil,
                                                             name: name, ext: ext, isPkg: isPkg)
                if let second {
                    state.sub[String(top) + "/" + String(second), default: Agg()]
                        .fold(bytes: bytes, alloc: alloc, own: depth == 1 ? st : nil, name: name, ext: ext, isPkg: isPkg)
                }
                state.total += bytes
                state.totalAlloc += alloc
                state.count += 1
                added += 1
                if st.isRegular, bytes > 0 {
                    state.byCategory[ScanEngine.category(name: name, ext: ext, isDir: false, size: st.size), default: 0] += bytes
                }

                if st.isDir {
                    subdirs.append(rel)
                } else if st.isRegular, !ScanEngine.insidePackage(rel: rel) {
                    ScanEngine.consider(candidate: st, name: name, path: path, ext: ext,
                                        locationID: locationID, state: &state)
                }
            }
            enqueue(subdirs)
            return added
        }

        // MARK: Progress

        private func publish(index: Int, state: WalkState, added: Int, force: Bool = false) {
            progressLock.lock()
            snapshots[index] = state.agg
            snapshotTotals[index] = (state.total, state.totalAlloc)
            sharedCount += added
            let now = Date()
            let due = force || sharedCount - lastEmitCount >= ScanEngine.batchSize
                || now.timeIntervalSince(lastEmit) > ScanEngine.batchInterval
            guard due, sharedCount > lastEmitCount else { progressLock.unlock(); return }
            lastEmit = now
            lastEmitCount = sharedCount
            var merged: [String: Agg] = [:]
            for snap in snapshots {
                for (k, v) in snap {
                    if var e = merged[k] { e.add(v); merged[k] = e } else { merged[k] = v }
                }
            }
            let totals = snapshotTotals.reduce((Int64(0), Int64(0))) { ($0.0 + $1.0, $0.1 + $1.1) }
            let count = sharedCount
            progressLock.unlock()
            let partial = merged.map { name, e in
                ScanEngine.node(id: "\(locationID)/\(name)", name: name, path: rootPath + "/" + name, agg: e)
            }.sorted { $0.logicalBytes > $1.logicalBytes }
            onProgress(ScanProgress(itemsFound: count, elapsed: now.timeIntervalSince(started),
                                    currentPath: partial.first?.name ?? "",
                                    partialTop: partial, partialBytes: totals.0, partialAllocated: totals.1))
        }

        // MARK: Merge

        private func merge(_ states: [WalkState]) -> WalkState {
            var out = WalkState()
            var seen: [FileIdentity: Bool] = [:]
            for s in states {
                for (k, v) in s.agg { if var e = out.agg[k] { e.add(v); out.agg[k] = e } else { out.agg[k] = v } }
                for (k, v) in s.sub { if var e = out.sub[k] { e.add(v); out.sub[k] = e } else { out.sub[k] = v } }
                out.total += s.total
                out.totalAlloc += s.totalAlloc
                for (k, v) in s.byCategory { out.byCategory[k, default: 0] += v }
                out.count += s.count
                // A link counted by two workers: keep the first, subtract the second.
                for (id, hit) in s.links {
                    if seen[id] == true {
                        out.total -= hit.bytes
                        out.totalAlloc -= hit.alloc
                        out.byCategory[hit.cat, default: 0] -= hit.bytes
                        out.agg[hit.top]?.bytes -= hit.bytes
                        out.agg[hit.top]?.alloc -= hit.alloc
                        if let sub = hit.sub {
                            out.sub[sub]?.bytes -= hit.bytes
                            out.sub[sub]?.alloc -= hit.alloc
                        }
                    } else {
                        seen[id] = true
                    }
                }
                out.largest.append(contentsOf: s.largest)
                out.largestDisk.append(contentsOf: s.largestDisk)
                out.oldest.append(contentsOf: s.oldest)
            }
            out.largest.sort { $0.logicalBytes > $1.logicalBytes }
            if out.largest.count > candidateCap { out.largest.removeLast(out.largest.count - candidateCap) }
            out.largestDisk.sort { ($0.allocatedBytes ?? 0) > ($1.allocatedBytes ?? 0) }
            if out.largestDisk.count > candidateCap { out.largestDisk.removeLast(out.largestDisk.count - candidateCap) }
            out.oldest.sort { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }
            if out.oldest.count > candidateCap { out.oldest.removeLast(out.oldest.count - candidateCap) }
            return out
        }
    }

    /// Track a regular file in the bounded largest/oldest rankings.
    fileprivate static func consider(candidate st: Stat, name: String, path: String, ext: String,
                                     locationID: String, state: inout WalkState) {
        let wantsLargest = st.size > state.smallestTracked || state.largest.count < candidateCap
        let wantsLargestDisk = st.allocated > state.smallestTrackedDisk || state.largestDisk.count < candidateCap
        let wantsOldest = st.modified != nil
            && (st.modified! < state.newestTracked || state.oldest.count < candidateCap)
        guard wantsLargest || wantsLargestDisk || wantsOldest else { return }
        let node = ScanNode(id: "\(locationID)#\(path)", name: name, path: path,
                            isFolder: false, category: category(name: name, ext: ext, isDir: false, size: st.size),
                            logicalBytes: st.size, modified: st.modified, childCount: 0,
                            isCloudPlaceholder: st.dataless,
                            fsFileNumber: st.ino, fsVolumeNumber: st.dev,
                            allocatedBytes: st.allocated, hardLinkCount: st.links,
                            ownedByOthers: st.uid != currentUID)
        if wantsLargest {
            insertSorted(&state.largest, node) { $0.logicalBytes > $1.logicalBytes }
            if state.largest.count > candidateCap { state.largest.removeLast() }
            state.smallestTracked = state.largest.last?.logicalBytes ?? 0
        }
        if wantsLargestDisk {
            insertSorted(&state.largestDisk, node) { ($0.allocatedBytes ?? 0) > ($1.allocatedBytes ?? 0) }
            if state.largestDisk.count > candidateCap { state.largestDisk.removeLast() }
            state.smallestTrackedDisk = state.largestDisk.last?.allocatedBytes ?? 0
        }
        if wantsOldest {
            insertSorted(&state.oldest, node) { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }
            if state.oldest.count > candidateCap { state.oldest.removeLast() }
            state.newestTracked = state.oldest.last?.modified ?? .distantFuture
        }
    }

    private static func insertSorted(_ array: inout [ScanNode], _ node: ScanNode,
                                     by before: (ScanNode, ScanNode) -> Bool) {
        var lo = 0, hi = array.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if before(array[mid], node) { lo = mid + 1 } else { hi = mid }
        }
        array.insert(node, at: lo)
    }

    /// Any ancestor directory carrying a package extension, or `.git`.
    fileprivate static func insidePackage(rel: String) -> Bool {
        var start = rel.startIndex
        while let slash = rel[start...].firstIndex(of: "/") {
            let comp = rel[start..<slash]
            if comp == ".git" { return true }
            if let dot = comp.lastIndex(of: "."), dot != comp.startIndex {
                let ext = comp[comp.index(after: dot)...].lowercased()
                if packageExtensions.contains(ext) { return true }
            }
            start = rel.index(after: slash)
        }
        return false
    }

    // MARK: - Tree assembly

    fileprivate static func buildTree(state: WalkState, locationID: String, rootPath: String) -> [ScanNode] {
        // Group second-level aggregates under their top entry once, not per top.
        var childrenByTop: [String: [ScanNode]] = [:]
        for (key, s) in state.sub {
            guard let slash = key.firstIndex(of: "/") else { continue }
            let top = String(key[..<slash])
            let second = String(key[key.index(after: slash)...])
            childrenByTop[top, default: []].append(
                node(id: "\(locationID)/\(top)/\(second)", name: second,
                     path: rootPath + "/" + top + "/" + second, agg: s))
        }
        return state.agg.map { name, e in
            var n = node(id: "\(locationID)/\(name)", name: name, path: rootPath + "/" + name, agg: e)
            if let kids = childrenByTop[name], !kids.isEmpty, e.isDir {
                n.children = kids.sorted { $0.logicalBytes > $1.logicalBytes }
            }
            return n
        }.sorted { $0.logicalBytes > $1.logicalBytes }
    }

    fileprivate static func node(id: String, name: String, path: String, agg e: Agg) -> ScanNode {
        ScanNode(id: id, name: name, path: path,
                 isFolder: e.isDir, isPackage: e.isPkg, category: e.cat,
                 logicalBytes: e.bytes, modified: e.own,
                 childCount: max(e.count - 1, e.isDir ? 1 : 0),
                 isCloudPlaceholder: e.dataless,
                 fsFileNumber: e.own == nil ? nil : e.ino,
                 fsVolumeNumber: e.own == nil ? nil : e.dev,
                 allocatedBytes: e.alloc,
                 ownedByOthers: e.ownedByOthers)
    }

    // MARK: - Identity for cleanup revalidation

    /// Inode and device numbers for replacement detection at cleanup time.
    static func identityNumbers(for url: URL) -> (UInt64?, UInt64?) {
        guard let st = lstat(path: url.path) else { return (nil, nil) }
        return (st.ino, st.dev)
    }

    /// Kept for callers that already hold a download status. `nil` (non-cloud
    /// or unknown) is not a placeholder.
    static func cloudPlaceholder(status: URLUbiquitousItemDownloadingStatus?) -> Bool {
        status == .notDownloaded
    }

    // MARK: - Classification

    private static let mediaExt: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "avi", "webm", "wmv", "flv", "mts", "m2ts", "mxf", "prores",
        "heic", "heif", "jpg", "jpeg", "png", "gif", "tif", "tiff", "bmp", "webp", "psd", "ai", "svg",
        "raw", "cr2", "cr3", "nef", "arw", "dng", "orf", "raf", "rw2", "pef", "srw", "x3f", "3fr", "iiq",
        "nrw", "erf", "mrw", "dcr", "kdc", "rwl", "srf", "sr2",
        "mp3", "wav", "aac", "m4a", "flac", "aif", "aiff", "ogg", "alac", "caf",
        "sketch", "fig", "afdesign", "afphoto", "procreate", "blend", "c4d", "fbx", "obj", "usdz",
    ]
    private static let archiveExt: Set<String> = [
        "zip", "dmg", "pkg", "mpkg", "tar", "gz", "tgz", "bz2", "xz", "zst", "7z", "rar", "iso", "img",
        "msi", "exe", "apk", "ipa", "xip", "sit", "sitx", "cab", "deb", "rpm",
    ]
    private static let developerExt: Set<String> = [
        "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "js", "jsx", "ts", "tsx", "py", "rb", "rs", "go",
        "java", "kt", "kts", "cs", "php", "sh", "zsh", "json", "yaml", "yml", "toml", "xml", "plist",
        "xcodeproj", "xcworkspace", "playground", "o", "a", "dylib", "so", "wasm", "jar", "class",
        "xcarchive", "ipsw", "simruntime", "sqlite", "db", "realm",
        // Virtual machine and container disks.
        "qcow2", "qcow", "vmdk", "vdi", "vhd", "vhdx", "hdd", "hds", "utm",
    ]

    /// Camera raw files top out well under this; a ".raw" this large is a
    /// disk image (Docker, QEMU), which belongs with developer data.
    static let largestCameraRaw: Int64 = 1_000_000_000
    private static let documentExt: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "txt", "rtf", "rtfd",
        "md", "csv", "epub", "mobi", "odt", "ods", "odp", "tex", "html", "htm", "eml", "ics", "vcf",
    ]

    static func category(name: String, ext: String, isDir: Bool, size: Int64 = 0) -> SDFileCategory {
        if ext == "app" { return .apps }
        if ext == "raw", size >= largestCameraRaw || name.lowercased() == "docker.raw" { return .developer }
        if mediaExt.contains(ext) { return .media }
        if archiveExt.contains(ext) { return .archives }
        if developerExt.contains(ext) { return .developer }
        if documentExt.contains(ext) { return .documents }
        if isDir {
            switch name.lowercased() {
            case "library", "system", "caches", "logs", "application support", "containers", "group containers":
                return .system
            case "developer", "node_modules", "build", ".build", "deriveddata", "target", "dist", "venv", ".venv",
                 "pods", "carthage", ".gradle", ".m2", ".cargo", ".npm", ".cache":
                return .developer
            case "movies", "music", "photos", "pictures":
                return .media
            case "downloads":
                return .archives
            case "documents", "desktop":
                return .documents
            case "applications":
                return .apps
            default:
                return .other
            }
        }
        return ext.isEmpty ? .other : .unknown
    }
}

nonisolated extension ScanEngine.Agg {
    /// Fold one visit. `own` is passed only on the entry's own visit, so a
    /// directory's mtime is its own, never a descendant summary (P1).
    /// Merge another worker's aggregate for the same entry.
    fileprivate mutating func add(_ o: ScanEngine.Agg) {
        bytes += o.bytes
        alloc += o.alloc
        count += o.count
        if o.own != nil {
            own = o.own; isDir = o.isDir; isPkg = o.isPkg; cat = o.cat; dataless = o.dataless
            ownedByOthers = o.ownedByOthers; ino = o.ino; dev = o.dev
        }
    }

    fileprivate mutating func fold(bytes: Int64, alloc: Int64, own: ScanEngine.Stat?, name: String, ext: String, isPkg: Bool) {
        self.bytes += bytes
        self.alloc += alloc
        count += 1
        if let own {
            isDir = own.isDir
            self.isPkg = isPkg
            cat = ScanEngine.category(name: name, ext: ext, isDir: own.isDir, size: own.size)
            self.own = own.modified
            dataless = own.dataless
            ownedByOthers = own.uid != ScanEngine.currentUID
            ino = own.ino
            dev = own.dev
        }
    }
}
