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
    /// Sector under the pointer and where the pointer is, for the hover label.
    @State private var hovered: (id: String, point: CGPoint)?

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
                            let isHovered = hovered?.id == s.id
                            ctx.fill(path, with: .color(s.color.opacity(selected || isHovered ? 1 : 0.85)))
                            ctx.stroke(path, with: .color(Color(nsColor: .windowBackgroundColor)), lineWidth: selected ? 0 : 1.5)
                            if selected { ctx.stroke(path, with: .color(.accentColor), lineWidth: 2.5) }
                            else if isHovered { ctx.stroke(path, with: .color(.primary.opacity(0.55)), lineWidth: 1.5) }
                        }
                    }
                    centerLabel(side: side)
                    if let hovered, let s = sectors.first(where: { $0.id == hovered.id }) {
                        hoverLabel(for: s, at: hovered.point, in: geo.size)
                    }
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        if let s = hit(location, in: geo.size, side: side, sectors: sectors) {
                            hovered = (s.id, location)
                        } else {
                            hovered = nil
                        }
                    case .ended:
                        hovered = nil
                    }
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
                .focusable()
                .onKeyPress(.rightArrow) { step(1, sectors: sectors); return .handled }
                .onKeyPress(.leftArrow) { step(-1, sectors: sectors); return .handled }
                .onKeyPress(.return) {
                    if let n = app.inspectedNode, n.isFolder, !n.isPackage { drill(n) }
                    return .handled
                }
                .onKeyPress(.space) { if let n = app.inspectedNode { app.preview(n) }; return .handled }
                .accessibilityLabel("Sunburst of \(levelNodes.count) items, \(SDFormat.bytesString(levelNodes.reduce(0) { $0 + app.bytes($1) }))")
                // Assistive technology gets one element per sector with the
                // same actions the pointer has.
                .accessibilityRepresentation {
                    VStack {
                        ForEach(sectors.filter { $0.ring == 0 }) { s in
                            if let n = s.node {
                                Button("\(n.name), \(SDFormat.bytesString(s.bytes))\(n.isFolder ? ", folder" : "")") {
                                    app.inspectedNodeID = n.id
                                }
                                .accessibilityAction(named: "Open") { if n.isFolder, !n.isPackage { drill(n) } }
                            } else {
                                Button("Smaller items, \(SDFormat.bytesString(s.bytes)), show in list") { app.viewMode = .list }
                            }
                        }
                    }
                }
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

    /// The center always describes the chart's root: the focused folder when
    /// drilled in, otherwise the whole level. Selection lives in the
    /// inspector, so the ring and its caption never disagree.
    private func centerLabel(side: CGFloat) -> some View {
        let inner = radii(ring: 0, side: side).0
        let node = focus
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

    /// Name, size and share of the level, next to the pointer and kept
    /// inside the chart. Sizes follow the size basis like everything else.
    private func hoverLabel(for s: Sector, at point: CGPoint, in size: CGSize) -> some View {
        let levelTotal = max(1, levelNodes.reduce(0) { $0 + app.bytes($1) })
        let parentBytes: Int64 = s.ring == 1
            ? (levelNodes.first(where: { $0.id == s.parentID }).map(app.bytes) ?? levelTotal)
            : levelTotal
        let share = Double(s.bytes) / Double(max(1, parentBytes)) * 100
        let title = s.node?.name ?? "Smaller items"
        let detail = s.node == nil
            ? "\(SDFormat.bytesString(s.bytes)), \(share.formatted(.number.precision(.fractionLength(share < 10 ? 1 : 0))))% of this level"
            : "\(SDFormat.bytesString(s.bytes)), \(share.formatted(.number.precision(.fractionLength(share < 10 ? 1 : 0))))% of \(s.ring == 1 ? "its folder" : "this level")"
        let width: CGFloat = 240, height: CGFloat = 46
        // Below and to the right of the pointer, flipped when it would leave the view.
        let x = point.x + 14 + width / 2 > size.width ? point.x - 14 - width / 2 : point.x + 14 + width / 2
        let y = point.y + 16 + height / 2 > size.height ? point.y - 16 - height / 2 : point.y + 16 + height / 2
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let n = s.node { CategoryDot(category: n.category) }
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            }
            Text(detail).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(width: width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        .position(x: x, y: y)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Arrow keys move the selection around the inner ring.
    private func step(_ delta: Int, sectors: [Sector]) {
        let ring = sectors.filter { $0.ring == 0 }.compactMap(\.node)
        guard !ring.isEmpty else { return }
        let current = ring.firstIndex { $0.id == app.inspectedNodeID } ?? (delta > 0 ? -1 : 0)
        let next = ((current + delta) % ring.count + ring.count) % ring.count
        app.inspectedNodeID = ring[next].id
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
