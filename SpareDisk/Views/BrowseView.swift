import AppKit
import SwiftUI

struct BrowseView: View {
    @Environment(AppState.self) private var app
    let locationID: String

    private var useReal: Bool { app.hasRealData && app.scans[locationID] != nil }
    private var scan: ScanResult? { app.scans[locationID] }
    private var locName: String {
        app.locations.first(where: { $0.id == locationID })?.name ?? "Home folder"
    }
    private var scanningHere: Bool { app.isScanning && app.scanningLocationID == locationID }
    private var all: [ScanNode] { app.hasRealData ? app.visibleTopNodes(for: locationID) : MockData.topLevel }
    private var total: Int64 {
        guard app.hasRealData else { return MockData.homeTree.logicalBytes }
        if let scan { return scan.totalBytes }
        return scanningHere ? (app.scanProgress?.partialBytes ?? 0) : 0
    }

    private var nodes: [ScanNode] {
        guard !app.searchText.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(app.searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(locName).font(.system(size: 20, weight: .semibold))
                if !useReal && !app.hasRealData {
                    Text("Sample").font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                if app.isScanning && app.scanningLocationID == locationID {
                    Button("Cancel") { app.cancelScan() }.buttonStyle(.bordered).controlSize(.small)
                } else if app.hasRealData {
                    Button("Rescan") { app.rescanActive() }.buttonStyle(.bordered).controlSize(.small)
                        .keyboardShortcut("r", modifiers: .command)
                }
                Text("Size basis: Logical").font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                    .help("Chart, table, inspector and queue use the same size basis")
            }
            .padding(.horizontal, SDTheme.Space.md)
            .padding(.vertical, SDTheme.Space.sm)

            HStack(spacing: 8) {
                if let scan, useReal {
                    Text("\(SDFormat.bytesString(scan.totalBytes)) scanned · \(scan.itemCount.formatted()) items")
                        .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                } else if app.isScanning, let p = app.scanProgress {
                    Text("Scanning · \(p.itemsFound.formatted()) items found · \(Int(p.elapsed))s elapsed")
                        .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                } else {
                    Text(app.hasRealData ? "No completed scan for this location" : "Sample data · choose a folder for your files")
                        .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Showing \(SDFormat.bytesString(nodes.reduce(0) { $0 + $1.logicalBytes })) of \(SDFormat.bytesString(total)) analyzed")
                    .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
            }
            .padding(.horizontal, SDTheme.Space.md)
            .padding(.bottom, SDTheme.Space.xs)

            if let scan, useReal, !scan.issues.isEmpty {
                HStack {
                    IssueBanner(text: "Scan finished. \(scan.issues.count) folders couldn't be read.")
                }
                .padding(.horizontal, SDTheme.Space.md)
                .padding(.bottom, SDTheme.Space.xs)
            }

            Divider()

            if nodes.isEmpty && !scanningHere {
                VStack(spacing: 8) {
                    Text(app.searchText.isEmpty ? "No scanned files to show." : "No files match your search.").font(SDTheme.Font.body)
                    Button("Choose Another Folder…") { Task { await app.addLocationFlow() } }.buttonStyle(.link)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if app.viewMode == .list {
                FileListView(nodes: nodes, total: total)
            } else {
                TreemapView(nodes: nodes)
            }
        }
    }
}

// Hierarchical sortable list (§F04) — List-based for full VoiceOver + keyboard support.
// Folders expand on demand: retained children show at once; deeper levels are
// read under the existing grant when expanded (focused scans, §F02).
struct FileListView: View {
    @Environment(AppState.self) private var app
    let nodes: [ScanNode]
    let total: Int64

    private var sorted: [ScanNode] {
        nodes.sorted { $0.logicalBytes > $1.logicalBytes }
    }

    var body: some View {
        List(selection: Binding(
            get: { app.inspectedNodeID },
            set: { app.inspectedNodeID = $0 }
        )) {
            Section {
                ForEach(sorted) { node in
                    FolderRows(node: node, total: total, depth: 0)
                }
            } header: {
                HStack {
                    Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                    Spacer()
                    Text("Size").frame(width: 90, alignment: .trailing)
                    Text("Share").frame(width: 64, alignment: .leading)
                    Text("Review").frame(width: 52)
                }
                .font(SDTheme.Font.secondary)
            }
        }
        .listStyle(.inset)
        .onKeyPress(.space) {
            // Finder convention: Space previews the selection.
            guard let sel = selectedNode, !sel.isCloudPlaceholder else { return .ignored }
            return app.preview(sel) == nil ? .handled : .ignored
        }

    }

    private var selectedNode: ScanNode? {
        guard let id = app.inspectedNodeID else { return nil }
        let pool = nodes + nodes.flatMap { $0.children ?? [] }
        return pool.first(where: { $0.id == id })
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
        node.isFolder && !node.isCloudPlaceholder && app.scopeForNode(node) != nil
    }

    var body: some View {
        if node.isFolder && (retained != nil || drillable) {
            DisclosureGroup(isExpanded: expanded) {
                if let kids = retained {
                    ForEach(kids.sorted { $0.logicalBytes > $1.logicalBytes }) { kid in
                        if depth + 1 < 6 {
                            FolderRows(node: kid, total: total, depth: depth + 1)
                        } else {
                            fileRow(kid).tag(kid.id)
                        }
                    }
                } else if drilling {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        if let p = app.drillProgress {
                            Text("Reading… \(p.itemsFound.formatted()) items found")
                                .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Cancel") { app.cancelDrill() }
                            .buttonStyle(.link).font(SDTheme.Font.secondary)
                    }
                    .frame(height: SDTheme.rowHeight)
                } else {
                    Button("Read contents") { app.ensureChildren(node) }
                        .buttonStyle(.link).font(SDTheme.Font.secondary)
                        .frame(height: SDTheme.rowHeight)
                }
            } label: {
                fileRow(node).tag(node.id)
            }
        } else {
            fileRow(node).tag(node.id)
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

    private func fileRow(_ node: ScanNode) -> some View {
        HStack(spacing: 8) {
            CategoryDot(category: node.category)
            FileTypeIcon(node: node, size: 20)
            Text(node.name).font(SDTheme.Font.body).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if app.isQueued(node.id) {
                Image(systemName: "tray.full.fill").foregroundStyle(Color.accentColor).help("In Review")
            }
            Spacer()
            MonospaceBytes(bytes: node.logicalBytes).frame(width: 90, alignment: .trailing)
            SizeBar(fraction: node.share(of: total), category: node.category).frame(width: 64)
            Button(app.isQueued(node.id) ? "Queued" : "Review") {
                app.toggleReview(node, source: "Browse")
            }
            .buttonStyle(.link).font(SDTheme.Font.secondary).frame(width: 52)
            .disabled(!app.canReview(node))
        }
        .frame(height: SDTheme.rowHeight)
        .contentShape(Rectangle())
        .contextMenu {
            Button(app.isQueued(node.id) ? "Remove from Review" : "Add to Review") { app.toggleReview(node, source: "Browse") }.disabled(!app.canReview(node))
            Button("Reveal in Finder") { app.reveal(node) }.disabled(app.scopeForNode(node) == nil)
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.path, forType: .string)
            }
        }
    }
}
