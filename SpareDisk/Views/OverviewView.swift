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
                    realHeader(loc: loc)
                    if let scan = app.activeScan {
                        if scan.issues.count > 0 {
                            IssueBanner(text: "Scan finished. \(scan.issues.count) folders couldn't be read.")
                        }
                        if app.isScanning { scanningCard } else { capacityCard(loc: loc) }
                        largestCard(nodes: scan.topNodes, total: scan.totalBytes, scopeNote: "\(SDFormat.bytesString(scan.totalBytes)) analyzed · \(scan.itemCount.formatted()) items")
                        entryRow
                    } else if app.isScanning {
                        scanningCard
                    } else {
                        emptyScanCard(loc: loc)
                    }
                } else {
                    firstLaunch
                    // Sample preview so layout/comfort can be judged before any grant.
                    largestCard(nodes: MockData.topLevel, total: MockData.homeTree.logicalBytes, scopeNote: "Sample data — your files are never touched until you choose a folder")
                    entryRow
                }
                if let n = app.notice {
                    Text(n).font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                }
            }
            .padding(SDTheme.Space.lg)
        }
    }

    // MARK: - First launch (§7.6)

    private var firstLaunch: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("See where your space goes.").font(SDTheme.Font.screenTitle)
            Text("Choose a folder to see what's taking up space. Files move only after you review and confirm.")
                .font(SDTheme.Font.body).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Choose a Folder…") { Task { await app.addLocationFlow() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut("o", modifiers: .command)
                if app.isScanning { Button("Cancel") { app.cancelScan() }.buttonStyle(.bordered) }
            }
            if let p = app.scanProgress {
                Text("Scanning · \(p.itemsFound.formatted()) items found · \(Int(p.elapsed))s elapsed")
                    .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
            }
        }
        .padding(SDTheme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private func realHeader(loc: SDLocation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(loc.name).font(SDTheme.Font.screenTitle)
            if let scan = app.activeScan {
                Text("\(SDFormat.bytesString(scan.totalBytes)) analyzed · \(scan.itemCount.formatted()) items · \(scan.finishedAt.formatted(date: .omitted, time: .shortened))")
                    .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
            } else if app.isScanning, let p = app.scanProgress {
                Text("Scanning · \(p.itemsFound.formatted()) items found · \(Int(p.elapsed))s elapsed")
                    .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
            } else {
                Text("Not scanned yet").font(SDTheme.Font.secondary).foregroundStyle(.secondary)
            }
            if !loc.access.isOK {
                Text(loc.access.label).font(SDTheme.Font.secondary).foregroundStyle(.orange)
            }
        }
    }

    private var scanningCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Scanning…")
            if let p = app.scanProgress {
                ProgressView()
                    .progressViewStyle(.linear)
                Text("\(p.itemsFound.formatted()) items found · \(Int(p.elapsed))s elapsed · results appear when the scan finishes.")
                    .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
            }
            Button("Cancel Scan") { app.cancelScan() }.buttonStyle(.bordered).keyboardShortcut(.cancelAction)
        }
        .padding(SDTheme.Space.md)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private func emptyScanCard(loc: SDLocation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: loc.name)
            Text("This location was added but hasn't finished a scan.")
                .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
            Button("Scan Now") { app.rescanActive() }.buttonStyle(.borderedProminent)
        }
        .padding(SDTheme.Space.md)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private func capacityCard(loc: SDLocation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Volume · \(loc.name)")
            if loc.capacityBytes > 0 {
                CapacityBar(used: max(0, loc.capacityBytes - loc.availableBytes), total: loc.capacityBytes, available: loc.availableBytes)
                HStack {
                    Text("Available \(SDFormat.bytesString(loc.availableBytes))").font(SDTheme.Font.secondary)
                    Spacer()
                    Text("Capacity \(SDFormat.bytesString(loc.capacityBytes))").font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                }
            } else {
                Text("Volume capacity isn't available for this location. Analyzed contents below still reflect exactly what was scanned.")
                    .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
            }
            Text("Volume data sampled at scan time. Analyzed contents cover only the locations you chose — never the whole disk by implication.")
                .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
            Button("Why the totals differ") { showTotalsExplanation = true }
                .popover(isPresented: $showTotalsExplanation) { Text("Volume capacity covers the entire volume. Analyzed size covers readable files inside the folder you selected. System files, snapshots, cloud placeholders and other folders can make these totals differ. Logical file sizes also differ from physical disk allocation.").padding(20).frame(width: 340) }.buttonStyle(.link).font(SDTheme.Font.secondary)
        }
        .padding(SDTheme.Space.md)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private func largestCard(nodes: [ScanNode], total: Int64, scopeNote: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Largest locations")
            Text(scopeNote).font(SDTheme.Font.secondary).foregroundStyle(.secondary)
            ForEach(nodes.prefix(8)) { node in
                LargestRow(node: node, total: total)
            }
        }
        .padding(SDTheme.Space.md)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private var entryRow: some View {
        HStack(spacing: 12) {
            EntryCard(title: "Explore contents", sub: "List and Map", symbol: "square.grid.2x2") {
                if let id = app.activeLocation?.id { app.selection = .location(id) } else { Task { await app.addLocationFlow() } }
            }
            EntryCard(title: "Review large files", sub: "> 500 MB", symbol: "doc.text.magnifyingglass") { app.selection = .largeFiles }
            EntryCard(title: "Review older files", sub: "Not modified in 12 mo", symbol: "calendar") { app.selection = .olderFiles }
        }
    }
}

private struct CapacityBar: View {
    let used, total, available: Int64
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(Color.accentColor)
                    .frame(width: geo.size.width * min(1, Double(used) / Double(max(total, 1))))
            }
        }
        .frame(height: 10)
        .accessibilityLabel("Volume used versus available")
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
            HStack(spacing: 12) {
                CategoryDot(category: node.category)
                Text(node.name).font(SDTheme.Font.body).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                SizeBar(fraction: node.share(of: total), category: node.category).frame(width: 64)
                Spacer()
                Text(SDFormat.pct(node.share(of: total))).font(.system(size: 12.5).monospacedDigit()).foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                MonospaceBytes(bytes: node.logicalBytes).frame(width: 90, alignment: .trailing)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(height: SDTheme.rowHeight)
        Divider()
    }
}

private struct EntryCard: View {
    let title, sub, symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: symbol).font(.title2).foregroundStyle(Color.accentColor)
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(sub).font(SDTheme.Font.secondary).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SDTheme.Space.md)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
