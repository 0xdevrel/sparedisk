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

    static let rowHeight: CGFloat = 34
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
