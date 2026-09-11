import Foundation
import SwiftUI

// MARK: - Categories (mutually exclusive for totals, §F04)

enum SDFileCategory: String, CaseIterable, Identifiable, Hashable, Codable {
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

struct ScanNode: Identifiable, Hashable, Codable {
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
    /// of many frees no unique storage — review copy says so.
    var hardLinkCount: Int = 1

    var isUnknownDate: Bool { modified == nil }

    func share(of total: Int64) -> Double {
        guard total > 0 else { return 0 }
        return Double(logicalBytes) / Double(total)
    }
}

// MARK: - Locations

struct SDLocation: Identifiable, Hashable {
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
    var scannedBytes: Int64
    var scannedAt: Date
    var issues: Int
}

// MARK: - Review

struct ReviewItem: Identifiable, Hashable {
    let id: String
    var node: ScanNode
    var source: String
    var reason: String
    var risk: String
}

// MARK: - App state

enum SDSidebarSelection: Hashable {
    case overview
    case location(String)
    case largeFiles
    case olderFiles
    case duplicates
    case review
}

enum SDViewMode: String, CaseIterable {
    case list = "List"
    case map = "Map"
}

enum SDSortField: String, CaseIterable {
    case name, size, modified
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
    var searchText = ""
    var inspectedNodeID: String? {
        didSet { if inspectedNodeID != nil { showInspector = true } }
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
            let less: Bool
            switch sortField {
            case .name: less = a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .size: less = a.logicalBytes < b.logicalBytes
            case .modified: less = (a.modified ?? .distantPast) < (b.modified ?? .distantPast)
            }
            return sortAscending ? less : !less
        }
    }

    /// Every retained node inside a location whose name matches, for search
    /// across the whole retained tree rather than the top level only.
    func searchNodes(in locationID: String, matching text: String) -> [ScanNode] {
        let prefix = locationID
        return nodeIndex.values.filter { n in
            (n.id.hasPrefix(prefix + "/") || n.id.hasPrefix(prefix + "#"))
                && n.name.localizedCaseInsensitiveContains(text)
        }
    }
    var breadcrumb: [ScanNode] = []
    /// Map drill-down trail (root = current list). Empty means top level.
    var mapTrail: [ScanNode] = []

    var activeLocationID = "home"

    // MARK: - Real scan state (mock dataset remains for previews / empty states)
    var locations: [SDLocation] = []
    var scans: [String: ScanResult] = [:]
    var scanningLocationID: String?
    var scanProgress: ScanProgress?
    /// Every retained node by id, rebuilt when scans change, so lookups from
    /// list rows, map cells and the inspector are O(1) instead of a tree walk.
    var nodeIndex: [String: ScanNode] = [:]
    var scanError: String?
    var notice: String?
    var scanTask: Task<Void, Never>?
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

    // MARK: - Cleanup execution state (§F10)
    var cleanupRunning = false
    var cleanupCurrent: String?
    var cleanupResults: [CleanupResult] = []
    var cleanupTask: Task<Void, Never>?
    var lastCleanupSummary: String?

    // MARK: - Duplicate detection state (§F07, on demand only)
    var duplicateGroups: [DuplicateGroup] = []
    var duplicateSkips: [DuplicateSkip] = []
    var duplicateKeepers: [String: String] = [:]
    var duplicateRunning = false
    var duplicateChecked = 0
    var duplicateTotal = 0
    var duplicateCurrent: String?
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
        case .largeFiles, .olderFiles, .duplicates: return "Search scanned files"
        default: return "Search"
        }
    }

    func canReview(_ node: ScanNode) -> Bool {
        guard hasRealData, !node.isCloudPlaceholder, !node.isUnreadable, !cleanupRunning else { return false }
        guard let known = nodeIndex[node.id] else { return false }
        return known.path == node.path
    }

    func toggleReview(_ node: ScanNode, source: String) {
        guard canReview(node) else { return }
        if let i = reviewItems.firstIndex(where: { $0.node.id == node.id }) {
            reviewItems.remove(at: i)
        } else {
            reviewItems.append(ReviewItem(
                id: node.id,
                node: node,
                source: source,
                reason: source,
                risk: node.isFolder ? "Folder. Review all contents before removal."
                    : node.hardLinkCount > 1 ? "One of \(node.hardLinkCount) hard links. The others keep the contents."
                    : "File. Moves to Trash on confirm."
            ))
        }
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

enum SDFormat {
    static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB, .useKB]
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

    static func date(_ d: Date?) -> String {
        guard let d else { return "Unknown date" }
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
