import AppKit
import Foundation
import SwiftUI

// MARK: - Categories (mutually exclusive for totals, §F04)

nonisolated enum SDFileCategory: String, CaseIterable, Identifiable, Hashable, Codable {
    case documents, media, archives, developer, apps, system
    case other, unknown

    var id: String { rawValue }

    var label: String {
        switch self {
        case .documents: "Documents"
        case .media: "Media"
        case .archives: "Archives & Installers"
        case .developer: "Developer"
        case .apps: "Applications"
        case .system: "System & Library"
        case .other: "Other"
        case .unknown: "Unknown"
        }
    }

    var symbol: String {
        switch self {
        case .documents: "doc.fill"
        case .media: "photo.fill"
        case .archives: "archivebox.fill"
        case .developer: "hammer.fill"
        case .apps: "app.badge.fill"
        case .system: "gearshape.fill"
        case .other: "folder.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }
}

// MARK: - Nodes

nonisolated struct ScanNode: Identifiable, Hashable, Codable {
    let id: String
    var name: String
    var path: String
    var isFolder: Bool
    var isPackage: Bool = false
    var category: SDFileCategory
    var logicalBytes: Int64
    var modified: Date?
    var childCount: Int
    var children: [ScanNode]?
    var isCloudPlaceholder: Bool = false
    var isUnreadable: Bool = false
    /// Stable filesystem identity for files (nil when unknown — falls back to size/date).
    /// For folders, `modified` carries the directory's own mtime, never a descendant summary.
    var fsFileNumber: UInt64? = nil
    var fsVolumeNumber: UInt64? = nil
    /// Measured on-disk allocation, independent of logical size (nil = not measured).
    var allocatedBytes: Int64? = nil
    /// Hard-link count at scan time (1 = ordinary file). Trashing one link
    /// of many frees no unique storage.
    var hardLinkCount: Int = 1
    /// Owned by root or another user. Finder can move such items with an
    /// administrator password; a sandboxed app cannot.
    var ownedByOthers: Bool = false

    var isUnknownDate: Bool { modified == nil }

    init(id: String, name: String, path: String, isFolder: Bool, isPackage: Bool = false,
         category: SDFileCategory, logicalBytes: Int64, modified: Date?, childCount: Int,
         children: [ScanNode]? = nil, isCloudPlaceholder: Bool = false, isUnreadable: Bool = false,
         fsFileNumber: UInt64? = nil, fsVolumeNumber: UInt64? = nil, allocatedBytes: Int64? = nil,
         hardLinkCount: Int = 1, ownedByOthers: Bool = false) {
        self.id = id; self.name = name; self.path = path; self.isFolder = isFolder; self.isPackage = isPackage
        self.category = category; self.logicalBytes = logicalBytes; self.modified = modified
        self.childCount = childCount; self.children = children; self.isCloudPlaceholder = isCloudPlaceholder
        self.isUnreadable = isUnreadable; self.fsFileNumber = fsFileNumber; self.fsVolumeNumber = fsVolumeNumber
        self.allocatedBytes = allocatedBytes; self.hardLinkCount = hardLinkCount; self.ownedByOthers = ownedByOthers
    }

    /// Tolerant decoding so saved scans from earlier builds still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        isFolder = try c.decode(Bool.self, forKey: .isFolder)
        isPackage = try c.decodeIfPresent(Bool.self, forKey: .isPackage) ?? false
        category = try c.decodeIfPresent(SDFileCategory.self, forKey: .category) ?? .other
        logicalBytes = try c.decode(Int64.self, forKey: .logicalBytes)
        modified = try c.decodeIfPresent(Date.self, forKey: .modified)
        childCount = try c.decodeIfPresent(Int.self, forKey: .childCount) ?? 0
        children = try c.decodeIfPresent([ScanNode].self, forKey: .children)
        isCloudPlaceholder = try c.decodeIfPresent(Bool.self, forKey: .isCloudPlaceholder) ?? false
        isUnreadable = try c.decodeIfPresent(Bool.self, forKey: .isUnreadable) ?? false
        fsFileNumber = try c.decodeIfPresent(UInt64.self, forKey: .fsFileNumber)
        fsVolumeNumber = try c.decodeIfPresent(UInt64.self, forKey: .fsVolumeNumber)
        allocatedBytes = try c.decodeIfPresent(Int64.self, forKey: .allocatedBytes)
        hardLinkCount = try c.decodeIfPresent(Int.self, forKey: .hardLinkCount) ?? 1
        ownedByOthers = try c.decodeIfPresent(Bool.self, forKey: .ownedByOthers) ?? false
    }

    func share(of total: Int64) -> Double {
        guard total > 0 else { return 0 }
        return Double(logicalBytes) / Double(total)
    }
}

// MARK: - Locations

nonisolated struct SDLocation: Identifiable, Hashable {
    enum Access: Hashable {
        case available, partiallyAccessible(String), reconnectRequired, unavailable, notGranted
        var label: String {
            switch self {
            case .available: "Available"
            case .partiallyAccessible(let s): s
            case .reconnectRequired: "Reconnect required"
            case .unavailable: "Unavailable"
            case .notGranted: "Not granted"
            }
        }
        var isOK: Bool {
            if case .available = self { return true }
            return false
        }
    }
    let id: String
    var name: String
    var symbol: String
    var isExternal: Bool
    var access: Access
    var capacityBytes: Int64
    var availableBytes: Int64
    /// Volume the folder lives on, so the storage picture never adds a
    /// folder on one disk to the capacity of another.
    var volumeUUID: String? = nil
    var volumeName: String? = nil
    var scannedBytes: Int64
    var scannedAt: Date
    var issues: Int
}

// MARK: - Review

nonisolated struct ReviewItem: Identifiable, Hashable {
    let id: String
    var node: ScanNode
    var source: String
    var reason: String
    var risk: String
    /// When the figures the user saw were taken: the finish time of the scan
    /// they came from. Anything inside a folder modified after this instant
    /// means the folder is no longer what was reviewed.
    var verifiedAt: Date = Date()
}

// MARK: - App state

enum SDSidebarSelection: Hashable {
    case overview
    case location(String)
    case largeFiles
    case olderFiles
    case fileTypes
    case duplicates
    case review
}

enum SDViewMode: String, CaseIterable {
    case list = "List"
    case map = "Map"
    case sunburst = "Sunburst"
}

/// What the map's colors mean.
enum SDMapColor: String, CaseIterable {
    case folder, type, age
    var label: String {
        switch self {
        case .folder: "By Folder"
        case .type: "By Type"
        case .age: "By Age"
        }
    }
}

enum SDSortField: String, CaseIterable {
    case name, size, modified
}

/// Which number the app shows and weighs by. Logical is what a file would
/// hold if fully downloaded and uncompressed; on disk is what it occupies.
enum SDSizeBasis: String, CaseIterable {
    case logical, onDisk
    var label: String { self == .logical ? "Logical Size" : "Size on Disk" }
}

@Observable
final class AppState {
    var selection: SDSidebarSelection = .overview {
        didSet {
            guard selection != oldValue else { return }
            if !traversingHistory {
                backStack.append(oldValue)
                forwardStack.removeAll()
            }
            if case .location(let id) = selection { activeLocationID = id }
            searchText = ""
            inspectedNodeID = nil
            selectedIDs = []
            mapTrail.removeAll()
        }
    }
    private var backStack: [SDSidebarSelection] = []
    private var forwardStack: [SDSidebarSelection] = []
    private var traversingHistory = false
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var showAbout = false
    var showScanIssues = false

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(selection)
        traversingHistory = true
        selection = previous
        traversingHistory = false
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(selection)
        traversingHistory = true
        selection = next
        traversingHistory = false
    }
    var viewMode: SDViewMode = SDViewMode(rawValue: UserDefaults.standard.string(forKey: "viewMode") ?? "") ?? .list {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: "viewMode") }
    }
    var sortField: SDSortField = SDSortField(rawValue: UserDefaults.standard.string(forKey: "sortField") ?? "") ?? .size {
        didSet { UserDefaults.standard.set(sortField.rawValue, forKey: "sortField") }
    }
    var sortAscending: Bool = UserDefaults.standard.object(forKey: "sortAscending") as? Bool ?? false {
        didSet { UserDefaults.standard.set(sortAscending, forKey: "sortAscending") }
    }
    var mapColor: SDMapColor = SDMapColor(rawValue: UserDefaults.standard.string(forKey: "mapColor") ?? "") ?? .folder {
        didSet { UserDefaults.standard.set(mapColor.rawValue, forKey: "mapColor") }
    }
    var sizeBasis: SDSizeBasis = SDSizeBasis(rawValue: UserDefaults.standard.string(forKey: "sizeBasis") ?? "") ?? .logical {
        didSet { UserDefaults.standard.set(sizeBasis.rawValue, forKey: "sizeBasis") }
    }

    /// The displayed and weighed size of a node under the current basis.
    /// Nodes scanned before allocation was tracked fall back to logical.
    func bytes(_ node: ScanNode) -> Int64 {
        switch sizeBasis {
        case .logical: return node.logicalBytes
        case .onDisk: return node.allocatedBytes ?? node.logicalBytes
        }
    }

    /// True when a node occupies far less than its logical size, so the
    /// logical figure would mislead: sparse, cloned or not-downloaded files.
    func hasDiskHint(_ node: ScanNode) -> Bool {
        guard sizeBasis == .logical, let a = node.allocatedBytes, node.logicalBytes >= 50_000_000 else { return false }
        return a * 2 < node.logicalBytes
    }

    var searchText = ""
    /// Every selected row. The newest selection drives the inspector.
    var selectedIDs: Set<String> = [] {
        didSet {
            guard selectedIDs != oldValue else { return }
            let added = selectedIDs.subtracting(oldValue)
            if let newest = added.first ?? selectedIDs.first {
                if inspectedNodeID != newest { inspectedNodeID = newest }
            } else if selectedIDs.isEmpty {
                inspectedNodeID = nil
            }
        }
    }
    var selectedNodes: [ScanNode] { selectedIDs.compactMap { nodeIndex[$0] } }
    var inspectedNodeID: String? {
        didSet {
            if let id = inspectedNodeID {
                showInspector = true
                if !selectedIDs.contains(id) { selectedIDs = [id] }
            } else if !selectedIDs.isEmpty {
                selectedIDs = []
            }
        }
    }
    var reviewItems: [ReviewItem] = []
    var showInspector: Bool = UserDefaults.standard.object(forKey: "showInspector") as? Bool ?? false {
        didSet { UserDefaults.standard.set(showInspector, forKey: "showInspector") }
    }

    /// Toggle sort on a column: same column flips direction, new column
    /// starts with its natural order (names ascending, sizes descending).
    func toggleSort(_ field: SDSortField) {
        if sortField == field {
            sortAscending.toggle()
        } else {
            sortField = field
            sortAscending = field == .name
        }
    }

    func sorted(_ nodes: [ScanNode]) -> [ScanNode] {
        nodes.sorted { a, b in
            let order: ComparisonResult
            switch sortField {
            case .name:
                order = a.name.localizedStandardCompare(b.name)
            case .size:
                let x = bytes(a), y = bytes(b)
                order = x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame
            case .modified:
                let x = a.modified ?? .distantPast, y = b.modified ?? .distantPast
                order = x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame
            }
            // Ties break by name, then id, so the order is strict and stable.
            if order == .orderedSame {
                let byName = a.name.localizedStandardCompare(b.name)
                return byName == .orderedSame ? a.id < b.id : byName == .orderedAscending
            }
            return sortAscending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    /// Human path: the location's name followed by the path inside it,
    /// so rows read "Home › Library › Caches" instead of a long absolute path.
    func displayPath(_ node: ScanNode) -> String {
        guard let loc = locations
            .filter({ node.path == $0.id || CleanupService.isWithin(node.path, root: $0.id) })
            .max(by: { $0.id.count < $1.id.count }) else { return node.path }
        let rel = node.path.dropFirst(loc.id.count).split(separator: "/").map(String.init)
        return ([loc.name] + rel.dropLast()).joined(separator: " › ")
    }

    /// Every retained node inside a location whose name matches, for search
    /// across the whole retained tree rather than the top level only.
    func searchNodes(in locationID: String, matching text: String) -> [ScanNode] {
        let prefix = locationID
        let matches = nodeIndex.values.filter { n in
            (n.id.hasPrefix(prefix + "/") || n.id.hasPrefix(prefix + "#"))
                && n.name.localizedCaseInsensitiveContains(text)
        }
        return Self.onePerPath(matches)
    }

    /// The same file can be retained twice: as a tree node and as a ranking
    /// candidate under another id. Keep one per path, preferring the tree
    /// node, so results and their totals count each file once.
    nonisolated static func onePerPath(_ nodes: [ScanNode]) -> [ScanNode] {
        var byPath: [String: ScanNode] = [:]
        for n in nodes {
            let p = CleanupService.standardized(n.path)
            if let existing = byPath[p] {
                if existing.id.contains("#") && !n.id.contains("#") { byPath[p] = n }
            } else {
                byPath[p] = n
            }
        }
        return Array(byPath.values)
    }
    var breadcrumb: [ScanNode] = []
    /// Map drill-down trail (root = current list). Empty means top level.
    var mapTrail: [ScanNode] = []

    var activeLocationID = "home"

    // MARK: - Real scan state (mock dataset remains for previews / empty states)
    var locations: [SDLocation] = []
    var scans: [String: ScanResult] = [:]
    /// The scan before the current one, per location, for comparison.
    var previousScans: [String: ScanResult] = [:]
    var showChanges = false

    func changes(for locationID: String) -> ScanDiff? {
        guard let cur = scans[locationID], let prev = previousScans[locationID] else { return nil }
        return ScanDiff.between(previous: prev, current: cur)
    }
    var scanningLocationID: String?
    var scanProgress: ScanProgress?
    /// Every retained node by id, rebuilt when scans change, so lookups from
    /// list rows, map cells and the inspector are O(1) instead of a tree walk.
    var nodeIndex: [String: ScanNode] = [:]
    var scanError: String?
    var notice: String?
    var scanTask: Task<Void, Never>?
    /// Locations waiting to be scanned after the current one.
    var scanQueue: [String] = []
    /// Monotonic run id: stale workers/progress never touch current state (P1).
    var scanGeneration = 0
    /// Focused drill-down scans: parent node id -> that folder's contents.
    /// Bounded by user navigation (one aggregate per drilled folder), cleared
    /// whenever the parent location is rescanned or forgotten.
    var focusedScans: [String: ScanResult] = [:]
    var drillScanningID: String?
    var drillProgress: ScanProgress?
    var drillTask: Task<Void, Never>?
    var drillGeneration = 0
    var expandedIDs: Set<String> = []
    /// Related-data lookups for app bundles, keyed "related#<app node id>".
    var relatedScanningID: String?
    var relatedTask: Task<Void, Never>?
    var relatedEvidence: [String: [String: String]] = [:]

    // MARK: - Cleanup execution state (§F10)
    var cleanupRunning = false
    var cleanupCurrent: String?
    var cleanupResults: [CleanupResult] = []
    var cleanupTask: Task<Void, Never>?
    var lastCleanupSummary: String?
    /// Items awaiting confirmation for a direct move to the Trash.
    var directTrashItems: [ReviewItem] = []

    // MARK: - Duplicate detection state (§F07, on demand only)
    var duplicateGroups: [DuplicateGroup] = []
    var duplicateSkips: [DuplicateSkip] = []
    var duplicateKeepers: [String: String] = [:]
    var duplicateRunning = false
    var duplicateChecked = 0
    var duplicateTotal = 0
    var duplicateCurrent: String?
    var duplicateBytesDone: Int64 = 0
    var duplicateBytesTotal: Int64 = 0
    var duplicateTask: Task<Void, Never>?
    var duplicateNotice: String?

    var hasRealData: Bool { !locations.isEmpty }
    var activeScan: ScanResult? { scans[activeLocationID] }
    var activeNodes: [ScanNode] { activeScan?.topNodes ?? [] }
    var isScanning: Bool { scanningLocationID != nil }

    var activeLocation: SDLocation? { locations.first(where: { $0.id == activeLocationID }) }

    var inspectedNode: ScanNode? {
        guard let id = inspectedNodeID else { return nil }
        if let found = nodeIndex[id] { return found }
        if let queued = reviewItems.first(where: { $0.node.id == id }) { return queued.node }
        if let partial = scanProgress?.partialTop.first(where: { $0.id == id }) { return partial }
        guard !hasRealData else { return nil }
        func find(_ nodes: [ScanNode]) -> ScanNode? {
            for node in nodes {
                if node.id == id { return node }
                if let found = find(node.children ?? []) { return found }
            }
            return nil
        }
        return find(MockData.topLevel + MockData.largeFiles)
    }

    /// Rebuild the id index from every retained scan. Called whenever
    /// `scans` or `focusedScans` change.
    func rebuildIndex() {
        var index: [String: ScanNode] = [:]
        func add(_ nodes: [ScanNode]) {
            for n in nodes {
                index[n.id] = n
                if let kids = n.children { add(kids) }
            }
        }
        for scan in scans.values {
            add(scan.topNodes); add(scan.largestFiles); add(scan.oldestFiles)
        }
        for scan in focusedScans.values { add(scan.topNodes) }
        nodeIndex = index
    }

    var searchPrompt: String {
        switch selection {
        case .location: return "Search in \(activeLocation?.name ?? "location")"
        case .largeFiles, .olderFiles, .fileTypes, .duplicates: return "Search scanned files"
        default: return "Search"
        }
    }

    /// Why an item cannot be staged, or nil when it can.
    /// Bundle paths of running applications, refreshed on demand.
    func isRunningApp(_ node: ScanNode) -> Bool {
        guard node.isPackage, node.name.hasSuffix(".app") else { return false }
        let path = URL(fileURLWithPath: node.path).standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.standardizedFileURL.path == path }
    }

    func reviewBlocker(_ node: ScanNode) -> String? {
        if node.isCloudPlaceholder { return "Not downloaded. Manage it in Finder." }
        if isRunningApp(node) { return "This app is running. Quit it before moving it." }
        if node.ownedByOthers { return "Owned by another user or the system. Finder can move it with an administrator password." }
        if node.isUnreadable { return "Could not be read." }
        return nil
    }

    func canReview(_ node: ScanNode) -> Bool {
        guard hasRealData, reviewBlocker(node) == nil, !cleanupRunning else { return false }
        guard let known = nodeIndex[node.id] else { return false }
        return known.path == node.path
    }

    /// Take an item out of the queue by its queue identity alone. Losing the
    /// ability to move a file never blocks withdrawing it from the plan.
    func removeFromReview(id: String) {
        reviewItems.removeAll { $0.id == id || $0.node.id == id }
    }

    func toggleReview(_ node: ScanNode, source: String) {
        if let i = reviewItems.firstIndex(where: { $0.node.id == node.id }) {
            reviewItems.remove(at: i)
        } else {
            guard canReview(node) else { return }
            reviewItems.append(ReviewItem(
                id: node.id,
                node: node,
                source: source,
                reason: source,
                risk: node.isFolder ? "Folder. Review all contents before removal."
                    : node.hardLinkCount > 1 ? "One of \(node.hardLinkCount) hard links. The others keep the contents."
                    : "File. Moves to Trash on confirm.",
                verifiedAt: verificationTime(for: node)
            ))
        }
    }

    /// The start of the earliest scan whose figures could be on screen for
    /// a node. A walk is not atomic, so anything modified after the scan
    /// began may have been measured stale; the descendant check treats it
    /// as changed. Falls back to now for items that were never scanned.
    func verificationTime(for node: ScanNode) -> Date {
        let covering = (Array(scans.values) + Array(focusedScans.values)).filter { r in
            let root = r.locationID.split(separator: "#").last.map(String.init) ?? r.locationID
            return node.path == root || CleanupService.isWithin(node.path, root: root)
        }
        return covering.map(\.startedAt).min() ?? Date()
    }

    func isQueued(_ id: String) -> Bool {
        reviewItems.contains(where: { $0.node.id == id })
    }

    /// The single normalized plan (overlap counted once) that drives the
    /// Review header, confirmation sheet, execution, and results (P2).
    var reviewPlan: [ReviewItem] { CleanupService.normalize(reviewItems) }
    var reviewPlanBytes: Int64 { reviewPlan.reduce(0) { $0 + $1.node.logicalBytes } }
}

// MARK: - Formatting

nonisolated enum SDFormat {
    static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB, .useKB, .useBytes]
        f.countStyle = .file
        f.includesUnit = true
        return f
    }()

    static func bytesString(_ v: Int64) -> String { bytes.string(fromByteCount: v) }

    static func exactBytes(_ v: Int64) -> String {
        let n = NSNumber(value: v)
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return "\(f.string(from: n) ?? "\(v)") bytes"
    }

    static func pct(_ fraction: Double) -> String {
        String(format: "%.1f%%", fraction * 100)
    }

    /// Dates before 1980 are placeholders left by archives and copies, never
    /// a real modification, so they read as unknown wherever they appear.
    static let earliestRealDate = Date(timeIntervalSince1970: 315_532_800) // 1980-01-01

    static func date(_ d: Date?) -> String {
        guard let d, d >= earliestRealDate else { return "Unknown date" }
        return d.formatted(date: .abbreviated, time: .omitted)
    }
}

// MARK: - Mock data (seeded UI dataset, never personal data)

enum MockData {
    static let now = Date()

    static func daysAgo(_ n: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -n, to: now)!
    }

    static let locations: [SDLocation] = [
        SDLocation(id: "home", name: "Home folder", symbol: "house.fill", isExternal: false,
                   access: .available, capacityBytes: 1_000_000_000_000, availableBytes: 214_000_000_000,
                   scannedBytes: 118_400_000_000, scannedAt: now.addingTimeInterval(-120), issues: 3),
        SDLocation(id: "ssd", name: "Project SSD", symbol: "externaldrive.fill", isExternal: true,
                   access: .available, capacityBytes: 2_000_000_000_000, availableBytes: 412_000_000_000,
                   scannedBytes: 1_588_000_000_000, scannedAt: now.addingTimeInterval(-3600 * 26), issues: 0),
        SDLocation(id: "share", name: "Team Share", symbol: "network", isExternal: true,
                   access: .reconnectRequired, capacityBytes: 4_000_000_000_000, availableBytes: 1_100_000_000_000,
                   scannedBytes: 0, scannedAt: now.addingTimeInterval(-3600 * 72), issues: 1),
    ]

    static let homeTree: ScanNode = {
        func f(_ id: String, _ name: String, _ gb: Double, _ cat: SDFileCategory, _ days: Int?, _ count: Int, _ kids: [ScanNode]? = nil) -> ScanNode {
            ScanNode(id: id, name: name, path: "/Users/demo/\(name)", isFolder: kids != nil || count > 1,
                     category: cat, logicalBytes: Int64(gb * 1_000_000_000),
                     modified: days.map { daysAgo($0) }, childCount: count, children: kids)
        }
        let movies = ScanNode(id: "movies", name: "Movies", path: "/Users/demo/Movies", isFolder: true,
                              category: .media, logicalBytes: 42_800_000_000, modified: daysAgo(210),
                              childCount: 18, children: [
            f("m1", "Edit_2025_Final.mp4", 8.2, .media, 210, 1),
            f("m2", "Drone_Broll.mov", 6.1, .media, 320, 1),
            f("m3", "Archive_2024", 18.4, .media, 400, 42),
            f("m4", "Renders", 10.1, .media, 35, 26),
        ])
        let dev = ScanNode(id: "dev", name: "Developer", path: "/Users/demo/Developer", isFolder: true,
                           category: .developer, logicalBytes: 28_600_000_000, modified: daysAgo(12),
                           childCount: 3120, children: [
            f("d1", "XcodeDerivedData", 9.4, .developer, 12, 840),
            f("d2", "node_modules", 6.8, .developer, 40, 1204),
            f("d3", "Simulators", 7.2, .developer, 90, 310),
            f("d4", "build", 5.2, .developer, 12, 96),
        ])
        let docs = ScanNode(id: "docs", name: "Documents", path: "/Users/demo/Documents", isFolder: true,
                            category: .documents, logicalBytes: 18_200_000_000, modified: daysAgo(4),
                            childCount: 486, children: [
            f("o1", "Archive.zip", 8.2, .archives, 540, 1),
            f("o2", "DesignExports", 4.6, .documents, 60, 88),
            f("o3", "Contracts", 2.1, .documents, 300, 34),
            f("o4", "Notes", 3.3, .documents, 4, 120),
        ])
        let downloads = ScanNode(id: "dl", name: "Downloads", path: "/Users/demo/Downloads", isFolder: true,
                                 category: .archives, logicalBytes: 12_400_000_000, modified: daysAgo(2),
                                 childCount: 64, children: [
            f("w1", "Xcode_16.dmg", 7.1, .archives, 180, 1),
            f("w2", "Installer.pkg", 2.4, .archives, 380, 1),
            f("w3", "Fonts.zip", 1.1, .archives, 95, 1),
            f("w4", "Misc", 1.8, .other, 2, 61),
        ])
        let lib = ScanNode(id: "lib", name: "Library", path: "/Users/demo/Library", isFolder: true,
                           category: .system, logicalBytes: 16_400_000_000, modified: daysAgo(6),
                           childCount: 2400, children: [
            f("l1", "Caches", 6.2, .system, 6, 900),
            f("l2", "Application Support", 7.8, .system, 6, 1100),
            f("l3", "Logs", 2.4, .system, 6, 400),
        ])
        return ScanNode(id: "home", name: "Home folder", path: "/Users/demo", isFolder: true,
                        category: .other, logicalBytes: 118_400_000_000, modified: now,
                        childCount: 5, children: [movies, dev, docs, downloads, lib])
    }()

    static var topLevel: [ScanNode] { homeTree.children ?? [] }

    static var largeFiles: [ScanNode] {
        [
            ScanNode(id: "m1", name: "Edit_2025_Final.mp4", path: "/Users/demo/Movies/Edit_2025_Final.mp4", isFolder: false, category: .media, logicalBytes: 8_200_000_000, modified: daysAgo(210), childCount: 0),
            ScanNode(id: "o1", name: "Archive.zip", path: "/Users/demo/Documents/Archive.zip", isFolder: false, category: .archives, logicalBytes: 8_200_000_000, modified: daysAgo(540), childCount: 0),
            ScanNode(id: "w1", name: "Xcode_16.dmg", path: "/Users/demo/Downloads/Xcode_16.dmg", isFolder: false, category: .archives, logicalBytes: 7_100_000_000, modified: daysAgo(180), childCount: 0),
            ScanNode(id: "m2", name: "Drone_Broll.mov", path: "/Users/demo/Movies/Drone_Broll.mov", isFolder: false, category: .media, logicalBytes: 6_100_000_000, modified: daysAgo(320), childCount: 0),
            ScanNode(id: "d1a", name: "DerivedData-Stale", path: "/Users/demo/Developer/XcodeDerivedData/Stale", isFolder: true, category: .developer, logicalBytes: 5_400_000_000, modified: daysAgo(200), childCount: 212),
            ScanNode(id: "v1", name: "VM-Ubuntu.raw", path: "/Users/demo/VMs/Ubuntu.raw", isFolder: false, category: .other, logicalBytes: 4_900_000_000, modified: daysAgo(410), childCount: 0),
        ].sorted { $0.logicalBytes > $1.logicalBytes }
    }

    static var olderFiles: [ScanNode] { largeFiles.sorted { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) } }
}
