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
// device and the dataless flag, so nothing else is asked per item.
struct ScanProgress: Hashable {
    var itemsFound: Int
    var elapsed: TimeInterval
    var currentPath: String
    /// Top-level aggregates so far, largest first. Sizes only grow.
    var partialTop: [ScanNode] = []
    var partialBytes: Int64 = 0
    var partialAllocated: Int64 = 0
}

struct ScanIssue: Hashable, Identifiable, Codable {
    var id = UUID()
    var path: String
    var message: String
}

struct ScanResult: Hashable, Codable {
    var locationID: String
    var rootName: String
    /// Logical bytes of unique content.
    var totalBytes: Int64
    /// Bytes actually allocated on disk. Not-downloaded cloud files, sparse
    /// files and clones make this smaller than the logical total, which is
    /// why a folder can "contain" more than its volume holds.
    var totalAllocated: Int64 = 0
    var itemCount: Int
    var topNodes: [ScanNode]
    var largestFiles: [ScanNode] = []
    var oldestFiles: [ScanNode] = []
    var issues: [ScanIssue]
    var startedAt: Date
    var finishedAt: Date
    var wasCancelled: Bool

    var elapsed: TimeInterval { finishedAt.timeIntervalSince(startedAt) }

    init(locationID: String, rootName: String, totalBytes: Int64, totalAllocated: Int64 = 0, itemCount: Int,
         topNodes: [ScanNode], largestFiles: [ScanNode] = [], oldestFiles: [ScanNode] = [], issues: [ScanIssue],
         startedAt: Date, finishedAt: Date, wasCancelled: Bool) {
        self.locationID = locationID; self.rootName = rootName; self.totalBytes = totalBytes
        self.totalAllocated = totalAllocated; self.itemCount = itemCount; self.topNodes = topNodes
        self.largestFiles = largestFiles; self.oldestFiles = oldestFiles; self.issues = issues
        self.startedAt = startedAt; self.finishedAt = finishedAt; self.wasCancelled = wasCancelled
    }

    /// Tolerant decoding so saved scans from earlier builds still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        locationID = try c.decode(String.self, forKey: .locationID)
        rootName = try c.decode(String.self, forKey: .rootName)
        totalBytes = try c.decode(Int64.self, forKey: .totalBytes)
        totalAllocated = try c.decodeIfPresent(Int64.self, forKey: .totalAllocated) ?? 0
        itemCount = try c.decode(Int.self, forKey: .itemCount)
        topNodes = try c.decode([ScanNode].self, forKey: .topNodes)
        largestFiles = try c.decodeIfPresent([ScanNode].self, forKey: .largestFiles) ?? []
        oldestFiles = try c.decodeIfPresent([ScanNode].self, forKey: .oldestFiles) ?? []
        issues = try c.decodeIfPresent([ScanIssue].self, forKey: .issues) ?? []
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        finishedAt = try c.decode(Date.self, forKey: .finishedAt)
        wasCancelled = try c.decodeIfPresent(Bool.self, forKey: .wasCancelled) ?? false
    }
}

enum ScanEngine {
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
    /// app). The walk itself is synchronous so there is no async-context
    /// enumerator use and no MainActor hops inside the loop.
    static func scan(locationID: String, rootName: String, root: URL,
                     onProgress: @escaping (ScanProgress) -> Void) async -> ScanResult {
        let started = Date()
        // Issues are collected in a reference box: the enumerator's error
        // handler runs re-entrantly from `nextObject()` while `walk` holds
        // the accumulation struct `inout`. Sharing one struct between the two
        // is an exclusivity violation that aborts the process.
        let issues = IssueBox()
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [],
            options: [.producesRelativePathURLs],
            errorHandler: { url, error -> Bool in
                issues.append(ScanIssue(path: url.path, message: (error as NSError).localizedDescription))
                return true // continue after ordinary per-item failures
            }) else {
            return ScanResult(locationID: locationID, rootName: rootName, totalBytes: 0,
                              itemCount: 0, topNodes: [], issues: issues.items,
                              startedAt: started, finishedAt: Date(), wasCancelled: false)
        }

        var state = WalkState()
        let rootPath = root.standardizedFileURL.path
        walk(enumerator: enumerator, rootPath: rootPath, locationID: locationID, started: started,
             state: &state, shouldStop: { Task.isCancelled },
             onBatch: { count, name, partial, bytes, alloc in
            // Called on the worker thread; the handler must be thread-safe
            // (the app yields into an AsyncStream here, no UI work).
            onProgress(ScanProgress(itemsFound: count, elapsed: Date().timeIntervalSince(started),
                                    currentPath: name, partialTop: partial, partialBytes: bytes,
                                    partialAllocated: alloc))
        })

        return ScanResult(locationID: locationID, rootName: rootName, totalBytes: state.total,
                          totalAllocated: state.totalAlloc,
                          itemCount: state.count,
                          topNodes: buildTree(state: state, locationID: locationID, rootPath: rootPath),
                          largestFiles: state.largest, oldestFiles: state.oldest,
                          issues: issues.items,
                          startedAt: started, finishedAt: Date(),
                          wasCancelled: Task.isCancelled)
    }

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
    }

    private struct FileIdentity: Hashable {
        var dev: UInt64
        var ino: UInt64
    }

    private struct WalkState {
        var total: Int64 = 0
        var totalAlloc: Int64 = 0
        var count = 0
        /// Top-level aggregates by first component.
        var agg: [String: Agg] = [:]
        /// Second-level aggregates by "top/second". Deeper content rolls into
        /// these totals; deep files surface via the largest/oldest rankings
        /// and via focused drill-down scans.
        var sub: [String: Agg] = [:]
        var seenLinks = Set<FileIdentity>()
        var largest: [ScanNode] = []
        var smallestTracked: Int64 = 0
        var oldest: [ScanNode] = []
        var newestTracked: Date = .distantFuture
        var lastEmit = Date.distantPast
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
    }

    static func lstat(path: String) -> Stat? {
        var st = Darwin.stat()
        guard Darwin.lstat(path, &st) == 0 else { return nil }
        let mode = st.st_mode & S_IFMT
        let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)
                         + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000)
        return Stat(isDir: mode == S_IFDIR, isLink: mode == S_IFLNK, isRegular: mode == S_IFREG,
                    size: Int64(st.st_size), allocated: Int64(st.st_blocks) * 512,
                    modified: st.st_mtimespec.tv_sec == 0 ? nil : mtime,
                    links: Int(st.st_nlink), ino: UInt64(st.st_ino), dev: UInt64(UInt32(bitPattern: st.st_dev)),
                    dataless: isDataless(flags: st.st_flags))
    }

    /// Not-downloaded placeholder for iCloud Drive and File Provider volumes
    /// alike. Pure function, unit-tested.
    static func isDataless(flags: UInt32) -> Bool {
        flags & UInt32(SF_DATALESS) != 0
    }

    // MARK: - Synchronous walk

    private static func walk(enumerator: FileManager.DirectoryEnumerator,
                             rootPath: String,
                             locationID: String,
                             started: Date,
                             state: inout WalkState,
                             shouldStop: () -> Bool,
                             onBatch: (Int, String, [ScanNode], Int64, Int64) -> Void) {
        while let url = enumerator.nextObject() as? URL {
            if shouldStop() { break }
            let rel = url.relativePath
            guard !rel.isEmpty else { continue }
            let full = rootPath + "/" + rel
            guard let st = lstat(path: full) else { continue }
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
                    depth = 2 // or deeper; treated the same
                } else {
                    second = rel[after...]
                }
            }
            let name = url.lastPathComponent
            let ext = (name as NSString).pathExtension.lowercased()
            let isPkg = st.isDir && !ext.isEmpty && packageExtensions.contains(ext)

            // Hard links: repeat sightings of one inode contribute no bytes,
            // so totals count unique content like `du` (P2 accounting).
            var duplicateLink = false
            if !st.isDir, st.links > 1 {
                duplicateLink = !state.seenLinks.insert(FileIdentity(dev: st.dev, ino: st.ino)).inserted
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

            // File-level candidates: never package/library/git interiors.
            if st.isRegular, !insidePackage(rel: rel) {
                let wantsLargest = st.size > state.smallestTracked || state.largest.count < candidateCap
                let wantsOldest = st.modified != nil
                    && (st.modified! < state.newestTracked || state.oldest.count < candidateCap)
                if wantsLargest || wantsOldest {
                    let node = ScanNode(id: "\(locationID)#\(full)", name: name, path: full,
                                        isFolder: false, category: category(name: name, ext: ext, isDir: false),
                                        logicalBytes: st.size, modified: st.modified, childCount: 0,
                                        isCloudPlaceholder: st.dataless,
                                        fsFileNumber: st.ino, fsVolumeNumber: st.dev,
                                        allocatedBytes: st.allocated, hardLinkCount: st.links)
                    if wantsLargest {
                        insertSorted(&state.largest, node) { $0.logicalBytes > $1.logicalBytes }
                        if state.largest.count > candidateCap { state.largest.removeLast() }
                        state.smallestTracked = state.largest.last?.logicalBytes ?? 0
                    }
                    if wantsOldest {
                        insertSorted(&state.oldest, node) { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }
                        if state.oldest.count > candidateCap { state.oldest.removeLast() }
                        state.newestTracked = state.oldest.last?.modified ?? .distantFuture
                    }
                }
            }

            if state.count % batchSize == 0
                || (state.count % 256 == 0 && Date().timeIntervalSince(state.lastEmit) > batchInterval) {
                state.lastEmit = Date()
                onBatch(state.count, name, partialTop(state: state, locationID: locationID, rootPath: rootPath),
                        state.total, state.totalAlloc)
            }
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
    private static func insidePackage(rel: String) -> Bool {
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

    private static func partialTop(state: WalkState, locationID: String, rootPath: String) -> [ScanNode] {
        state.agg.map { name, e in
            node(id: "\(locationID)/\(name)", name: name, path: rootPath + "/" + name, agg: e)
        }.sorted { $0.logicalBytes > $1.logicalBytes }
    }

    private static func buildTree(state: WalkState, locationID: String, rootPath: String) -> [ScanNode] {
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

    private static func node(id: String, name: String, path: String, agg e: Agg) -> ScanNode {
        ScanNode(id: id, name: name, path: path,
                 isFolder: e.isDir, isPackage: e.isPkg, category: e.cat,
                 logicalBytes: e.bytes, modified: e.own,
                 childCount: max(e.count - 1, e.isDir ? 1 : 0),
                 isCloudPlaceholder: e.dataless,
                 allocatedBytes: e.alloc)
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
        "raw", "cr2", "cr3", "nef", "arw", "dng", "orf", "raf",
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
    ]
    private static let documentExt: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "txt", "rtf", "rtfd",
        "md", "csv", "epub", "mobi", "odt", "ods", "odp", "tex", "html", "htm", "eml", "ics", "vcf",
    ]

    static func category(name: String, ext: String, isDir: Bool) -> SDFileCategory {
        if ext == "app" { return .apps }
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

extension ScanEngine.Agg {
    /// Fold one visit. `own` is passed only on the entry's own visit, so a
    /// directory's mtime is its own, never a descendant summary (P1).
    fileprivate mutating func fold(bytes: Int64, alloc: Int64, own: ScanEngine.Stat?, name: String, ext: String, isPkg: Bool) {
        self.bytes += bytes
        self.alloc += alloc
        count += 1
        if let own {
            isDir = own.isDir
            self.isPkg = isPkg
            cat = ScanEngine.category(name: name, ext: ext, isDir: own.isDir)
            self.own = own.modified
            dataless = own.dataless
        }
    }
}
