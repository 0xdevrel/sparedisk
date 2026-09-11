import AppKit
import SwiftUI

// Inspector order (§F05): name/type → path → size → dates/counts → access/risk → preview/reveal → staging.
struct InspectorView: View {
    @Environment(AppState.self) private var app
    @State private var actionNotice: String?

    private var node: ScanNode? { app.inspectedNode }

    /// Grant-backed availability: bare path checks fail after relaunch when
    /// no scope is held, so availability means "a grant covers this node" (P1).
    private func hasGrant(_ node: ScanNode) -> Bool {
        app.scopeForNode(node) != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SDTheme.Space.sm) {
                if let node {
                    // 1. Name + type
                    HStack(spacing: 10) {
                        FileTypeIcon(node: node, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(node.name).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                            HStack(spacing: 6) {
                                CategoryDot(category: node.category)
                                Text(node.category.label).font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                            }
                        }
                    }

                    // 2. Path
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Path").font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                        Text(node.path).font(.system(size: 12.5)).foregroundStyle(.primary)
                            .lineLimit(3).truncationMode(.middle).textSelection(.enabled)
                    }

                    Divider()

                    // 3. Size — logical + on-disk kept independent
                    VStack(alignment: .leading, spacing: 4) {
                        Text(SDFormat.bytesString(node.logicalBytes)).font(SDTheme.Font.figureSmall)
                        Text(SDFormat.exactBytes(node.logicalBytes)).font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                        Text(app.hasRealData ? "Logical size · scanned contents" : "Sample data · not your files").font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                        Text("On-disk allocation: Not measured").font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                    }

                    Divider()

                    // 4. Dates / counts
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        GridRow { Text("Modified").foregroundStyle(.secondary); Text(SDFormat.date(node.modified)) }
                        GridRow { Text("Items").foregroundStyle(.secondary); Text(node.isFolder ? "\(node.childCount) items (recursive)" : "1 file") }
                        GridRow { Text("Access").foregroundStyle(.secondary); Text(node.isUnreadable ? "Could not read" : node.isCloudPlaceholder ? "Cloud-only item" : "Checked again before cleanup").foregroundStyle(.primary) }
                    }
                    .font(SDTheme.Font.secondary)

                    // 5. Risk context
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle").foregroundStyle(Color.accentColor)
                        Text(node.isFolder ? "Review contents before moving. New files need renewed review." : "Moves to Trash only after you confirm in Review.")
                            .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

                    // 6. Preview / reveal
                    if node.isCloudPlaceholder {
                        HStack(spacing: 8) {
                            Image(systemName: "icloud.and.arrow.down").foregroundStyle(.secondary)
                            Text("Cloud-only item. Preview would download it — use Finder to choose download vs. remove.")
                                .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                    HStack(spacing: 8) {
                        Button("Quick Look") {
                            actionNotice = app.preview(node)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!hasGrant(node) || node.isCloudPlaceholder)
                        .help("Preview selected file")
                        Button("Reveal in Finder") {
                            actionNotice = app.reveal(node)
                        }.buttonStyle(.bordered).disabled(!hasGrant(node))
                    }
                    .font(SDTheme.Font.secondary)

                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(node.path, forType: .string)
                    }.buttonStyle(.link).font(SDTheme.Font.secondary)

                    if let m = actionNotice {
                        Text(m).font(SDTheme.Font.secondary).foregroundStyle(.orange)
                    }

                    Divider()

                    // 7. Staging
                    Button(app.isQueued(node.id) ? "Remove from Review" : "Add to Review") {
                        app.toggleReview(node, source: "Inspector")
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .disabled(!app.canReview(node))

                    Text("Quick Look opens on explicit request only. Cloud-only items show a download warning first.")
                        .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                } else {
                    Text("Select an item to inspect").foregroundStyle(.secondary)
                }
            }
            .padding(SDTheme.Space.md)
        }
        .accessibilityLabel("Selection inspector")
    }
}
