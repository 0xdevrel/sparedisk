import Charts
import SwiftUI

// Sunburst (§3.3): two rings around the focused level. The inner ring is the
// level itself, the outer ring its children; the center names the selection.
// Colors follow the same mode as the map. Click a sector to select, double
// click a folder to focus on it, click the center to go up.
struct SunburstView: View {
    @Environment(AppState.self) private var app
    @Environment(\.colorScheme) private var scheme
    let nodes: [ScanNode]
    /// Label for the root when the nodes are a Find result, not a location.
    var rootTitle: String?

    /// A flat list of files has nothing for an outer ring, so the one ring
    /// takes the whole radius instead of leaving an empty band.
    private var singleRing: Bool { levelNodes.allSatisfy { !$0.isFolder || $0.isPackage } }

    private struct Sector: Identifiable {
        let id: String
        let node: ScanNode?
        let parentID: String
        let bytes: Int64
        let ring: Int
        let start: Double // radians, clockwise from top
        let end: Double
        let color: Color
    }

    private var focus: ScanNode? { app.mapTrail.last }
    private var levelNodes: [ScanNode] {
        if let f = focus { return app.children(of: f) ?? [] }
        return nodes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height) - 24
                let sectors = layout()
                ZStack {
                    Canvas { ctx, size in
                        let c = CGPoint(x: size.width / 2, y: size.height / 2)
                        for s in sectors {
                            let (r0, r1) = radii(ring: s.ring, side: side)
                            var path = Path()
                            path.addArc(center: c, radius: r1, startAngle: .radians(s.start - .pi / 2), endAngle: .radians(s.end - .pi / 2), clockwise: false)
                            path.addArc(center: c, radius: r0, startAngle: .radians(s.end - .pi / 2), endAngle: .radians(s.start - .pi / 2), clockwise: true)
                            path.closeSubpath()
                            let selected = s.node != nil && s.node?.id == app.inspectedNodeID
                            ctx.fill(path, with: .color(s.color.opacity(selected ? 1 : 0.85)))
                            ctx.stroke(path, with: .color(Color(nsColor: .windowBackgroundColor)), lineWidth: selected ? 0 : 1.5)
                            if selected { ctx.stroke(path, with: .color(.accentColor), lineWidth: 2.5) }
                        }
                    }
                    centerLabel(side: side)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { location in
                    if let s = hit(location, in: geo.size, side: side, sectors: sectors), let n = s.node { drill(n) }
                }
                .onTapGesture { location in
                    if let s = hit(location, in: geo.size, side: side, sectors: sectors) {
                        if let n = s.node { app.inspectedNodeID = n.id } else { app.viewMode = .list }
                    } else if !app.mapTrail.isEmpty, distance(location, in: geo.size) < radii(ring: 0, side: side).0 {
                        _ = app.mapTrail.popLast()
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Sunburst of \(levelNodes.count) items, \(SDFormat.bytesString(levelNodes.reduce(0) { $0 + app.bytes($1) }))")
            }
            .padding(SDTheme.Space.md)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                app.mapTrail.removeAll()
            } label: {
                Label(rootTitle ?? app.activeLocation?.name ?? "Top", systemImage: rootTitle == nil ? "folder" : "circle.circle")
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
            }
            Spacer()
            if app.mapColor == .folder {
                Text(singleRing ? "Each file in proportion to its size. Grey: smaller items, click for the list."
                     : "Inner ring: this level. Outer ring: inside each folder. Grey: smaller items, click for the list.")
                    .foregroundStyle(.tertiary)
            } else {
                MapColorLegend().font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .font(SDTheme.Font.secondary)
        .padding(.horizontal, SDTheme.Space.md)
        .padding(.top, SDTheme.Space.xs)
    }

    private func centerLabel(side: CGFloat) -> some View {
        let inner = radii(ring: 0, side: side).0
        let node = app.inspectedNode ?? focus
        return VStack(spacing: 2) {
            if let node {
                Text(node.name).font(.system(size: 13, weight: .semibold)).lineLimit(2).multilineTextAlignment(.center)
                Text(SDFormat.bytesString(app.bytes(node))).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
            } else {
                Text(SDFormat.bytesString(levelNodes.reduce(0) { $0 + app.bytes($1) })).font(.system(size: 14, weight: .semibold).monospacedDigit())
                Text("\(levelNodes.count) items").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if !app.mapTrail.isEmpty {
                Text("Click to go up").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .frame(width: inner * 1.6)
    }

    // MARK: - Geometry

    private func radii(ring: Int, side: CGFloat) -> (CGFloat, CGFloat) {
        let r = side / 2
        if singleRing { return ring == 0 ? (r * 0.40, r * 0.98) : (r * 0.98, r * 0.98) }
        return ring == 0 ? (r * 0.34, r * 0.64) : (r * 0.66, r * 0.98)
    }

    private func distance(_ p: CGPoint, in size: CGSize) -> CGFloat {
        hypot(p.x - size.width / 2, p.y - size.height / 2)
    }

    private func hit(_ p: CGPoint, in size: CGSize, side: CGFloat, sectors: [Sector]) -> Sector? {
        let d = distance(p, in: size)
        var angle = atan2(p.x - size.width / 2, -(p.y - size.height / 2)) // 0 at top, clockwise
        if angle < 0 { angle += 2 * .pi }
        for s in sectors {
            let (r0, r1) = radii(ring: s.ring, side: side)
            if d >= r0 && d <= r1 && angle >= s.start && angle < s.end { return s }
        }
        return nil
    }

    /// Sectors narrower than this fold into one "smaller items" sector.
    private static let minSpan = 2 * Double.pi / 240

    private func layout() -> [Sector] {
        let sorted = levelNodes.sorted { app.bytes($0) > app.bytes($1) }
        let total = max(1, sorted.reduce(0) { $0 + app.bytes($1) })
        var level: [ScanNode] = []
        var restBytes: Int64 = 0
        var restCount = 0
        for n in sorted {
            if 2 * .pi * Double(app.bytes(n)) / Double(total) >= Self.minSpan && level.count < 48 {
                level.append(n)
            } else {
                restBytes += app.bytes(n); restCount += 1
            }
        }
        var out: [Sector] = []
        var angle = 0.0
        for (i, n) in level.enumerated() {
            let span = 2 * .pi * Double(app.bytes(n)) / Double(total)
            let color = color(for: n, rank: i)
            out.append(Sector(id: n.id, node: n, parentID: "", bytes: app.bytes(n), ring: 0, start: angle, end: angle + span, color: color))
            // Outer ring: children in size order, filler for bytes not in a retained child.
            let kids = n.isPackage ? [] : (app.children(of: n) ?? []).sorted { app.bytes($0) > app.bytes($1) }
            var a = angle
            let parentBytes = max(1, app.bytes(n))
            for (j, k) in kids.enumerated() {
                let ks = span * Double(app.bytes(k)) / Double(parentBytes)
                if ks * (Double(min(1000, 800)) / 2) >= 1.2 { // skip sub-pixel slivers
                    out.append(Sector(id: k.id, node: k, parentID: n.id, bytes: app.bytes(k), ring: 1, start: a, end: a + ks,
                                      color: childColor(base: color, node: k, index: j)))
                }
                a += ks
            }
            angle += span
        }
        if restCount > 0 {
            let span = 2 * .pi * Double(restBytes) / Double(total)
            out.append(Sector(id: "__other", node: nil, parentID: "", bytes: restBytes, ring: 0,
                              start: angle, end: angle + span, color: Color.primary.opacity(0.18)))
        }
        return out
    }

    private func color(for node: ScanNode, rank: Int) -> Color {
        switch app.mapColor {
        case .folder: return SDTheme.hue(rank, scheme: scheme)
        case .type: return SDTheme.color(for: node.category, scheme: scheme)
        case .age: return SDTheme.ageColor(bucket: SDTheme.ageBucket(for: node.modified), scheme: scheme)
        }
    }

    private func childColor(base: Color, node: ScanNode, index: Int) -> Color {
        switch app.mapColor {
        case .folder: return base.opacity(index % 2 == 0 ? 0.75 : 0.55)
        case .type: return SDTheme.color(for: node.category, scheme: scheme).opacity(0.8)
        case .age: return SDTheme.ageColor(bucket: SDTheme.ageBucket(for: node.modified), scheme: scheme).opacity(0.85)
        }
    }

    private func drill(_ node: ScanNode) {
        guard node.isFolder, !node.isPackage, !node.isCloudPlaceholder else { return }
        guard !app.mapTrail.contains(where: { $0.id == node.id }) else { return }
        app.mapTrail.append(node)
        app.inspectedNodeID = node.id
        app.ensureChildren(node)
    }
}
