import AppKit
import SwiftUI

struct BrowseView: View {
    @Environment(AppState.self) private var app
    let locationID: String

    private var scan: ScanResult? { app.scans[locationID] }
    private var location: SDLocation? { app.locations.first(where: { $0.id == locationID }) }
    private var scanningHere: Bool { app.isScanning && app.scanningLocationID == locationID }
    private var searching: Bool { !app.searchText.isEmpty }

    private var all: [ScanNode] { app.hasRealData ? app.visibleTopNodes(for: locationID) : MockData.topLevel }
    private var total: Int64 {
        guard app.hasRealData else { return MockData.homeTree.logicalBytes }
        if let scan { return scan.totalBytes }
        return scanningHere ? (app.scanProgress?.partialBytes ?? 0) : 0
    }

    /// Top-level rows, or every retained node whose name matches the search.
    private var nodes: [ScanNode] {
        guard searching else { return all }
        if app.hasRealData {
            return app.searchNodes(in: locationID, matching: app.searchText)
        }
        return all.filter { $0.name.localizedCaseInsensitiveContains(app.searchText) }
    }

    private var statusLine: String {
        if let scan, app.hasRealData {
            let when = scan.finishedAt.formatted(.relative(presentation: .named))
            let disk = scan.totalAllocated > 0 && scan.totalAllocated < scan.totalBytes * 9 / 10
                ? ", \(SDFormat.bytesString(scan.totalAllocated)) on disk" : ""
            return "\(SDFormat.bytesString(scan.totalBytes)) in \(scan.itemCount.formatted()) items\(disk), scanned \(when)"
        }
        if scanningHere, let p = app.scanProgress {
            return "Scanning, \(p.itemsFound.formatted()) items so far"
        }
        return app.hasRealData ? "Not scanned yet" : "Sample data"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(statusLine).font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                    .help("Sizes are logical file sizes. On-disk allocation is shown in the inspector.")
                if let scan, app.hasRealData, !scan.issues.isEmpty {
                    Button("\(scan.issues.count) unreadable", systemImage: "exclamationmark.triangle.fill") {
                        app.showScanIssues = true
                    }
                    .buttonStyle(.plain).font(SDTheme.Font.secondary).foregroundStyle(.orange)
                    .help("Some folders could not be read")
                }
                Spacer()
                if searching {
                    Text("\(nodes.count) matching \(SDFormat.bytesString(nodes.reduce(0) { $0 + $1.logicalBytes }))")
                        .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                }
                if scanningHere {
                    Button("Cancel") { app.cancelScan() }.controlSize(.small)
                } else if app.hasRealData {
                    Button("Rescan") { app.rescanActive() }.controlSize(.small)
                        .disabled(location?.access.isOK == false && scan == nil)
                }
            }
            .padding(.horizontal, SDTheme.Space.md)
            .padding(.vertical, SDTheme.Space.xs)

            Divider()

            if nodes.isEmpty && !scanningHere {
                VStack(spacing: 8) {
                    Text(searching ? "No items match \"\(app.searchText)\"." : "Nothing scanned yet.").font(SDTheme.Font.body)
                    if !searching {
                        Button(app.hasRealData ? "Scan Now" : "Add Location…") {
                            if app.hasRealData { app.rescanActive() } else { Task { await app.addLocationFlow() } }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if app.viewMode == .list || searching {
                FileListView(nodes: nodes, total: total, flat: searching)
            } else {
                TreemapView(nodes: nodes)
            }
        }
    }
}

// Hierarchical sortable list (§F04). Folders expand on demand: retained
// children show at once; deeper levels are read under the existing grant
// when expanded (focused scans, §F02). Search shows a flat result list.
struct FileListView: View {
    @Environment(AppState.self) private var app
    let nodes: [ScanNode]
    let total: Int64
    var flat = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List(selection: Binding(
                get: { app.inspectedNodeID },
                set: { app.inspectedNodeID = $0 }
            )) {
                ForEach(app.sorted(nodes)) { node in
                    if flat {
                        FileRow(node: node, total: total, showPath: true).tag(node.id)
                    } else {
                        FolderRows(node: node, total: total, depth: 0)
                    }
                }
            }
            .listStyle(.inset)
            .onKeyPress(.space) {
                guard let sel = app.inspectedNode, !sel.isCloudPlaceholder else { return .ignored }
                return app.preview(sel) == nil ? .handled : .ignored
            }
            .onKeyPress(.return) {
                guard let sel = app.inspectedNode, sel.isFolder, !sel.isPackage else { return .ignored }
                if app.expandedIDs.contains(sel.id) { app.expandedIDs.remove(sel.id) } else {
                    app.expandedIDs.insert(sel.id); app.ensureChildren(sel)
                }
                return .handled
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            sortButton("Name", .name).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, flat ? 16 : 36)
            sortButton("Modified", .modified).frame(width: 96, alignment: .trailing)
            sortButton("Size", .size).frame(width: 96, alignment: .trailing)
            Spacer().frame(width: 64)
        }
        .frame(height: 24)
        .padding(.horizontal, SDTheme.Space.md)
        .font(SDTheme.Font.secondary)
    }

    private func sortButton(_ title: String, _ field: SDSortField) -> some View {
        Button {
            app.toggleSort(field)
        } label: {
            HStack(spacing: 3) {
                Text(title).foregroundStyle(app.sortField == field ? .primary : .secondary)
                if app.sortField == field {
                    Image(systemName: app.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .help("Sort by \(title.lowercased())")
    }
}

private struct FolderRows: View {
    @Environment(AppState.self) private var app
    let node: ScanNode
    let total: Int64
    let depth: Int

    private var retained: [ScanNode]? { app.children(of: node) }
    private var drilling: Bool { app.drillScanningID == node.id }
    private var drillable: Bool {
        node.isFolder && !node.isPackage && !node.isCloudPlaceholder && app.scopeForNode(node) != nil
    }

    var body: some View {
        if node.isFolder && !node.isPackage && (retained != nil || drillable) {
            DisclosureGroup(isExpanded: expanded) {
                if let kids = retained {
                    ForEach(app.sorted(kids)) { kid in
                        if depth + 1 < 8 {
                            FolderRows(node: kid, total: total, depth: depth + 1)
                        } else {
                            FileRow(node: kid, total: total).tag(kid.id)
                        }
                    }
                } else if drilling {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        if let p = app.drillProgress {
                            Text("Reading, \(p.itemsFound.formatted()) items")
                                .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Cancel") { app.cancelDrill() }
                            .buttonStyle(.link).font(SDTheme.Font.secondary)
                    }
                    .frame(height: SDTheme.rowHeight)
                } else {
                    Button("Read Contents") { app.ensureChildren(node) }
                        .buttonStyle(.link).font(SDTheme.Font.secondary)
                        .frame(height: SDTheme.rowHeight)
                }
            } label: {
                FileRow(node: node, total: total).tag(node.id)
            }
        } else {
            FileRow(node: node, total: total).tag(node.id)
        }
    }

    private var expanded: Binding<Bool> {
        Binding(
            get: { app.expandedIDs.contains(node.id) },
            set: { open in
                if open {
                    app.expandedIDs.insert(node.id)
                    app.ensureChildren(node)
                } else {
                    app.expandedIDs.remove(node.id)
                }
            }
        )
    }
}

struct FileRow: View {
    @Environment(AppState.self) private var app
    let node: ScanNode
    let total: Int64
    var showPath = false

    var body: some View {
        HStack(spacing: 8) {
            FileTypeIcon(node: node, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name).font(SDTheme.Font.body).lineLimit(1)
                if showPath {
                    Text(node.path).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if node.isCloudPlaceholder {
                Image(systemName: "icloud").foregroundStyle(.secondary).help("Not downloaded")
            }
            if app.isQueued(node.id) {
                Image(systemName: "tray.full").foregroundStyle(Color.accentColor).help("In Review")
            }
            Text(SDFormat.date(node.modified))
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 96, alignment: .trailing)
            MonospaceBytes(bytes: node.logicalBytes).frame(width: 96, alignment: .trailing)
            SizeBar(fraction: node.share(of: total), category: node.category).frame(width: 64)
        }
        .frame(height: showPath ? SDTheme.rowHeight + 6 : SDTheme.rowHeight)
        .contentShape(Rectangle())
        .contextMenu { NodeContextMenu(node: node, source: "Browse") }
    }
}
