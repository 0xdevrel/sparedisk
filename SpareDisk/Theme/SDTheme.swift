import SwiftUI

// Quiet native utility theme — §7. Restraint over decoration.
enum SDTheme {
    // Spacing rhythm: 4, 8, 12, 16, 24, 32
    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
    }

    enum Font {
        static let body = SwiftUI.Font.system(size: 14)
        static let secondary = SwiftUI.Font.system(size: 12.5)
        static let section = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let screenTitle = SwiftUI.Font.system(size: 24, weight: .semibold)
        static let figure = SwiftUI.Font.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit()
        static let figureSmall = SwiftUI.Font.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit()
    }

    typealias RGB = (r: Double, g: Double, b: Double)

    /// Categories share the chart palette in every view, including legends.
    static func categoryComponents(_ category: SDFileCategory, scheme: ColorScheme) -> RGB {
        let index: Int
        switch category {
        case .documents: index = 0
        case .developer: index = 1
        case .archives: index = 2
        case .media: index = 3
        case .apps: index = 4
        case .system: index = 7
        case .other, .unknown: return neutralComponents(scheme: scheme)
        }
        return hueComponents(index, scheme: scheme)
    }

    static func color(for category: SDFileCategory, scheme: ColorScheme) -> Color {
        let c = categoryComponents(category, scheme: scheme)
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    /// The window background each map fill is composited over.
    static func backgroundLuminanceComponents(scheme: ColorScheme) -> (r: Double, g: Double, b: Double) {
        scheme == .dark ? (0.118, 0.118, 0.118) : (1, 1, 1)
    }

    /// The fill a cell actually shows: the mode's color at the map opacity
    /// over the window background.
    static func effectiveFill(_ c: (r: Double, g: Double, b: Double), alpha: Double, scheme: ColorScheme) -> (r: Double, g: Double, b: Double) {
        let bg = backgroundLuminanceComponents(scheme: scheme)
        return (c.r * alpha + bg.r * (1 - alpha), c.g * alpha + bg.g * (1 - alpha), c.b * alpha + bg.b * (1 - alpha))
    }

    /// White or black, whichever reads better on the fill. One of the
    /// two always clears 4.5:1, so labels never depend on the fill's hue.
    static func labelComponents(over fill: (r: Double, g: Double, b: Double)) -> (r: Double, g: Double, b: Double) {
        let light: (r: Double, g: Double, b: Double) = (1, 1, 1)
        let dark: (r: Double, g: Double, b: Double) = (0, 0, 0)
        return contrast(fill, light) >= contrast(fill, dark) ? light : dark
    }

    static func labelColor(over fill: (r: Double, g: Double, b: Double)) -> Color {
        let c = labelComponents(over: fill)
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    // MARK: Map palette

    // Paired light/dark colours: blue, teal, amber, violet, rose, green,
    // cyan, slate. Explicit dark values preserve hue instead of multiplying
    // every channel down into muddy brown and olive. Both charts use these
    // same fills; geometry and interaction never determine colour identity.
    private static let lightHues: [RGB] = [
        (0.73, 0.83, 0.96), (0.68, 0.85, 0.80),
        (0.95, 0.81, 0.60), (0.83, 0.76, 0.93),
        (0.94, 0.75, 0.80), (0.78, 0.86, 0.69),
        (0.68, 0.84, 0.91), (0.79, 0.83, 0.89),
    ]
    private static let darkHues: [RGB] = [
        (0.25, 0.43, 0.66), (0.22, 0.47, 0.43),
        (0.57, 0.40, 0.19), (0.45, 0.35, 0.60),
        (0.57, 0.34, 0.42), (0.34, 0.46, 0.29),
        (0.23, 0.46, 0.57), (0.35, 0.43, 0.53),
    ]

    static var hueCount: Int { lightHues.count }

    /// FNV-1a is deliberately stable across launches, unlike Swift Hasher.
    /// Use the path rather than a scan/ranking ID, which can have aliases.
    static func folderHueIndex(path: String) -> Int {
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
        var hash: UInt64 = 14695981039346656037
        for byte in canonical.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return Int(hash % UInt64(hueCount))
    }

    /// Hues for one level of siblings, largest first. Each keeps its
    /// path-hashed hue when free, otherwise the next free hue, so colours
    /// stay stable across views while neighbours never share one when the
    /// level has eight or fewer members.
    static func folderHues(for nodes: [ScanNode], bytes: (ScanNode) -> Int64) -> [String: Int] {
        var taken = Set<Int>()
        var out: [String: Int] = [:]
        for n in nodes.sorted(by: { bytes($0) > bytes($1) }) {
            let key = n.path.isEmpty ? n.id : n.path
            var hue = folderHueIndex(path: key)
            if taken.count < hueCount {
                var tries = 0
                while taken.contains(hue), tries < hueCount { hue = (hue + 1) % hueCount; tries += 1 }
            }
            taken.insert(hue)
            out[n.id] = hue
        }
        return out
    }

    static func hueComponents(_ index: Int, scheme: ColorScheme) -> RGB {
        let palette = scheme == .dark ? darkHues : lightHues
        return palette[((index % palette.count) + palette.count) % palette.count]
    }

    static func hue(_ index: Int, scheme: ColorScheme) -> Color {
        let c = hueComponents(index, scheme: scheme)
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    /// Grey for things that carry no category: the Other kind and unknown
    /// dates. Distinct from the window and from folded cells.
    static func neutralComponents(scheme: ColorScheme) -> RGB {
        scheme == .dark ? (0.40, 0.43, 0.47) : (0.72, 0.74, 0.78)
    }

    /// Quieter grey for "N smaller items" cells, which are containers for
    /// what did not fit rather than data in their own right.
    static func foldedComponents(scheme: ColorScheme) -> RGB {
        scheme == .dark ? (0.26, 0.28, 0.31) : (0.86, 0.87, 0.89)
    }

    /// `hue` is the level-resolved folder hue when the caller has one; the
    /// bare path hash otherwise.
    static func mapComponents(for node: ScanNode, mode: SDMapColor, scheme: ColorScheme, hue: Int? = nil) -> RGB {
        switch mode {
        case .folder: hueComponents(hue ?? folderHueIndex(path: node.path.isEmpty ? node.id : node.path), scheme: scheme)
        case .type: categoryComponents(node.category, scheme: scheme)
        case .age: ageComponents(bucket: ageBucket(for: node.modified), scheme: scheme)
        }
    }

    /// Hierarchy changes lightness only in folder mode. Type and age colours
    /// retain their exact meaning at every depth. Both charts call this.
    static func childMapComponents(for node: ScanNode, parent: RGB, mode: SDMapColor, scheme: ColorScheme) -> RGB {
        guard mode == .folder else { return mapComponents(for: node, mode: mode, scheme: scheme) }
        let amount = folderHueIndex(path: node.path) % 2 == 0 ? 0.12 : 0.22
        return (parent.r + (1 - parent.r) * amount,
                parent.g + (1 - parent.g) * amount,
                parent.b + (1 - parent.b) * amount)
    }

    /// Small state change; selection is primarily communicated by an outline.
    static func mapFillOpacity(scheme: ColorScheme, emphasized: Bool) -> Double {
        emphasized ? 1 : 0.94
    }

    /// WCAG relative luminance and contrast ratio, for the palette test.
    static func luminance(_ c: (r: Double, g: Double, b: Double)) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    static func contrast(_ a: (r: Double, g: Double, b: Double), _ b: (r: Double, g: Double, b: Double)) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Age buckets for the map's By Age coloring, oldest first.
    static let ageBuckets: [(label: String, years: Double)] = [
        ("Over 5 years", 5), ("2 to 5 years", 2), ("1 to 2 years", 1), ("6 to 12 months", 0.5), ("Under 6 months", 0),
    ]

    static func ageBucket(for date: Date?) -> Int {
        guard let date else { return -1 }
        let years = Date().timeIntervalSince(date) / (365.25 * 86400)
        for (i, b) in ageBuckets.enumerated() where years >= b.years { return i }
        return ageBuckets.count - 1
    }

    /// Oldest files have the strongest blue; recent files recede. Unknown
    /// dates are neutral, never presented as evidence that a file is old.
    static func ageComponents(bucket: Int, scheme: ColorScheme) -> RGB {
        guard ageBuckets.indices.contains(bucket) else { return neutralComponents(scheme: scheme) }
        let light: [RGB] = [
            (0.50, 0.65, 0.84), (0.62, 0.74, 0.88), (0.73, 0.82, 0.92),
            (0.82, 0.88, 0.95), (0.90, 0.93, 0.97),
        ]
        let dark: [RGB] = [
            (0.29, 0.49, 0.73), (0.27, 0.42, 0.62), (0.24, 0.35, 0.51),
            (0.22, 0.29, 0.41), (0.20, 0.24, 0.31),
        ]
        return (scheme == .dark ? dark : light)[bucket]
    }

    static func ageColor(bucket: Int, scheme: ColorScheme) -> Color {
        let c = ageComponents(bucket: bucket, scheme: scheme)
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    static let rowHeight: CGFloat = 34
    /// Height of the bar that sits under the window toolbar on every screen.
    static let screenBarHeight: CGFloat = 40
    static let corner: CGFloat = 8
}

// MARK: - Shared bits

struct CategoryDot: View {
    @Environment(\.colorScheme) private var scheme
    let category: SDFileCategory
    var body: some View {
        Circle()
            .fill(SDTheme.color(for: category, scheme: scheme))
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }
}

struct SizeBar: View {
    @Environment(\.colorScheme) private var scheme
    var fraction: Double
    var category: SDFileCategory
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(SDTheme.color(for: category, scheme: scheme))
                    .frame(width: max(3, geo.size.width * min(1, fraction)))
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

struct MonospaceBytes: View {
    let bytes: Int64
    var body: some View {
        Text(SDFormat.bytesString(bytes))
            .font(.system(size: 13).monospacedDigit())
            .foregroundStyle(.primary)
            .lineLimit(1)
    }
}

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(SDTheme.Font.section)
            .foregroundStyle(.primary)
            .padding(.bottom, SDTheme.Space.xs)
            .accessibilityAddTraits(.isHeader)
    }
}

struct IssueBanner: View {
    @Environment(AppState.self) private var app
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(SDTheme.Font.secondary)
                .foregroundStyle(.primary)
            Spacer()
            Button("Details") { app.showScanIssues = true }.buttonStyle(.link).font(SDTheme.Font.secondary)
        }
        .padding(8)
        .background(Color.orange.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Screen bar and search

/// The strip under the toolbar that every screen shares: context on the
/// left, controls on the right, one height, one padding.
struct ScreenBar<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // Leading text truncates before the column asks the window
                // for more room; controls on the right keep their size.
                HStack(spacing: 10) { leading }
                    .lineLimit(1).truncationMode(.tail)
                    .frame(minWidth: 0, alignment: .leading)
                    .layoutPriority(-1)
                    .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                HStack(spacing: 8) { trailing }
                    .controlSize(.small)
            }
            .padding(.horizontal, SDTheme.Space.md)
            .frame(height: SDTheme.screenBarHeight)
            Divider()
        }
    }
}

/// A compact search field that lives inside the content column, so it
/// aligns with the content instead of floating over the inspector.
struct SearchField: View {
    @Binding var text: String
    var prompt = "Search"
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 11, weight: .medium))
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 7)
        .frame(minWidth: 130, idealWidth: 200, maxWidth: 200)
        .frame(height: 24)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? Color.accentColor : Color.primary.opacity(0.10), lineWidth: focused ? 1.5 : 1))
        .onKeyPress(.escape) { text = ""; return .handled }
    }
}

extension SDTheme {
    /// Laptop or desktop glyph for this machine, the way Finder's sidebar does.
    static let macSymbol: String = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "desktopcomputer" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer).contains("Book") ? "macbook" : "desktopcomputer"
    }()
}

/// Lays children out left to right and wraps to new rows, so legends and
/// chip rows never force a minimum width on the window.
struct FlowLayout: Layout {
    var spacing: CGFloat = 10
    var rowSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(width: width, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + rowSpacing * CGFloat(max(0, rows.count - 1))
        let used = rows.map(\.width).max() ?? 0
        return CGSize(width: width == .infinity ? used : min(width, max(used, 0)), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + rowSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            var row = rows[rows.count - 1]
            let next = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if next > width, !row.indices.isEmpty {
                rows.append(Row(indices: [i], width: size.width, height: size.height))
            } else {
                row.indices.append(i); row.width = next; row.height = max(row.height, size.height)
                rows[rows.count - 1] = row
            }
        }
        return rows
    }
}
