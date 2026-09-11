import SwiftUI

// Duplicate review (§F07): identical contents only — metadata, resource
// forks, and app meaning can still differ. One copy per group is always kept:
// group staging leaves the keeper out, and cleanup refuses the last copy.
struct DuplicatesView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Duplicates").font(.system(size: 20, weight: .semibold))
                Text(scopeLine).font(SDTheme.Font.secondary).foregroundStyle(.secondary)
            }
            .padding(.horizontal, SDTheme.Space.md).padding(.vertical, SDTheme.Space.sm)

            if !app.hasRealData {
                VStack(spacing: 8) {
                    Text("Scan a location first.").font(SDTheme.Font.body)
                    Text("Duplicates are compared among scanned large files — never uploaded anywhere.")
                        .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                    Button("Choose a Folder…") { Task { await app.addLocationFlow() } }
                        .buttonStyle(.link)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            HStack(spacing: 8) {
                if app.duplicateRunning {
                    ProgressView().controlSize(.small)
                    Text(progressLine).font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { app.cancelDuplicates() }.buttonStyle(.bordered).controlSize(.small)
                } else {
                    Button(app.duplicateGroups.isEmpty ? "Find Duplicates" : "Find Again") {
                        app.duplicateTask = Task { await app.findDuplicates() }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .help("Reads file contents to compare — extra IO, stays on this Mac")
                    if !app.duplicateGroups.isEmpty {
                        Text("\(app.duplicateGroups.count) groups · \(SDFormat.bytesString(redundantTotal)) logical redundancy")
                            .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, SDTheme.Space.md).padding(.bottom, SDTheme.Space.xs)

            if let notice = app.duplicateNotice {
                Text(notice).font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                    .padding(.horizontal, SDTheme.Space.md).padding(.bottom, SDTheme.Space.xs)
            }

            Divider()

            if app.duplicateRunning && app.duplicateGroups.isEmpty {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Comparing contents…").font(SDTheme.Font.body)
                    Text("Size groups, then samples, then full hashes, then byte confirmation.")
                        .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if app.duplicateGroups.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.on.doc").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("No duplicate groups yet.").font(SDTheme.Font.body)
                    Text("Run a comparison to find identical contents among large files.")
                        .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredGroups) { group in
                        Section {
                            groupHeader(group)
                            ForEach(group.files) { file in
                                fileRow(file, group: group)
                            }
                        }
                    }
                    if !app.duplicateSkips.isEmpty {
                        Section("Skipped") {
                            ForEach(app.duplicateSkips) { s in
                                HStack(spacing: 10) {
                                    Image(systemName: "minus.circle").foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(s.name).font(SDTheme.Font.body)
                                        Text(s.reason).font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(minHeight: SDTheme.rowHeight)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
            Text("Redundancy is logical bytes — clones may share blocks, so Trash may free less. Content equality doesn't mean the files mean the same thing to their apps.")
                .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                .padding(SDTheme.Space.sm)
            }
        }
    }

    // MARK: - Derived

    private var scopeLine: String {
        "Among retained large files (≥1 MB) across \(app.scans.count) scanned location\(app.scans.count == 1 ? "" : "s") — not an exhaustive whole-disk search"
    }

    private var progressLine: String {
        if app.duplicateTotal > 0 {
            return "Compared \(app.duplicateChecked) of \(app.duplicateTotal) · \(app.duplicateCurrent ?? "")"
        }
        return "Starting…"
    }

    private var redundantTotal: Int64 {
        app.duplicateGroups.reduce(0) { $0 + $1.redundantLogicalBytes }
    }

    private var filteredGroups: [DuplicateGroup] {
        guard !app.searchText.isEmpty else { return app.duplicateGroups }
        return app.duplicateGroups.filter { g in
            g.files.contains { $0.name.localizedCaseInsensitiveContains(app.searchText) }
        }
    }

    // MARK: - Rows

    private func groupHeader(_ group: DuplicateGroup) -> some View {
        let keeper = app.duplicateKeepers[group.id] ?? group.files[0].id
        let keeperName = group.files.first(where: { $0.id == keeper })?.name ?? "a copy"
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("\(group.files.count) identical copies · \(SDFormat.bytesString(group.bytesPerFile)) each")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                MonospaceBytes(bytes: group.redundantLogicalBytes)
            }
            HStack(spacing: 8) {
                Menu("Keep: \(keeperName)") {
                    ForEach(group.files) { f in
                        Button(f.name) { app.duplicateKeepers[group.id] = f.id }
                    }
                }
                .menuStyle(.borderlessButton).font(SDTheme.Font.secondary)
                .help("The kept copy never enters review from group staging")
                Button("Stage the Rest for Review") { app.stageGroupExceptKeeper(group) }
                    .buttonStyle(.link).font(SDTheme.Font.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func fileRow(_ file: ScanNode, group: DuplicateGroup) -> some View {
        let keeper = app.duplicateKeepers[group.id] ?? group.files[0].id
        return HStack(spacing: 10) {
            FileTypeIcon(node: file, size: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(file.name).font(SDTheme.Font.body).lineLimit(1)
                    if file.id == keeper {
                        Text("keeper").font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    if app.isQueued(file.id) {
                        Image(systemName: "tray.full.fill").foregroundStyle(Color.accentColor)
                            .help("In Review")
                    }
                }
                Text("\(file.path) · Modified \(SDFormat.date(file.modified))")
                    .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            MonospaceBytes(bytes: file.logicalBytes)
            Button(app.isQueued(file.id) ? "Queued" : "Review") {
                app.toggleReview(file, source: "Duplicates")
                app.inspectedNodeID = file.id
            }
            .buttonStyle(.link).font(SDTheme.Font.secondary)
            .disabled(!app.canReview(file))
        }
        .frame(minHeight: SDTheme.rowHeight)
        .contextMenu {
            Button("Add to Review") { app.toggleReview(file, source: "Duplicates") }
                .disabled(!app.canReview(file))
            Button("Reveal in Finder") { app.reveal(file) }
                .disabled(app.scopeForNode(file) == nil)
        }
    }
}
