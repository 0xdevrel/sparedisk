import SwiftUI

/// Data left behind by apps that are no longer installed, grouped by
/// bundle identifier. Each group can be staged whole; every item still
/// goes through Review and the Trash.
struct LeftoversView: View {
    @Environment(AppState.self) private var app

    private var filtered: [LeftoverGroup] {
        guard !app.searchText.isEmpty else { return app.leftoverGroups }
        return app.leftoverGroups.filter { g in
            g.bundleID.localizedCaseInsensitiveContains(app.searchText)
                || g.items.contains { $0.name.localizedCaseInsensitiveContains(app.searchText) }
        }
    }

    /// Charts show each app's leftovers as one unit holding its items.
    private var groupNodes: [ScanNode] {
        filtered.map { g in
            ScanNode(id: "leftover:\(g.bundleID)", name: g.displayName, path: "", isFolder: true, category: .system,
                     logicalBytes: g.bytes, modified: g.newestChange, childCount: g.items.count, children: g.items)
        }
    }

    var body: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: 0) {
            ScreenBar {
                if app.leftoverRunning {
                    ProgressView().controlSize(.small)
                    Text("Reading your Library…")
                    Button("Cancel") { app.cancelLeftovers() }.buttonStyle(.link)
                } else if let n = app.leftoverNotice {
                    Text(n)
                } else if app.homeLocation == nil {
                    Text("Add your home folder first. Leftovers live under its Library.")
                } else {
                    Text("Library entries named after an app identifier that no installed app claims.")
                }
            } trailing: {
                SearchField(text: $app.searchText, prompt: "Search leftovers")
                if !app.leftoverGroups.isEmpty {
                    let all = filtered.flatMap(\.items).filter { app.canReview($0) }
                    Button("Move All to Trash…") { app.requestTrash(all) }
                        .disabled(all.isEmpty || app.cleanupRunning)
                        .help("Checked again, then moved to the Trash after you confirm")
                }
                Button(app.leftoverGroups.isEmpty ? "Find Leftovers" : "Find Again") { app.findLeftovers() }
                    .buttonStyle(.borderedProminent)
                    .disabled(app.homeLocation == nil || app.leftoverRunning)
            }
            if app.leftoverGroups.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "app.dashed").font(.largeTitle).foregroundStyle(.tertiary)
                    Text(app.leftoverRunning ? "Looking for data without an app…" : "No leftovers listed yet.").font(SDTheme.Font.body)
                    Text("Containers, caches, preferences and saved state whose app is gone. Apple's own identifiers are not shown. Moving to the Trash asks first and checks each item again.")
                        .font(SDTheme.Font.secondary).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if app.viewMode == .sunburst {
                SunburstView(nodes: groupNodes, rootTitle: "Leftovers")
            } else if app.viewMode != .list {
                TreemapView(nodes: groupNodes, rootTitle: "Leftovers")
            } else {
                List(selection: Binding(get: { app.selectedIDs }, set: { app.selectedIDs = $0 })) {
                    ForEach(filtered) { g in
                        Section {
                            ForEach(g.items) { n in
                                HStack(spacing: 10) {
                                    FileTypeIcon(node: n, size: 22)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(n.name).font(SDTheme.Font.body).lineLimit(1)
                                        Text("\(app.leftoverKinds[n.path] ?? "Item"), \(app.displayPath(n)), modified \(SDFormat.date(n.modified))")
                                            .font(SDTheme.Font.secondary).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    }
                                    if app.isQueued(n.id) {
                                        Image(systemName: "tray.full").foregroundStyle(Color.accentColor).help("In Review")
                                    }
                                    Spacer()
                                    MonospaceBytes(bytes: app.bytes(n))
                                }
                                .frame(minHeight: SDTheme.rowHeight)
                                .contentShape(Rectangle())
                                .contextMenu { NodeContextMenu(node: n, source: "Leftovers") }
                                .tag(n.id)
                            }
                        } header: {
                            HStack(alignment: .firstTextBaseline) {
                                Text(g.displayName).font(.system(size: 13, weight: .semibold))
                                Text(g.bundleID).font(SDTheme.Font.secondary).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                                Text("\(g.items.count) \(g.items.count == 1 ? "item" : "items"), \(SDFormat.bytesString(g.bytes))")
                                    .font(SDTheme.Font.secondary.monospacedDigit()).foregroundStyle(.secondary)
                                Button("Move to Trash…") { app.requestTrash(g.items) }
                                    .buttonStyle(.link).font(SDTheme.Font.secondary)
                                    .help("Checked again, then moved to the Trash after you confirm")
                                    .disabled(!g.items.contains { app.canReview($0) } || app.cleanupRunning)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
            if !app.leftoverGroups.isEmpty {
                Divider()
                Text("No installed app claims these identifiers. Command-line tools and apps outside the usual folders can still own some of them, so check the name before moving anything.")
                    .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                    .padding(.horizontal, SDTheme.Space.md).padding(.vertical, 6)
            }
        }
    }
}
