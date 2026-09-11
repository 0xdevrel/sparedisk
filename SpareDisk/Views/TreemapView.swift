import AppKit
import SwiftUI

// Principal visual mode (§3.9, §7.4): squarified areas, flat fills, crisp
// 1-point gaps, one "Other" aggregate for cells too small to read. Every
// cell is a real button: focusable, VoiceOver-labelled, hover-highlighted.
// Return or double-click drills into a folder; the breadcrumb climbs back.
struct TreemapView: View {
    @Environment(AppState.self) private var app
    @Environment(\.colorScheme) private var scheme
    @State private var hoveredID: String?
    let nodes: [ScanNode]
    /// Embedded in Overview: no breadcrumb, no drilling, click opens Browse.
    var embedded = false
    /// Breadcrumb root label when the map is not a location (Find screens).
    var rootTitle: String?

    private var focus: ScanNode? { app.mapTrail.last }

    private var levelNodes: [ScanNode] {
        if let f = focus { return app.children(of: f) ?? [] }
        return nodes
    }

    private var levelSum: Int64 { levelNodes.reduce(0) { $0 + $1.logicalBytes } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !embedded { breadcrumb }
            GeometryReader { geo in
                if geo.size.width < 160 || geo.size.height < 120 {
                    Text("Widen the window to see the map.")
                        .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if levelNodes.isEmpty {
                    emptyLevel
                } else {
                    mapBody(size: geo.size)
                }
            }
            .padding(.horizontal, embedded ? 0 : SDTheme.Space.md)
            .padding(.vertical, embedded ? 0 : SDTheme.Space.xs)
        }
    }

    // MARK: - Breadcrumb

    private var breadcrumb: some View {
        HStack(spacing: 6) {
            Button {
                app.mapTrail.removeAll()
            } label: {
                Label(rootTitle ?? app.activeLocation?.name ?? "Top", systemImage: rootTitle == nil ? "folder" : "square.grid.2x2")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .foregroundStyle(app.mapTrail.isEmpty ? .primary : Color.accentColor)
            .disabled(app.mapTrail.isEmpty)
            ForEach(Array(app.mapTrail.enumerated()), id: \.element.id) { index, node in
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                Button(node.name) {
                    app.mapTrail.removeLast(app.mapTrail.count - index - 1)
                    app.inspectedNodeID = node.id
                }
                .buttonStyle(.plain)
                .foregroundStyle(index == app.mapTrail.count - 1 ? .primary : Color.accentColor)
                .disabled(index == app.mapTrail.count - 1)
                .lineLimit(1)
            }
            Spacer()
            Text(SDFormat.bytesString(levelSum))
                .font(SDTheme.Font.secondary.monospacedDigit()).foregroundStyle(.secondary)
            if !app.mapTrail.isEmpty {
                Button("Enclosing Folder", systemImage: "arrow.up") { _ = app.mapTrail.popLast() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .help("Enclosing folder (⌘↑)")
            }
        }
        .font(SDTheme.Font.secondary)
        .padding(.horizontal, SDTheme.Space.md)
        .padding(.top, SDTheme.Space.xs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Map location")
    }

    private var emptyLevel: some View {
        Group {
            if let f = focus, app.drillScanningID == f.id, let p = app.drillProgress {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Reading \(f.name)… \(p.itemsFound.formatted()) items")
                        .font(SDTheme.Font.body)
                    Button("Cancel") { app.cancelDrill() }.buttonStyle(.bordered).controlSize(.small)
                }
            } else if let f = focus {
                VStack(spacing: 8) {
                    Text("Couldn't read \(f.name).").font(SDTheme.Font.body)
                    Text("The folder may be offline or its access may have expired.")
                        .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                    Button("Try Again") { app.ensureChildren(f) }.buttonStyle(.bordered).controlSize(.small)
                }
            } else {
                Text("No files in this folder.").font(SDTheme.Font.body).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Layout

    private struct Entry {
        var node: ScanNode
        var isOther: Bool
        var members: Int
    }

    /// Cells smaller than this many square points cannot show a size label,
    /// so they are folded into one "Other" cell that does.
    private static let minCellArea: CGFloat = 56 * 24
    private static let maxCells = 80

    private func aggregated(_ items: [ScanNode], in rect: CGRect) -> [Entry] {
        let sorted = items.sorted { $0.logicalBytes > $1.logicalBytes }
        let sum = max(1, items.reduce(0) { $0 + $1.logicalBytes })
        let scale = rect.width * rect.height / CGFloat(sum)
        var big: [ScanNode] = []
        var small: [ScanNode] = []
        for (i, n) in sorted.enumerated() {
            if CGFloat(app.bytes(n)) * scale >= Self.minCellArea && i < Self.maxCells {
                big.append(n)
            } else {
                small.append(n)
            }
        }
        // A lone leftover is not "Other"; just show it.
        if small.count == 1, big.count < Self.maxCells { big.append(small.removeFirst()) }
        var out = big.map { Entry(node: $0, isOther: false, members: 0) }
        if !small.isEmpty {
            let bytes = small.reduce(0) { $0 + $1.logicalBytes }
            let other = ScanNode(id: "__other-\(focus?.id ?? "top")", name: "\(small.count) smaller items",
                                 path: "", isFolder: true, category: .other, logicalBytes: bytes,
                                 modified: nil, childCount: small.count)
            out.append(Entry(node: other, isOther: true, members: small.count))
        }
        return out
    }

    /// Smallest cell that can still show a size label. Anything smaller after
    /// layout is folded into the "smaller items" cell and the level is laid
    /// out again, so no cell is ever drawn blank.
    private static let minCellWidth: CGFloat = 52
    private static let minCellHeight: CGFloat = 18

    private func layout(_ items: [ScanNode], in rect: CGRect) -> (entries: [Entry], frames: [TreemapFrame]) {
        var entries = aggregated(items, in: rect)
        var frames = TreemapLayout.squarify(entries.map { ($0.node.id, CGFloat(app.bytes($0.node))) }, in: rect)
        for _ in 0..<8 {
            let tiny = Set(frames.filter { $0.rect.width < Self.minCellWidth || $0.rect.height < Self.minCellHeight }.map(\.id))
            let demoted = entries.filter { !$0.isOther && tiny.contains($0.node.id) }
            guard !demoted.isEmpty else { break }
            var kept = entries.filter { !$0.isOther && !tiny.contains($0.node.id) }
            var smallBytes = entries.first(where: { $0.isOther }).map { app.bytes($0.node) } ?? 0
            var smallCount = entries.first(where: { $0.isOther })?.members ?? 0
            for d in demoted { smallBytes += app.bytes(d.node); smallCount += 1 }
            if smallCount > 0 {
                let other = ScanNode(id: "__other-\(focus?.id ?? "top")", name: "\(smallCount) smaller items",
                                     path: "", isFolder: true, category: .other, logicalBytes: smallBytes,
                                     modified: nil, childCount: smallCount)
                kept.append(Entry(node: other, isOther: true, members: smallCount))
            }
            entries = kept
            frames = TreemapLayout.squarify(entries.map { ($0.node.id, CGFloat(app.bytes($0.node))) }, in: rect)
        }
        return (entries, frames)
    }

    private func mapBody(size: CGSize) -> some View {
        let rect = CGRect(origin: .zero, size: size)
        let (entries, frames) = layout(levelNodes, in: rect)
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.node.id, $0) })
        let rank = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.node.id, $0.offset) })
        return ZStack(alignment: .topLeading) {
            ForEach(frames, id: \.id) { frame in
                if let entry = byID[frame.id] {
                    let r = frame.rect.insetBy(dx: 1, dy: 1)
                    Group {
                        if entry.isOther {
                            otherCell(entry: entry, rect: r)
                        } else {
                            cell(node: entry.node, rect: r, hue: rank[entry.node.id] ?? 0)
                        }
                    }
                    .frame(width: max(0, r.width), height: max(0, r.height))
                    .position(x: frame.rect.midX, y: frame.rect.midY)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .focusable()
        .onKeyPress(.rightArrow) { step(entries.map(\.node), by: 1); return .handled }
        .onKeyPress(.leftArrow) { step(entries.map(\.node), by: -1); return .handled }
        .onKeyPress(.downArrow) { step(entries.map(\.node), by: 1); return .handled }
        .onKeyPress(.upArrow) { step(entries.map(\.node), by: -1); return .handled }
    }

    /// Arrow keys walk the level by size rank; selection wraps.
    private func step(_ ordered: [ScanNode], by delta: Int) {
        let real = ordered.filter { !$0.id.hasPrefix("__") }
        guard !real.isEmpty else { return }
        let current = real.firstIndex(where: { $0.id == app.inspectedNodeID }) ?? (delta > 0 ? -1 : 0)
        let next = ((current + delta) % real.count + real.count) % real.count
        app.inspectedNodeID = real[next].id
    }

    // MARK: - Cells

    /// Label plan for a cell of the given size. Size is shown whenever it
    /// fits, even when the name does not.
    private enum LabelPlan { case nameAndSize, nameOnly, sizeOnly, none }

    private func plan(for rect: CGRect) -> LabelPlan {
        if rect.width >= 72 && rect.height >= 34 { return .nameAndSize }
        if rect.width >= 72 && rect.height >= 17 { return .nameOnly }
        if rect.width >= 52 && rect.height >= 15 { return .sizeOnly }
        return .none
    }

    private func headerHeight(for plan: LabelPlan) -> CGFloat {
        switch plan {
        case .nameAndSize: 34
        case .nameOnly, .sizeOnly: 18
        case .none: 0
        }
    }

    private func cell(node: ScanNode, rect: CGRect, hue: Int) -> some View {
        let isSelected = selected(node)
        let isHovered = hoveredID == node.id
        let labels = plan(for: rect)
        let headerH = headerHeight(for: labels)
        // Nesting: real folders only (never packages), and only when the
        // body is large enough to show something readable.
        let kids = node.isPackage ? [] : (app.children(of: node) ?? []).sorted { $0.logicalBytes > $1.logicalBytes }
        let bodyRect = CGRect(x: 3, y: headerH, width: rect.width - 6, height: rect.height - headerH - 3)
        let canNest = !kids.isEmpty && bodyRect.width >= 80 && bodyRect.height >= 44
        let nested = canNest ? nestedEntries(kids, in: bodyRect) : []
        let childFrames = canNest
            ? TreemapLayout.squarify(nested.map { ($0.node.id, CGFloat(app.bytes($0.node))) }, in: bodyRect)
            : []
        let nestedByID = Dictionary(uniqueKeysWithValues: nested.map { ($0.node.id, $0) })

        return ZStack(alignment: .topLeading) {
            Rectangle().fill(SDTheme.mapFill(hue: hue, scheme: scheme, emphasized: isHovered || isSelected))
            if labels != .none {
                cellLabel(node: node, plan: labels)
                    .padding(.horizontal, 5)
                    .frame(width: rect.width, height: headerH, alignment: .leading)
            }
            if canNest {
                ForEach(childFrames, id: \.id) { frame in
                    if let entry = nestedByID[frame.id] {
                        let r = frame.rect.insetBy(dx: 1, dy: 1)
                        nestedCell(entry: entry, rect: r)
                            .frame(width: max(0, r.width), height: max(0, r.height))
                            .position(x: frame.rect.midX, y: frame.rect.midY)
                    }
                }
            }
            Rectangle()
                .stroke(isSelected ? Color.accentColor : Color.primary.opacity(isHovered ? 0.35 : 0.12),
                        lineWidth: isSelected ? 2 : 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if embedded { open(node) } else { drill(node) } }
        .onTapGesture { app.inspectedNodeID = node.id }
        .onHover { hoveredID = $0 ? node.id : (hoveredID == node.id ? nil : hoveredID) }
        .focusable()
        .onKeyPress(.return) { if embedded { open(node) } else { drill(node) }; return .handled }
        .onKeyPress(.space) { app.preview(node); return .handled }
        .contextMenu { NodeContextMenu(node: node, source: "Map") }
        .onDrag { NSItemProvider(object: URL(fileURLWithPath: node.path) as NSURL) }
        .help("\(node.name)\n\(SDFormat.bytesString(app.bytes(node)))\(node.isFolder && !node.isPackage ? "\nDouble-click to open" : "")")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(node.name), \(SDFormat.bytesString(app.bytes(node)))\(node.isFolder ? ", folder" : "")")
        .accessibilityAddTraits(.isButton)
    }

    private func cellLabel(node: ScanNode, plan: LabelPlan) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            switch plan {
            case .nameAndSize:
                Text(node.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(app.hasDiskHint(node)
                     ? "\(SDFormat.bytesString(node.logicalBytes)), \(SDFormat.bytesString(node.allocatedBytes ?? 0)) on disk"
                     : SDFormat.bytesString(app.bytes(node)))
                    .font(.system(size: 11).monospacedDigit()).opacity(0.85).lineLimit(1)
            case .nameOnly:
                Text(node.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
            case .sizeOnly:
                Text(SDFormat.bytesString(app.bytes(node)))
                    .font(.system(size: 11).monospacedDigit()).lineLimit(1)
            case .none:
                EmptyView()
            }
        }
        .foregroundStyle(.primary)
    }

    private func nestedEntries(_ kids: [ScanNode], in rect: CGRect) -> [Entry] {
        let sum = max(1, kids.reduce(0) { $0 + $1.logicalBytes })
        let scale = rect.width * rect.height / CGFloat(sum)
        var big: [ScanNode] = []
        var rest: [ScanNode] = []
        for k in kids {
            if CGFloat(app.bytes(k)) * scale >= 52 * 18 && big.count < 12 { big.append(k) } else { rest.append(k) }
        }
        if rest.count == 1 { big.append(rest.removeFirst()) }
        var out = big.map { Entry(node: $0, isOther: false, members: 0) }
        if !rest.isEmpty {
            let bytes = rest.reduce(0) { $0 + $1.logicalBytes }
            out.append(Entry(node: ScanNode(id: "__more-\(kids.first?.id ?? "")", name: "\(rest.count) more",
                                            path: "", isFolder: true, category: .other, logicalBytes: bytes,
                                            modified: nil, childCount: rest.count),
                             isOther: true, members: rest.count))
        }
        return out
    }

    private func nestedCell(entry: Entry, rect: CGRect) -> some View {
        let kid = entry.node
        let isSelected = !entry.isOther && selected(kid)
        let isHovered = !entry.isOther && hoveredID == kid.id
        let showBoth = rect.width >= 72 && rect.height >= 32
        let showName = !showBoth && rect.width >= 56 && rect.height >= 16
        let showSize = !showBoth && !showName && rect.width >= 52 && rect.height >= 16
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(entry.isOther ? 0.30 : (isHovered || isSelected ? 0.62 : 0.45)))
            if showBoth {
                VStack(alignment: .leading, spacing: 0) {
                    Text(kid.name).font(.system(size: 10, weight: .medium)).lineLimit(1)
                    Text(SDFormat.bytesString(app.bytes(kid))).font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                .foregroundStyle(entry.isOther ? .secondary : .primary)
                .padding(.horizontal, 4).padding(.top, 2)
            } else if showName || showSize {
                Text(showName ? kid.name : SDFormat.bytesString(app.bytes(kid)))
                    .font(.system(size: 10).monospacedDigit()).lineLimit(1)
                    .foregroundStyle(entry.isOther ? .secondary : .primary)
                    .padding(.horizontal, 4).padding(.top, 2)
            }
            Rectangle().stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.10), lineWidth: isSelected ? 2 : 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if !entry.isOther { if embedded { open(kid) } else { drill(kid) } } }
        .onTapGesture { if !entry.isOther { app.inspectedNodeID = kid.id } }
        .onHover { if !entry.isOther { hoveredID = $0 ? kid.id : (hoveredID == kid.id ? nil : hoveredID) } }
        .help(entry.isOther ? "\(entry.members) smaller items, \(SDFormat.bytesString(app.bytes(kid)))"
                            : "\(kid.name)\n\(SDFormat.bytesString(app.bytes(kid)))")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.isOther ? "\(entry.members) smaller items, \(SDFormat.bytesString(app.bytes(kid)))"
                                          : "\(kid.name), \(SDFormat.bytesString(app.bytes(kid)))")
    }

    private func otherCell(entry: Entry, rect: CGRect) -> some View {
        let labels = plan(for: rect)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.primary.opacity(hoveredID == entry.node.id ? 0.12 : 0.07))
            if labels != .none {
                VStack(alignment: .leading, spacing: 0) {
                    if labels != .sizeOnly {
                        Text(entry.node.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    }
                    if labels != .nameOnly {
                        Text(SDFormat.bytesString(app.bytes(entry.node)))
                            .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.horizontal, 5)
                .frame(width: rect.width, height: headerHeight(for: labels), alignment: .leading)
            }
            Rectangle().stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { showInList() }
        .onHover { hoveredID = $0 ? entry.node.id : (hoveredID == entry.node.id ? nil : hoveredID) }
        .focusable()
        .onKeyPress(.return) { showInList(); return .handled }
        .help("\(entry.members) items too small to draw, \(SDFormat.bytesString(app.bytes(entry.node))) in total.\nClick to see them in the list.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.members) smaller items, \(SDFormat.bytesString(app.bytes(entry.node))). Activate to show in list.")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Helpers

    private func selected(_ node: ScanNode) -> Bool { app.inspectedNodeID == node.id }

    /// Embedded map: jump to the location's full map, focused on the folder.
    private func open(_ node: ScanNode) {
        guard let id = app.activeLocation?.id else { return }
        app.viewMode = .map
        app.selection = .location(id)
        if node.isFolder, !node.isPackage {
            app.mapTrail = [node]
            app.ensureChildren(node)
        }
        app.inspectedNodeID = node.id
    }

    private func showInList() {
        app.viewMode = .list
        if embedded, let id = app.activeLocation?.id { app.selection = .location(id) }
    }

    private func drill(_ node: ScanNode) {
        guard node.isFolder, !node.isPackage, !node.isCloudPlaceholder else { return }
        guard !app.mapTrail.contains(where: { $0.id == node.id }) else { return }
        app.mapTrail.append(node)
        app.inspectedNodeID = node.id
        app.ensureChildren(node)
    }
}
