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
        if let scan { return app.sizeBasis == .onDisk && scan.totalAllocated > 0 ? scan.totalAllocated : scan.totalBytes }
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
                ? "\(SDFormat.bytesString(scan.totalAllocated)) on disk, " : ""
            return "\(disk)scanned \(when)"
        }
        if scanningHere, let p = app.scanProgress {
            return "Scanning, \(p.itemsFound.formatted()) items so far"
        }
        return app.hasRealData ? "Not scanned yet" : "Sample data"
    }

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            if scan != nil || scanningHere || !app.hasRealData {
                ScreenBar {
                    Text(statusLine)
                        .lineLimit(1).truncationMode(.tail)
                        .help("Sizes are logical file sizes. On-disk allocation is shown alongside where it differs.")
                    if let scan, app.hasRealData, !scan.issues.isEmpty {
                        Button {
                            app.showScanIssues = true
                        } label: {
                            Label("\(scan.issues.count) unreadable", systemImage: "exclamationmark.triangle.fill")
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain).foregroundStyle(.orange)
                        .help("Some folders could not be read")
                    }
                    if let diff = app.changes(for: locationID), !searching {
                        Button {
                            app.showChanges = true
                        } label: {
                            let delta = diff.bytesDelta == 0 ? "No change"
                                : "\(diff.bytesDelta > 0 ? "+" : "−")\(SDFormat.bytesString(abs(diff.bytesDelta)))"
                            let symbol = diff.bytesDelta > 0 ? "arrow.up.right" : diff.bytesDelta < 0 ? "arrow.down.right" : "equal"
                            // Full wording when there is room, the figure alone when the bar is narrow.
                            ViewThatFits(in: .horizontal) {
                                Label("\(delta) since last scan", systemImage: symbol).lineLimit(1)
                                Label(delta, systemImage: symbol).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                        .help("What changed since the previous scan")
                        .sheet(isPresented: $app.showChanges) {
                            ChangesView(locationName: location?.name ?? "", diff: diff)
                        }
                    }
                    if searching {
                        Text("\(nodes.count) matching, \(SDFormat.bytesString(nodes.reduce(0) { $0 + app.bytes($1) }))")
                            .lineLimit(1)
                    }
                } trailing: {
                    if app.viewMode != .list && !searching {
                        Menu {
                            Picker("Color", selection: $app.mapColor) {
                                ForEach(SDMapColor.allCases, id: \.self) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.inline)
                        } label: {
                            Text(app.mapColor.label)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("What the colors mean")
                    }
                    Menu {
                        Picker("Size Basis", selection: $app.sizeBasis) {
                            Text("Logical Size").tag(SDSizeBasis.logical)
                            Text("Size on Disk").tag(SDSizeBasis.onDisk)
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Text(app.sizeBasis == .logical ? "Logical" : "On Disk")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Which size the list, map and totals show")
                    SearchField(text: $app.searchText, prompt: "Search \(location?.name ?? "")")
                }
            }

            if scan == nil && !scanningHere && app.hasRealData {
                notScanned
            } else if nodes.isEmpty && !scanningHere {
                VStack(spacing: 8) {
                    Text(searching ? "No items match \"\(app.searchText)\"." : "This folder is empty.")
                        .font(SDTheme.Font.body).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if app.viewMode == .list || searching {
                FileListView(nodes: nodes, total: total, flat: searching)
            } else if app.viewMode == .sunburst {
                SunburstView(nodes: nodes)
            } else {
                TreemapView(nodes: nodes)
            }
        }
    }

    /// The one clear call to action for a location that has never been read.
    private var notScanned: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder").font(.system(size: 44, weight: .light)).foregroundStyle(.tertiary)
            VStack(spacing: 4) {
                Text(location?.name ?? "This folder").font(.system(size: 20, weight: .semibold))
                Text(location?.id ?? "").font(SDTheme.Font.secondary).foregroundStyle(.secondary)
            }
            Button("Scan \(location?.name ?? "Folder")") { app.rescanActive() }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut(.defaultAction)
            if let l = location, !l.access.isOK {
                Text(l.access.label).font(SDTheme.Font.secondary).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                get: { app.selectedIDs },
                set: { app.selectedIDs = $0 }
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
                    Text(app.displayPath(node)).font(.system(size: 11)).foregroundStyle(.secondary)
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
            if app.hasDiskHint(node) {
                Text("\(SDFormat.bytesString(node.allocatedBytes ?? 0)) on disk")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .help("Sparse, cloned or not downloaded: occupies less than its size")
            }
            Text(SDFormat.date(node.modified))
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 96, alignment: .trailing)
            MonospaceBytes(bytes: app.bytes(node)).frame(width: 96, alignment: .trailing)
            SizeBar(fraction: Double(app.bytes(node)) / Double(max(total, 1)), category: node.category).frame(width: 64)
        }
        .frame(height: showPath ? SDTheme.rowHeight + 6 : SDTheme.rowHeight)
        .contentShape(Rectangle())
        .contextMenu { NodeContextMenu(node: node, source: "Browse") }
    }
}
