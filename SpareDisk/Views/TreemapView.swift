import SwiftUI

// Principal visual mode (§3.9, §7.4): shallow nesting, crisp separators,
// "Other items" aggregation, labels only when they fit.
struct TreemapView: View {
    @Environment(AppState.self) private var app
    let nodes: [ScanNode]
    let total: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Map · 2 levels · each area = logical size")
                    .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                Spacer()
                Text("Tiny items grouped into Other")
                    .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
            }
            .padding(.horizontal, SDTheme.Space.md)
            .padding(.top, SDTheme.Space.sm)

            GeometryReader { geo in
                TreemapLayout(nodes: visibleNodes, total: total, size: geo.size) { node, rect, isOther in
                    TreemapCell(node: node, rect: rect, total: total, isOther: isOther)
                        .onTapGesture { app.inspectedNodeID = isOther ? nil : node.id }
                }
            }
            .padding(SDTheme.Space.sm)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, SDTheme.Space.md)
            .padding(.bottom, SDTheme.Space.sm)

            // Keyboard-accessible ranked list mirror (§7.4)
            Text("Same data as list — every action is also available from rows and menus.")
                .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                .padding(.horizontal, SDTheme.Space.md)
                .padding(.bottom, SDTheme.Space.sm)
        }
    }

    private var visibleNodes: [ScanNode] {
        // Aggregate marks below pixel-area threshold into Other
        let sorted = nodes.sorted { $0.logicalBytes > $1.logicalBytes }
        let threshold = total / 60 // ~1.6% — below this goes to Other at this zoom
        let big = sorted.filter { $0.logicalBytes >= threshold }
        let small = sorted.filter { $0.logicalBytes < threshold }
        guard !small.isEmpty else { return big }
        let otherBytes = small.reduce(0) { $0 + $1.logicalBytes }
        let other = ScanNode(id: "__other", name: "Other \(small.count) items", path: "",
                             isFolder: true, category: .other, logicalBytes: otherBytes,
                             modified: nil, childCount: small.count)
        return big + [other]
    }
}

private struct TreemapCell: View {
    @Environment(AppState.self) private var app
    let node: ScanNode
    let rect: CGRect
    let total: Int64
    let isOther: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(isOther ? Color(nsColor: .separatorColor).opacity(0.5) : SDTheme.color(for: node.category).opacity(selected ? 0.85 : 0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(selected ? Color.accentColor : Color.primary.opacity(0.18), lineWidth: selected ? 2.5 : 1)
                )
            VStack(alignment: .leading, spacing: 2) {
                if rect.width > 76 {
                    Text(node.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).foregroundStyle(.primary)
                }
                if rect.width > 76 && rect.height > 34 {
                    Text(SDFormat.bytesString(node.logicalBytes)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                }
                if rect.width > 110 && rect.height > 52 {
                    Text(SDFormat.pct(node.share(of: total))).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(7)
        }
        .frame(width: rect.width, height: rect.height)
        .help("\(node.name) — \(SDFormat.bytesString(node.logicalBytes))")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(node.name), \(SDFormat.bytesString(node.logicalBytes))")
    }

    private var selected: Bool { app.inspectedNodeID == node.id }
}

// Simple deterministic slice-and-dice layout: stable, no animation of thousands of marks.
private struct TreemapLayout<Content: View>: View {
    let nodes: [ScanNode]
    let total: Int64
    let size: CGSize
    let content: (ScanNode, CGRect, Bool) -> Content

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(frames, id: \.node.id) { item in
                content(item.node, item.rect, item.node.id == "__other")
                    .offset(x: item.rect.minX, y: item.rect.minY)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private var frames: [(node: ScanNode, rect: CGRect)] {
        guard total > 0, size.width > 10, size.height > 10 else { return [] }
        var out: [(ScanNode, CGRect)] = []
        var x: CGFloat = 0
        let gap: CGFloat = 4
        for node in nodes {
            let w = max(40, (CGFloat(node.logicalBytes) / CGFloat(total)) * (size.width - gap * CGFloat(nodes.count - 1)))
            let rect = CGRect(x: x, y: 0, width: min(w, size.width - x), height: size.height)
            out.append((node, rect))
            x += w + gap
        }
        return out
    }
}
