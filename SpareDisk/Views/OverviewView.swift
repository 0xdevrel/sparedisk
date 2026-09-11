import SwiftUI

struct OverviewView: View {
    @Environment(AppState.self) private var app
    @State private var showTotalsExplanation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SDTheme.Space.lg) {
                if let err = app.scanError {
                    IssueBanner(text: err)
                }
                if app.hasRealData, let loc = app.activeLocation {
                    header(loc: loc)
                    if let scan = app.activeScan {
                        if scan.issues.count > 0 {
                            IssueBanner(text: "\(scan.issues.count) folders could not be read.")
                        }
                        capacity(loc: loc)
                        largest(nodes: scan.topNodes, total: scan.totalBytes)
                    } else if app.isScanning, let p = app.scanProgress, app.scanningLocationID == loc.id {
                        scanning(progress: p)
                        if !p.partialTop.isEmpty {
                            largest(nodes: p.partialTop, total: max(p.partialBytes, 1))
                        }
                    } else {
                        notScanned(loc: loc)
                    }
                } else {
                    firstLaunch
                    largest(nodes: MockData.topLevel, total: MockData.homeTree.logicalBytes)
                }
                if let n = app.notice {
                    Text(n).font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SDTheme.Space.lg)
        }
    }

    // MARK: - First launch (§7.6)

    private var firstLaunch: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("See where your space goes.").font(SDTheme.Font.screenTitle)
            Text("Add a folder to analyze. Nothing moves until you review it and confirm.")
                .font(SDTheme.Font.body).foregroundStyle(.secondary)
            Button("Add Location…") { Task { await app.addLocationFlow() } }
                .buttonStyle(.borderedProminent).keyboardShortcut("o", modifiers: .command)
            Text("Sample data is shown below until then.")
                .font(SDTheme.Font.secondary).foregroundStyle(.tertiary)
        }
    }

    private func header(loc: SDLocation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(loc.name).font(SDTheme.Font.screenTitle)
                Spacer()
                if app.locations.count > 1 {
                    Picker("Location", selection: Binding(get: { app.activeLocationID }, set: { app.activeLocationID = $0 })) {
                        ForEach(app.locations) { l in Text(l.name).tag(l.id) }
                    }
                    .labelsHidden().frame(maxWidth: 220)
                }
            }
            HStack(spacing: 12) {
                if let scan = app.activeScan {
                    Text("\(SDFormat.bytesString(scan.totalBytes)) in \(scan.itemCount.formatted()) items, scanned \(scan.finishedAt.formatted(.relative(presentation: .named)))")
                        .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                        .help("Logical size. \(SDFormat.bytesString(scan.totalAllocated)) is occupied on disk.")
                    Button("Explore", systemImage: "square.grid.2x2") { app.selection = .location(loc.id) }
                    Button("Large Files", systemImage: "doc.text.magnifyingglass") { app.selection = .largeFiles }
                    Button("Older Files", systemImage: "calendar") { app.selection = .olderFiles }
                }
            }
            .buttonStyle(.link).font(SDTheme.Font.secondary)
            if !loc.access.isOK {
                Text(loc.access.label).font(SDTheme.Font.secondary).foregroundStyle(.orange)
            }
        }
    }

    private func scanning(progress p: ScanProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Scanning, \(p.itemsFound.formatted()) items so far")
                    .font(SDTheme.Font.body)
                Spacer()
                Button("Cancel") { app.cancelScan() }.controlSize(.small).keyboardShortcut(.cancelAction)
            }
            if !p.currentPath.isEmpty {
                Text(p.currentPath).font(SDTheme.Font.secondary).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
    }

    private func notScanned(loc: SDLocation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Not scanned yet.").font(SDTheme.Font.body).foregroundStyle(.secondary)
            Button("Scan Now") { app.rescanActive() }.buttonStyle(.borderedProminent)
        }
    }

    private func capacity(loc: SDLocation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Volume")
            if loc.capacityBytes > 0 {
                let used = max(0, loc.capacityBytes - loc.availableBytes)
                CapacityBar(used: used, total: loc.capacityBytes)
                HStack {
                    Text("\(SDFormat.bytesString(used)) used").font(SDTheme.Font.secondary)
                    Spacer()
                    Text("\(SDFormat.bytesString(loc.availableBytes)) available of \(SDFormat.bytesString(loc.capacityBytes))")
                        .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                }
                if let scan = app.activeScan, scan.totalAllocated > 0 {
                    HStack(spacing: 4) {
                        Text("This folder occupies \(SDFormat.bytesString(scan.totalAllocated)) on disk, \(SDFormat.pct(Double(scan.totalAllocated) / Double(loc.capacityBytes))) of the volume.")
                            .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                        Button("Why the totals differ") { showTotalsExplanation = true }
                            .buttonStyle(.link).font(SDTheme.Font.secondary)
                            .popover(isPresented: $showTotalsExplanation) {
                                Text("File sizes in the list are logical sizes: what the files would hold if fully downloaded and uncompressed. On-disk space is what they actually occupy. Cloud files that are not downloaded, sparse files and cloned files take less space than their size suggests. The rest of the volume is used by other folders, system files and snapshots.")
                                    .font(SDTheme.Font.secondary).padding(16).frame(width: 320)
                            }
                    }
                }
            } else {
                Text("Volume capacity is not available for this location.")
                    .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
            }
        }
    }

    private func largest(nodes: [ScanNode], total: Int64) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Largest items")
            ForEach(nodes.prefix(10)) { node in
                LargestRow(node: node, total: total)
            }
            if nodes.count > 10, let id = app.activeLocation?.id, app.hasRealData {
                Button("Show all \(nodes.count) items") { app.selection = .location(id) }
                    .buttonStyle(.link).font(SDTheme.Font.secondary).padding(.top, 8)
            }
        }
    }
}

private struct CapacityBar: View {
    let used, total: Int64
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.10))
                RoundedRectangle(cornerRadius: 3).fill(Color.accentColor)
                    .frame(width: geo.size.width * min(1, Double(used) / Double(max(total, 1))))
            }
        }
        .frame(height: 12)
        .accessibilityLabel("\(SDFormat.bytesString(used)) used of \(SDFormat.bytesString(total))")
    }
}

private struct LargestRow: View {
    @Environment(AppState.self) private var app
    let node: ScanNode
    let total: Int64
    var body: some View {
        Button {
            app.inspectedNodeID = node.id
        } label: {
            HStack(spacing: 10) {
                FileTypeIcon(node: node, size: 18)
                Text(node.name).font(SDTheme.Font.body).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                SizeBar(fraction: node.share(of: total), category: node.category).frame(width: 80)
                Text(SDFormat.pct(node.share(of: total))).font(.system(size: 12.5).monospacedDigit()).foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                MonospaceBytes(bytes: node.logicalBytes).frame(width: 90, alignment: .trailing)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(height: SDTheme.rowHeight)
        .background(app.inspectedNodeID == node.id ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contextMenu { NodeContextMenu(node: node, source: "Overview") }
        Divider()
    }
}
