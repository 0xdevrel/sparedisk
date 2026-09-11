import AppKit
import SwiftUI

// Inspector order (§F05): name and kind, path, size, dates and counts,
// largest children for folders, actions, staging.
struct InspectorView: View {
    @Environment(AppState.self) private var app
    @State private var actionNotice: String?

    private var node: ScanNode? { app.inspectedNode }

    private func hasGrant(_ node: ScanNode) -> Bool { app.scopeForNode(node) != nil }

    var body: some View {
        ScrollView {
            if let node {
                VStack(alignment: .leading, spacing: SDTheme.Space.sm) {
                    identity(node)
                    Divider()
                    size(node)
                    Divider()
                    facts(node)
                    if node.isFolder, !node.isPackage {
                        Divider()
                        children(node)
                    }
                    Divider()
                    actions(node)
                }
                .padding(SDTheme.Space.md)
            } else {
                Text("No Selection").font(SDTheme.Font.body).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .accessibilityLabel("Inspector")
    }

    private func identity(_ node: ScanNode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                FileTypeIcon(node: node, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name).font(.system(size: 15, weight: .semibold)).lineLimit(3)
                    HStack(spacing: 5) {
                        CategoryDot(category: node.category)
                        Text(node.isPackage ? "Package" : node.isFolder ? "Folder" : node.category.label)
                            .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                    }
                }
            }
            Text(node.path).font(.system(size: 11.5)).foregroundStyle(.secondary)
                .lineLimit(3).truncationMode(.middle).textSelection(.enabled)
        }
    }

    private func size(_ node: ScanNode) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(SDFormat.bytesString(node.logicalBytes)).font(SDTheme.Font.figureSmall)
            Text(SDFormat.exactBytes(node.logicalBytes)).font(SDTheme.Font.secondary).foregroundStyle(.secondary)
            if let alloc = node.allocatedBytes, alloc != node.logicalBytes {
                Text("\(SDFormat.bytesString(alloc)) on disk").font(SDTheme.Font.secondary).foregroundStyle(.secondary)
            }
            if node.hardLinkCount > 1 {
                Text("One of \(node.hardLinkCount) hard links. Trashing this one frees nothing.")
                    .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
            }
        }
    }

    private func facts(_ node: ScanNode) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            GridRow {
                Text("Modified").foregroundStyle(.secondary)
                Text(node.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Unknown")
            }
            if node.isFolder {
                GridRow { Text("Contains").foregroundStyle(.secondary); Text("\(node.childCount.formatted()) items") }
            }
            if node.isCloudPlaceholder {
                GridRow { Text("Status").foregroundStyle(.secondary); Text("Not downloaded") }
            }
            if node.ownedByOthers {
                GridRow { Text("Owner").foregroundStyle(.secondary); Text("Another user or the system") }
            }
            if node.isUnreadable {
                GridRow { Text("Status").foregroundStyle(.secondary); Text("Could not be read") }
            }
        }
        .font(SDTheme.Font.secondary)
    }

    private func children(_ node: ScanNode) -> some View {
        let kids = (app.children(of: node) ?? []).sorted { $0.logicalBytes > $1.logicalBytes }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Largest inside").font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                Spacer()
                if kids.isEmpty {
                    if app.drillScanningID == node.id {
                        ProgressView().controlSize(.mini)
                    } else if hasGrant(node), !node.isCloudPlaceholder {
                        Button("Read") { app.ensureChildren(node) }.buttonStyle(.link).font(SDTheme.Font.secondary)
                    }
                }
            }
            ForEach(kids.prefix(10)) { kid in
                Button {
                    app.inspectedNodeID = kid.id
                } label: {
                    HStack(spacing: 6) {
                        FileTypeIcon(node: kid, size: 14)
                        Text(kid.name).font(SDTheme.Font.secondary).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(SDFormat.bytesString(kid.logicalBytes))
                            .font(SDTheme.Font.secondary.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if kids.count > 10 {
                Button("Show all \(kids.count)") {
                    app.viewMode = .list
                    app.expandedIDs.insert(node.id)
                    if case .location = app.selection {} else if let id = app.activeLocation?.id {
                        app.selection = .location(id)
                    }
                }
                .buttonStyle(.link).font(SDTheme.Font.secondary)
            }
        }
    }

    private func actions(_ node: ScanNode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                app.toggleReview(node, source: "Inspector")
            } label: {
                Text(app.isQueued(node.id) ? "Remove from Review" : "Add to Review").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!app.canReview(node))
            HStack(spacing: 8) {
                Button { actionNotice = app.preview(node) } label: {
                    Label("Quick Look", systemImage: "eye").frame(maxWidth: .infinity)
                }
                .disabled(!hasGrant(node) || node.isCloudPlaceholder)
                Button { actionNotice = app.reveal(node) } label: {
                    Label("Finder", systemImage: "folder").frame(maxWidth: .infinity)
                }
                .disabled(!hasGrant(node))
            }
            .controlSize(.large)
            if let m = actionNotice {
                Text(m).font(SDTheme.Font.secondary).foregroundStyle(.orange)
            }
            if let why = app.reviewBlocker(node) {
                Text(why).font(SDTheme.Font.secondary).foregroundStyle(.secondary)
            } else if !app.hasRealData {
                Text("Sample data. Add a location to work with your own files.")
                    .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
            }
        }
    }
}
