import SwiftUI

// Duplicate review (§F07): identical contents only — metadata, resource
// forks, and app meaning can still differ. One copy per group is always kept:
// group staging leaves the keeper out, and cleanup refuses the last copy.
struct DuplicatesView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: 0) {
            ScreenBar {
                if app.duplicateRunning {
                    Text(progressLine).lineLimit(1)
                } else if !app.duplicateGroups.isEmpty {
                    Text("\(app.duplicateGroups.count) groups, \(SDFormat.bytesString(redundantTotal)) redundant")
                } else {
                    Text(scopeLine)
                }
            } trailing: {
                if app.hasRealData {
                    SearchField(text: $app.searchText, prompt: "Search duplicates")
                    if app.duplicateRunning {
                        Button("Cancel") { app.cancelDuplicates() }
                    } else {
                        Button(app.duplicateGroups.isEmpty ? "Find Duplicates" : "Find Again") {
                            app.duplicateTask = Task { await app.findDuplicates() }
                        }
                        .buttonStyle(.borderedProminent)
                        .help("Reads file contents to compare them. Everything stays on this Mac.")
                    }
                }
            }

            if !app.hasRealData {
                VStack(spacing: 8) {
                    Text("Scan a location first.").font(SDTheme.Font.body)
                    Text("Duplicates are found among the scanned large files. Nothing is uploaded.")
                        .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                    Button("Add Location…") { Task { await app.addLocationFlow() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            if let notice = app.duplicateNotice {
                Text(notice).font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                    .padding(.horizontal, SDTheme.Space.md).padding(.vertical, SDTheme.Space.xs)
            }

            if app.duplicateRunning && app.duplicateGroups.isEmpty {
                VStack(spacing: 12) {
                    if app.duplicateBytesTotal > 0 {
                        ProgressView(value: Double(app.duplicateBytesDone), total: Double(max(app.duplicateBytesTotal, 1)))
                            .progressViewStyle(.linear).frame(width: 320)
                        Text("Comparing contents, \(SDFormat.bytesString(app.duplicateBytesDone)) of up to \(SDFormat.bytesString(app.duplicateBytesTotal))")
                            .font(SDTheme.Font.body)
                    } else {
                        ProgressView()
                        Text("Grouping files by size").font(SDTheme.Font.body)
                    }
                    Text(app.duplicateCurrent ?? "").font(SDTheme.Font.secondary).foregroundStyle(.secondary).lineLimit(1)
                        .frame(maxWidth: 420)
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
            } else if app.viewMode == .sunburst {
                SunburstView(nodes: filteredGroups.flatMap(\.files), rootTitle: "Duplicates")
            } else if app.viewMode != .list {
                TreemapView(nodes: filteredGroups.flatMap(\.files), rootTitle: "Duplicates")
            } else {
                List(selection: Binding(get: { app.selectedIDs }, set: { app.selectedIDs = $0 })) {
                    ForEach(filteredGroups) { group in
                        Section {
                            groupHeader(group)
                            ForEach(group.files) { file in
                                fileRow(file, group: group).tag(file.id)
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
            Text("Redundancy counts logical bytes. Cloned files can share blocks, so the Trash may free less. Identical contents can still mean different things to their apps.")
                .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                .padding(SDTheme.Space.sm)
            }
        }
    }

    // MARK: - Derived

    private var scopeLine: String {
        "Compares the largest files of every scanned location, 1 MB and up"
    }

    private var progressLine: String {
        if app.duplicateBytesTotal > 0 {
            return "Comparing \(app.duplicateChecked) of \(app.duplicateTotal) candidates"
        }
        if app.duplicateTotal > 0 { return "Grouping \(app.duplicateTotal) files by size" }
        return "Starting"
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
                Text("\(app.displayPath(file)), modified \(SDFormat.date(file.modified))")
                    .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            MonospaceBytes(bytes: file.logicalBytes)
        }
        .frame(minHeight: SDTheme.rowHeight)
        .contentShape(Rectangle())
        .contextMenu {
            Button(file.id == keeper ? "Kept copy" : "Keep This Copy") { app.duplicateKeepers[group.id] = file.id }
                .disabled(file.id == keeper)
            Divider()
            NodeContextMenu(node: file, source: "Duplicates")
        }
    }
}
