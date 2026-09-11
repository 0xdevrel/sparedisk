import SwiftUI

// Principal visual mode (§3.9, §7.4): bounded squarified areas, crisp
// separators, "Other items" aggregation, labels only when they fit both
// dimensions. Cells are real buttons: Tab-focusable, VoiceOver-labelled,
// double-click drills into folders with children. "Other" switches to the
// ranked list, where every small item is explorable — the map never strands.
struct TreemapView: View {
    @Environment(AppState.self) private var app
    let nodes: [ScanNode]

    private var levelNodes: [ScanNode] {
        app.mapTrail.last?.children ?? nodes
    }

    private var levelSum: Int64 { levelNodes.reduce(0) { $0 + $1.logicalBytes } }

    private var hasNested: Bool { levelNodes.contains { !($0.children ?? []).isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            breadcrumb
            HStack {
                Text("Map · \(hasNested ? "up to 2 levels" : "1 level") · areas share \(SDFormat.bytesString(levelSum)) shown")
                    .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                Spacer()
                Text("Double-click a folder to drill in")
                    .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
            }
            .padding(.horizontal, SDTheme.Space.md)

            GeometryReader { geo in
                if geo.size.width < 120 || geo.size.height < 120 {
                    Text("Make the window wider to explore the map — the list always works.")
                        .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if levelNodes.isEmpty {
                    Text("No files found in this folder.").font(SDTheme.Font.body)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    mapBody(size: geo.size)
                }
            }
            .padding(SDTheme.Space.sm)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, SDTheme.Space.md)
            .padding(.bottom, SDTheme.Space.sm)

            Text("Same data as the list — every action is also available from rows and menus.")
                .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                .padding(.horizontal, SDTheme.Space.md)
                .padding(.bottom, SDTheme.Space.sm)
        }
    }

    // MARK: - Breadcrumb drill-down

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            Button(app.mapTrail.isEmpty ? "This folder" : "Top") {
                app.mapTrail.removeAll()
            }
            .buttonStyle(.link).font(SDTheme.Font.secondary)
            .disabled(app.mapTrail.isEmpty)
            ForEach(Array(app.mapTrail.enumerated()), id: \.element.id) { index, node in
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                Button(node.name) {
                    app.mapTrail.removeLast(app.mapTrail.count - index - 1)
                    app.inspectedNodeID = node.id
                }
                .buttonStyle(.link).font(SDTheme.Font.secondary)
                .lineLimit(1)
            }
            Spacer()
            if !app.mapTrail.isEmpty {
                Button("Up") { _ = app.mapTrail.popLast() }
                    .buttonStyle(.link).font(SDTheme.Font.secondary)
            }
        }
        .padding(.horizontal, SDTheme.Space.md)
        .padding(.top, SDTheme.Space.sm)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Map location")
    }

    // MARK: - Map body

    private func mapBody(size: CGSize) -> some View {
        let rect = CGRect(origin: .zero, size: size)
        let entries = aggregated(levelNodes, tag: "top")
        let frames = TreemapLayout.squarify(entries.map { ($0.node.id, CGFloat($0.node.logicalBytes)) }, in: rect)
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.node.id, $0) })
        return ZStack(alignment: .topLeading) {
            ForEach(frames, id: \.id) { frame in
                if let entry = byID[frame.id] {
                    if entry.isOther {
                        otherCell(entry: entry, rect: frame.rect)
                            .offset(x: frame.rect.minX + 2, y: frame.rect.minY + 2)
                    } else {
                        folderCell(node: entry.node, rect: frame.rect.insetBy(dx: 2, dy: 2), denom: levelSum)
                            .offset(x: frame.rect.minX + 2, y: frame.rect.minY + 2)
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }

    /// Split a level into comparable marks + one "Other" aggregate.
    private func aggregated(_ items: [ScanNode], tag: String) -> [(node: ScanNode, isOther: Bool, members: Int)] {
        let sorted = items.sorted { $0.logicalBytes > $1.logicalBytes }
        let sum = items.reduce(0) { $0 + $1.logicalBytes }
        let threshold = sum / 64 // ~1.5% of this level
        let big = sorted.filter { $0.logicalBytes >= threshold }
        let small = sorted.filter { $0.logicalBytes < threshold }
        var out = big.map { (node: $0, isOther: false, members: 0) }
        if !small.isEmpty {
            let bytes = small.reduce(0) { $0 + $1.logicalBytes }
            let other = ScanNode(id: "__other-\(tag)", name: "Other \(small.count) items", path: "",
                                 isFolder: true, category: .other, logicalBytes: bytes,
                                 modified: nil, childCount: small.count)
            out.append((node: other, isOther: true, members: small.count))
        }
        return out
    }

    // MARK: - Cells

    private func folderCell(node: ScanNode, rect: CGRect, denom: Int64) -> some View {
        let kids = (node.children ?? []).sorted { $0.logicalBytes > $1.logicalBytes }
        let shown = Array(kids.prefix(8))
        let hidden = kids.count - shown.count
        let canNest = !shown.isEmpty && rect.width > 120 && rect.height > 90
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(SDTheme.color(for: node.category).opacity(selected(node) ? 0.85 : 0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(selected(node) ? Color.accentColor : Color.primary.opacity(0.18),
                                lineWidth: selected(node) ? 2.5 : 1)
                )
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    app.inspectedNodeID = node.id
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        if rect.width > 64 {
                            Text(node.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        }
                        if rect.width > 64 && rect.height > 40 {
                            Text(SDFormat.bytesString(node.logicalBytes))
                                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable()
                .simultaneousGesture(TapGesture(count: 2).onEnded { drill(node) })
                .help("\(node.name) — \(SDFormat.bytesString(node.logicalBytes)). Double-click to drill in.")
                .accessibilityLabel("\(node.name), \(SDFormat.bytesString(node.logicalBytes))\(kids.isEmpty ? "" : ", folder, double-click to drill in")")

                if canNest {
                    let bodyRect = CGRect(x: 0, y: 0, width: rect.width - 8, height: rect.height - 34)
                    let childFrames = TreemapLayout.squarify(shown.map { ($0.id, CGFloat($0.logicalBytes)) }, in: bodyRect)
                    ZStack(alignment: .topLeading) {
                        ForEach(childFrames, id: \.id) { frame in
                            if let kid = shown.first(where: { $0.id == frame.id }) {
                                Button {
                                    app.inspectedNodeID = kid.id
                                } label: {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.75))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 3)
                                                .stroke(selected(kid) ? Color.accentColor : Color.primary.opacity(0.15),
                                                        lineWidth: selected(kid) ? 2 : 1)
                                        )
                                        .overlay(alignment: .topLeading) {
                                            if frame.rect.width > 56 && frame.rect.height > 22 {
                                                Text(kid.name).font(.system(size: 10)).lineLimit(1)
                                                    .padding(4)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                                .focusable()
                                .simultaneousGesture(TapGesture(count: 2).onEnded { drill(kid) })
                                .help("\(kid.name) — \(SDFormat.bytesString(kid.logicalBytes))")
                                .accessibilityLabel("\(kid.name), \(SDFormat.bytesString(kid.logicalBytes))")
                                .frame(width: max(0, frame.rect.width - 2), height: max(0, frame.rect.height - 2))
                                .offset(x: frame.rect.minX + 4, y: frame.rect.minY)
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    if hidden > 0 {
                        Text("+\(hidden) more in list")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.bottom, 4)
                    }
                }
            }
        }
        .frame(width: max(0, rect.width), height: max(0, rect.height))
    }

    private func otherCell(entry: (node: ScanNode, isOther: Bool, members: Int), rect: CGRect) -> some View {
        Button {
            // Meaningful activation: the ranked list explores every member.
            app.viewMode = .list
        } label: {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .separatorColor).opacity(0.45))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.primary.opacity(0.18), lineWidth: 1)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    if rect.width > 64 {
                        Text("Other \(entry.members)").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    }
                    if rect.width > 64 && rect.height > 40 {
                        Text("Show in list").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(6)
            }
        }
        .buttonStyle(.plain)
        .focusable()
        .frame(width: max(0, rect.width - 4), height: max(0, rect.height - 4))
        .help("Other \(entry.members) small items — activate to explore them in the list")
        .accessibilityLabel("Other \(entry.members) small items. Activate to show in list.")
    }

    // MARK: - Helpers

    private func selected(_ node: ScanNode) -> Bool { app.inspectedNodeID == node.id }

    private func drill(_ node: ScanNode) {
        guard node.isFolder, !(node.children ?? []).isEmpty else { return }
        app.mapTrail.append(node)
        app.inspectedNodeID = node.id
    }
}
