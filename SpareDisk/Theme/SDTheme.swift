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

    // Up to six chart categories + neutral Unknown/Other. Stable identity across views.
    static func color(for category: SDFileCategory) -> Color {
        switch category {
        case .documents: return Color(red: 0.23, green: 0.47, blue: 0.85)
        case .media: return Color(red: 0.55, green: 0.36, blue: 0.78)
        case .archives: return Color(red: 0.85, green: 0.55, blue: 0.18)
        case .developer: return Color(red: 0.20, green: 0.60, blue: 0.52)
        case .apps: return Color(red: 0.83, green: 0.33, blue: 0.42)
        case .system: return Color(red: 0.45, green: 0.50, blue: 0.57)
        case .other: return Color(red: 0.55, green: 0.58, blue: 0.62)
        case .unknown: return Color(red: 0.68, green: 0.69, blue: 0.71)
        }
    }

    /// Flat map fill. Light mode wants a pastel over white; dark mode wants
    /// a deeper tint so text stays legible and orange does not turn brown.
    static func mapFill(for category: SDFileCategory, scheme: ColorScheme, emphasized: Bool) -> Color {
        let base = color(for: category)
        switch scheme {
        case .dark: return base.opacity(emphasized ? 0.72 : 0.5)
        default: return base.opacity(emphasized ? 0.5 : 0.3)
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
                .foregroundStyle(.secondary)
            Spacer()
            Button("Review") { app.showScanIssues = true }.buttonStyle(.link).font(SDTheme.Font.secondary)
        }
        .padding(8)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
}
