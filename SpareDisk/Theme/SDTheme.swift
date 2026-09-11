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

    // Up to six chart categories plus neutral Other/Unknown. Stable identity
    // across views. Dark mode lifts the tints so orange reads as orange on a
    // dark surface instead of brown.
    private static func rgb(_ category: SDFileCategory) -> (Double, Double, Double) {
        switch category {
        case .documents: (0.23, 0.47, 0.85)
        case .media: (0.55, 0.36, 0.78)
        case .archives: (0.93, 0.60, 0.22)
        case .developer: (0.20, 0.60, 0.52)
        case .apps: (0.83, 0.33, 0.42)
        case .system: (0.45, 0.50, 0.57)
        case .other: (0.55, 0.58, 0.62)
        case .unknown: (0.68, 0.69, 0.71)
        }
    }

    static func color(for category: SDFileCategory) -> Color {
        let (r, g, b) = rgb(category)
        return Color(red: r, green: g, blue: b)
    }

    /// Category color adjusted for the appearance: lifted toward white in
    /// dark mode so saturated fills stay recognizable.
    static func color(for category: SDFileCategory, scheme: ColorScheme) -> Color {
        let (r, g, b) = rgb(category)
        guard scheme == .dark else { return Color(red: r, green: g, blue: b) }
        let lift = 0.22
        return Color(red: r + (1 - r) * lift, green: g + (1 - g) * lift, blue: b + (1 - b) * lift)
    }

    /// Flat map fill. Light mode wants a pastel over white; dark mode wants
    /// a deeper tint so text stays legible and orange does not turn brown.
    static func mapFill(for category: SDFileCategory, scheme: ColorScheme, emphasized: Bool) -> Color {
        let base = color(for: category, scheme: scheme)
        switch scheme {
        case .dark: return base.opacity(emphasized ? 0.9 : 0.72)
        default: return base.opacity(emphasized ? 0.55 : 0.34)
        }
    }

    // MARK: Map palette
    // Eight muted hues assigned by rank within a level, so the largest items
    // are always distinguishable and the map is never a single grey block.
    // Category colors stay for dots and bars; the map is about shape.
    private static let hues: [(Double, Double, Double)] = [
        (0.36, 0.55, 0.86), // blue
        (0.34, 0.68, 0.62), // teal
        (0.86, 0.60, 0.30), // amber
        (0.70, 0.48, 0.80), // violet
        (0.86, 0.45, 0.50), // rose
        (0.52, 0.70, 0.42), // green
        (0.86, 0.72, 0.36), // gold
        (0.50, 0.58, 0.70), // slate
    ]

    static func hue(_ index: Int, scheme: ColorScheme) -> Color {
        let (r, g, b) = hues[((index % hues.count) + hues.count) % hues.count]
        if scheme == .dark {
            return Color(red: r * 0.78, green: g * 0.78, blue: b * 0.78)
        }
        return Color(red: r, green: g, blue: b)
    }

    /// Fill for a top-level map cell: a solid, appearance-tuned tint that
    /// keeps white or black text legible.
    static func mapFill(hue index: Int, scheme: ColorScheme, emphasized: Bool) -> Color {
        let base = hue(index, scheme: scheme)
        switch scheme {
        case .dark: return base.opacity(emphasized ? 1.0 : 0.82)
        default: return base.opacity(emphasized ? 0.62 : 0.42)
        }
    }

    static let rowHeight: CGFloat = 34
    /// Height of the bar that sits under the window toolbar on every screen.
    static let screenBarHeight: CGFloat = 40
    static let corner: CGFloat = 8
}

// MARK: - Shared bits

struct CategoryDot: View {
    let category: SDFileCategory
    var body: some View {
        Circle()
            .fill(SDTheme.color(for: category))
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }
}

struct SizeBar: View {
    var fraction: Double
    var category: SDFileCategory
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(SDTheme.color(for: category))
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
                HStack(spacing: 10) { leading }
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
        .frame(width: 200, height: 24)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? Color.accentColor : Color.primary.opacity(0.10), lineWidth: focused ? 1.5 : 1))
        .onKeyPress(.escape) { text = ""; return .handled }
    }
}
