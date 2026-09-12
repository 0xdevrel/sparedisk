import AppKit
import Charts
import SwiftUI

// Inspector order (§F05): name and kind, path, size, dates and counts,
// largest children for folders, actions, staging.
struct InspectorView: View {
    @Environment(AppState.self) private var app
    @State private var actionNotice: String?

    private var node: ScanNode? { app.inspectedNode }

    private func hasGrant(_ node: ScanNode) -> Bool { app.scopeForNode(node) != nil }

    var body: some View {
        ScrollView {
            if app.selectedNodes.count > 1 {
                multiple(app.selectedNodes)
            } else if let node {
                VStack(alignment: .leading, spacing: SDTheme.Space.sm) {
                    identity(node)
                    Divider()
                    size(node)
                    Divider()
                    facts(node)
                    if node.isFolder, !node.isPackage {
                        Divider()
                        children(node)
                    }
                    if node.isPackage, node.name.hasSuffix(".app") {
                        Divider()
                        related(node)
                    }
                    Divider()
                    actions(node)
                }
                .padding(SDTheme.Space.md)
            } else if app.selection == .overview, let summary = app.storageSummary {
                StorageInspector(summary: summary)
                    .padding(SDTheme.Space.md)
            } else {
                Text("No Selection").font(SDTheme.Font.body).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector")
    }

    private func multiple(_ nodes: [ScanNode]) -> some View {
        let total = nodes.reduce(0) { $0 + app.bytes($1) }
        let reviewable = nodes.filter { app.canReview($0) }
        return VStack(alignment: .leading, spacing: SDTheme.Space.sm) {
            Text("\(nodes.count) items").font(.system(size: 15, weight: .semibold))
            Text(SDFormat.bytesString(total)).font(SDTheme.Font.figureSmall)
            Text("\(nodes.filter(\.isFolder).count) folders, \(nodes.filter { !$0.isFolder }.count) files")
                .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
            Divider()
            HStack(spacing: 8) {
                Button {
                    app.addToReview(reviewable, source: "Inspector")
                } label: {
                    Label("Add \(reviewable.count) to Review", systemImage: "tray").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(reviewable.isEmpty)
                Button {
                    app.requestTrash(reviewable)
                } label: {
                    Label("Move to Trash", systemImage: "trash").frame(maxWidth: .infinity)
                }
                .disabled(reviewable.isEmpty)
            }
            .controlSize(.large)
            if reviewable.count < nodes.count {
                Text("\(nodes.count - reviewable.count) of the selected items cannot be moved by SpareDisk.")
                    .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
            }
        }
        .padding(SDTheme.Space.md)
    }

    private func identity(_ node: ScanNode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                FileTypeIcon(node: node, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name).font(.system(size: 15, weight: .semibold)).lineLimit(3)
                    HStack(spacing: 5) {
                        CategoryDot(category: node.category)
                        Text(node.isPackage ? "Package" : node.isFolder ? "Folder" : node.category.label)
                            .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                    }
                }
            }
            // Where it lives, relative to its location. The full path stays
            // one hover or Copy Path away.
            Text(app.displayPath(node)).font(.system(size: 11.5)).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle).help(node.path)
        }
    }

    private func size(_ node: ScanNode) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(SDFormat.bytesString(node.logicalBytes)).font(SDTheme.Font.figureSmall)
            Text(SDFormat.exactBytes(node.logicalBytes)).font(SDTheme.Font.secondary).foregroundStyle(.secondary)
            if let alloc = node.allocatedBytes, alloc != node.logicalBytes {
                Text("\(SDFormat.bytesString(alloc)) on disk").font(SDTheme.Font.secondary).foregroundStyle(.secondary)
            }
            if node.hardLinkCount > 1 {
                Text("One of \(node.hardLinkCount) hard links. Trashing this one frees nothing.")
                    .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
            }
        }
    }

    private func facts(_ node: ScanNode) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            GridRow {
                Text("Modified").foregroundStyle(.secondary)
                Text(node.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Unknown")
            }
            if node.isFolder {
                GridRow { Text("Contains").foregroundStyle(.secondary); Text("\(node.childCount.formatted()) items") }
            }
            if node.isCloudPlaceholder {
                GridRow { Text("Status").foregroundStyle(.secondary); Text("Not downloaded") }
            }
            if node.ownedByOthers {
                GridRow { Text("Owner").foregroundStyle(.secondary); Text("Another user or the system") }
            }
            if app.isRunningApp(node) {
                GridRow { Text("Status").foregroundStyle(.secondary); Text("Running") }
            }
            if node.isUnreadable {
                GridRow { Text("Status").foregroundStyle(.secondary); Text("Could not be read") }
            }
        }
        .font(SDTheme.Font.secondary)
    }

    private func children(_ node: ScanNode) -> some View {
        let kids = (app.children(of: node) ?? []).sorted { $0.logicalBytes > $1.logicalBytes }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Largest inside").font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                Spacer()
                if kids.isEmpty {
                    if app.drillScanningID == node.id {
                        ProgressView().controlSize(.mini)
                    } else if hasGrant(node), !node.isCloudPlaceholder {
                        Button("Read") { app.ensureChildren(node) }.buttonStyle(.link).font(SDTheme.Font.secondary)
                    }
                }
            }
            ForEach(kids.prefix(10)) { kid in
                Button {
                    app.inspectedNodeID = kid.id
                } label: {
                    HStack(spacing: 6) {
                        FileTypeIcon(node: kid, size: 14)
                        Text(kid.name).font(SDTheme.Font.secondary).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(SDFormat.bytesString(kid.logicalBytes))
                            .font(SDTheme.Font.secondary.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if kids.count > 10 {
                Button("Show all \(kids.count)") {
                    app.viewMode = .list
                    app.expandedIDs.insert(node.id)
                    if case .location = app.selection {} else if let id = app.activeLocation?.id {
                        app.selection = .location(id)
                    }
                }
                .buttonStyle(.link).font(SDTheme.Font.secondary)
            }
        }
    }

    private func related(_ node: ScanNode) -> some View {
        let found = app.relatedData(for: node)
        let evidence = app.relatedEvidence["related#\(node.id)"] ?? [:]
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Related data").font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                Spacer()
                if app.relatedScanningID == node.id {
                    ProgressView().controlSize(.mini)
                } else if found == nil {
                    if app.homeLocation == nil {
                        Text("Add your home folder to look").font(SDTheme.Font.secondary).foregroundStyle(.tertiary)
                    } else {
                        Button("Find") { app.findRelatedData(for: node) }.buttonStyle(.link).font(SDTheme.Font.secondary)
                    }
                }
            }
            if let found {
                if found.isEmpty {
                    Text("Nothing found under your Library for this app.")
                        .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                } else {
                    ForEach(found) { item in
                        Button {
                            app.inspectedNodeID = item.id
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    FileTypeIcon(node: item, size: 14)
                                    Text(item.name).font(SDTheme.Font.secondary).lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if app.isQueued(item.id) {
                                        Image(systemName: "tray.full").font(.system(size: 10)).foregroundStyle(Color.accentColor)
                                    }
                                    Text(SDFormat.bytesString(item.logicalBytes))
                                        .font(SDTheme.Font.secondary.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                if let e = evidence[item.path] {
                                    Text(e).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                                        .padding(.leading, 20)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu { NodeContextMenu(node: item, source: "Related data") }
                    }
                    Text("Total \(SDFormat.bytesString(found.reduce(0) { $0 + $1.logicalBytes })). Matches by identifier are reliable; matches by name may belong to something else.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func actions(_ node: ScanNode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    app.toggleReview(node, source: "Inspector")
                } label: {
                    Label(app.isQueued(node.id) ? "Remove" : "Add to Review", systemImage: "tray").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!app.canReview(node))
                Button {
                    app.requestTrash(node)
                } label: {
                    Label("Move to Trash", systemImage: "trash").frame(maxWidth: .infinity)
                }
                .disabled(!app.canReview(node))
                .help("Checked again, then moved to the Trash (⌘⌫)")
            }
            .controlSize(.large)
            HStack(spacing: 8) {
                Button { actionNotice = app.preview(node) } label: {
                    Label("Quick Look", systemImage: "eye").frame(maxWidth: .infinity)
                }
                .disabled(!hasGrant(node) || node.isCloudPlaceholder)
                Button { actionNotice = app.reveal(node) } label: {
                    Label("Finder", systemImage: "folder").frame(maxWidth: .infinity)
                }
                .disabled(!hasGrant(node))
            }
            .controlSize(.large)
            if node.isPackage, node.name.hasSuffix(".app") {
                Button {
                    app.prepareUninstall(node)
                } label: {
                    HStack {
                        if app.uninstallPreparingID == node.id { ProgressView().controlSize(.mini) }
                        Label("Uninstall…", systemImage: "app.badge.checkmark").frame(maxWidth: .infinity)
                    }
                }
                .controlSize(.large)
                .disabled(!app.canReview(node) || app.homeLocation == nil || app.uninstallPreparingID != nil)
                .help(app.homeLocation == nil ? "Add your home folder to find the app's data" : "Stage the app and its data for review")
            }
            if let m = actionNotice {
                Text(m).font(SDTheme.Font.secondary).foregroundStyle(.orange)
            }
            if let why = app.reviewBlocker(node) {
                Text(why).font(SDTheme.Font.secondary).foregroundStyle(.secondary)
            } else if !app.hasRealData {
                Text("Sample data. Add a location to work with your own files.")
                    .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
            }
        }
    }
}

/// The volume as a ring: each scanned location, everything else in use,
/// and what is still available. Shown while My Mac has no selection.
private struct StorageInspector: View {
    @Environment(AppState.self) private var app
    @Environment(\.colorScheme) private var scheme
    let summary: StorageSummary
    @State private var hoveredID: String?

    private var hoveredSlice: Slice? { slices.first { $0.id == hoveredID } }

    private struct Slice: Identifiable {
        var id: String
        var name: String
        var bytes: Int64
        var color: Color
    }

    private var slices: [Slice] {
        var out = summary.parts.map {
            Slice(id: $0.id, name: $0.name, bytes: $0.bytes, color: SDTheme.hue($0.rank, scheme: scheme))
        }
        out.append(Slice(id: "__other", name: "Other used", bytes: summary.other, color: Color.primary.opacity(0.22)))
        out.append(Slice(id: "__free", name: "Available", bytes: summary.volume.availableBytes, color: Color.primary.opacity(0.07)))
        return out.filter { $0.bytes > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SDTheme.Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.volume.volumeName ?? "Startup Disk").font(.system(size: 15, weight: .semibold))
                Text("\(SDFormat.bytesString(summary.volume.capacityBytes)) in total")
                    .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
            }
            ZStack {
                Chart(slices) { s in
                    SectorMark(angle: .value("Bytes", s.bytes), innerRadius: .ratio(0.68), angularInset: 1.2)
                        .foregroundStyle(s.color.opacity(hoveredID == nil || hoveredID == s.id ? 1 : 0.4))
                        .cornerRadius(2)
                }
                .chartLegend(.hidden)
                .overlay {
                    GeometryReader { geometry in
                        Color.clear.contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let point):
                                    let bounds = CGRect(origin: .zero, size: geometry.size)
                                    let index = StorageDonutHitTest.index(at: point, in: bounds, weights: slices.map(\.bytes))
                                    hoveredID = index.map { slices[$0].id }
                                case .ended: hoveredID = nil
                                }
                            }
                    }
                }
                VStack(spacing: 3) {
                    Text(SDFormat.bytesString(hoveredSlice?.bytes ?? summary.volume.availableBytes))
                        .font(SDTheme.Font.figureSmall)
                    Text(hoveredSlice?.name ?? "available")
                        .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                        .lineLimit(2).multilineTextAlignment(.center)
                    if let slice = hoveredSlice {
                        Text((Double(slice.bytes) / Double(max(1, summary.scale))).formatted(.percent.precision(.fractionLength(1))) + " of chart")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 130)
                .allowsHitTesting(false)
            }
            .frame(height: 210)
            .padding(.vertical, 6)
            .onChange(of: summary) { _, _ in hoveredID = nil }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(hoveredSlice.map { "\($0.name), \(SDFormat.bytesString($0.bytes))" }
                                ?? "\(SDFormat.bytesString(summary.used)) used, \(SDFormat.bytesString(summary.volume.availableBytes)) available")
            .accessibilityIdentifier("storage-donut")
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                ForEach(slices) { s in
                    GridRow {
                        Circle().fill(s.color).frame(width: 9, height: 9)
                        Text(s.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Text(SDFormat.bytesString(s.bytes)).monospacedDigit().foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                    }
                    .contentShape(Rectangle())
                    .onHover { hoveredID = $0 ? s.id : nil }
                    .background(hoveredID == s.id ? Color.primary.opacity(0.06) : .clear)
                }
            }
            .font(SDTheme.Font.secondary)
            Text(summary.overshoot > 0
                 ? "Sizes on disk. Scanned folders exceed the used figure by \(SDFormat.bytesString(summary.overshoot)); see My Mac."
                 : "Sizes on disk. Other used is everything outside the scanned folders.")
                .font(SDTheme.Font.secondary).foregroundStyle(.tertiary)
        }
    }
}

/// SectorMark starts at twelve o'clock and proceeds clockwise. Exclude
/// the hole and the area outside the ring so hover never reports a guess.
nonisolated enum StorageDonutHitTest {
    static func index(at point: CGPoint, in bounds: CGRect, weights: [Int64]) -> Int? {
        let radius = min(bounds.width, bounds.height) / 2
        let dx = point.x - bounds.midX, dy = point.y - bounds.midY
        let distance = hypot(dx, dy)
        guard radius > 0, distance >= radius * 0.68, distance <= radius else { return nil }
        let total = weights.reduce(0.0) { $0 + Double(max(0, $1)) }
        guard total > 0 else { return nil }
        let angle = (atan2(dx, -dy) + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
        let value = angle / (2 * .pi) * total
        var end = 0.0
        for (index, weight) in weights.enumerated() where weight > 0 {
            end += Double(weight)
            if value < end { return index }
        }
        return nil
    }
}
