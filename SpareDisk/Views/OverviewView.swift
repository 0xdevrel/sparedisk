import SwiftUI

// Overview: the whole storage picture. The volume with each analyzed
// location as a segment, then every location with its own scan control,
// then a map of the largest scanned location and the biggest files.
struct OverviewView: View {
    @Environment(AppState.self) private var app
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openWindow) private var openWindow
    @State private var showTotalsExplanation = false

    private var scanned: [SDLocation] { app.locations.filter { app.scans[$0.id] != nil } }
    private var volume: SDLocation? { app.locations.first(where: { $0.capacityBytes > 0 }) }
    private var featured: SDLocation? {
        scanned.max { (app.scans[$0.id]?.totalAllocated ?? 0) < (app.scans[$1.id]?.totalAllocated ?? 0) }
    }
    private var biggestFiles: [ScanNode] {
        Array(app.scans.values.flatMap(\.largestFiles).sorted { app.bytes($0) > app.bytes($1) }.prefix(8))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SDTheme.Space.xl) {
                if let err = app.scanError { IssueBanner(text: err) }
                if app.hasRealData {
                    volumeSection
                    locationsSection
                    if let f = featured, let scan = app.scans[f.id] { mapSection(location: f, scan: scan) }
                    if !biggestFiles.isEmpty { filesSection }
                } else {
                    firstLaunch
                }
                if let n = app.notice {
                    Text(n).font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: app.hasRealData ? .leading : .center)
            .padding(.horizontal, SDTheme.Space.lg)
            .padding(.vertical, SDTheme.Space.lg)
        }
    }

    // MARK: - First launch

    private var firstLaunch: some View {
        VStack(spacing: SDTheme.Space.lg) {
            VStack(spacing: 8) {
                Text("See where your space goes.").font(SDTheme.Font.screenTitle)
                Text("Pick what to analyze. SpareDisk maps what is inside, and nothing moves until you review it and confirm.")
                    .font(SDTheme.Font.body).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            HStack(spacing: 14) {
                StartCard(symbol: "house", title: "Home Folder",
                          detail: "Desktop, Documents, Downloads and Library in one step.",
                          prominent: true) { Task { await app.addHomeFolderFlow() } }
                StartCard(symbol: "square.grid.3x3", title: "Applications",
                          detail: "Installed apps and what each one takes.") { Task { await app.addApplicationsFlow() } }
                StartCard(symbol: "folder", title: "Other Folders",
                          detail: "Any folder or external drive. Pick several at once.") { Task { await app.addLocationFlow() } }
            }
            .frame(maxWidth: 720)
            Text("macOS asks once before a protected folder is read. Nothing leaves this Mac.")
                .font(SDTheme.Font.secondary).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 72)
    }

    // MARK: - Volume

    private var volumeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let v = volume, v.capacityBytes > 0 {
                let used = max(0, v.capacityBytes - v.availableBytes)
                HStack(alignment: .firstTextBaseline) {
                    Text("\(SDFormat.bytesString(used)) used").font(SDTheme.Font.figure)
                    Spacer()
                    Text("\(SDFormat.bytesString(v.availableBytes)) available of \(SDFormat.bytesString(v.capacityBytes))")
                        .font(SDTheme.Font.body).foregroundStyle(.secondary)
                }
                SegmentedCapacityBar(segments: segments(capacity: v.capacityBytes, used: used), capacity: v.capacityBytes)
                    .frame(height: 14)
                HStack(spacing: 14) {
                    ForEach(Array(scanned.enumerated()), id: \.element.id) { i, loc in
                        legend(color: SDTheme.hue(i, scheme: scheme), name: loc.name)
                    }
                    legend(color: Color.primary.opacity(0.28), name: "Other")
                    Spacer()
                    Button("Why the totals differ") { showTotalsExplanation = true }
                        .buttonStyle(.link).font(SDTheme.Font.secondary)
                        .popover(isPresented: $showTotalsExplanation) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Segments show what each scanned folder occupies on disk. Folders may overlap when one contains another. Other covers everything outside the scanned folders: system files, other users, snapshots, and files not yet downloaded.")
                                    .font(SDTheme.Font.secondary)
                                Button("More in Help") { showTotalsExplanation = false; openWindow(id: "help") }
                                    .buttonStyle(.link).font(SDTheme.Font.secondary)
                            }
                            .padding(16).frame(width: 320)
                        }
                }
                .font(SDTheme.Font.secondary)
            } else {
                Text("Volume capacity is not available for these locations.")
                    .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
            }
        }
    }

    private func segments(capacity: Int64, used: Int64) -> [SegmentedCapacityBar.Segment] {
        var out: [SegmentedCapacityBar.Segment] = []
        var accounted: Int64 = 0
        // Skip a location nested inside an already-counted one so bytes are not drawn twice.
        var counted: [String] = []
        for (i, loc) in scanned.enumerated() {
            let bytes = app.scans[loc.id].map(diskBytes) ?? 0
            let nested = counted.contains { CleanupService.isWithin(loc.id, root: $0) }
            if !nested {
                out.append(.init(id: loc.id, bytes: bytes, color: SDTheme.hue(i, scheme: scheme)))
                accounted += bytes
            }
            counted.append(loc.id)
        }
        out.append(.init(id: "__other", bytes: max(0, used - accounted), color: Color.primary.opacity(0.22)))
        return out
    }

    private func legend(color: Color, name: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(name).foregroundStyle(.secondary).lineLimit(1)
        }
        .fixedSize()
    }

    /// On-disk bytes for a scan, falling back to logical size for results
    /// saved before allocation was tracked.
    private func diskBytes(_ scan: ScanResult) -> Int64 {
        scan.totalAllocated > 0 ? scan.totalAllocated : scan.totalBytes
    }

    // MARK: - Locations

    private var locationsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Locations")
            ForEach(Array(app.locations.enumerated()), id: \.element.id) { i, loc in
                LocationRow(location: loc, color: SDTheme.hue(scanned.firstIndex(where: { $0.id == loc.id }) ?? i, scheme: scheme))
                if loc.id != app.locations.last?.id { Divider() }
            }
            Button("Add Location…", systemImage: "plus") { Task { await app.addLocationFlow() } }
                .buttonStyle(.link).font(SDTheme.Font.secondary)
                .padding(.top, 10)
        }
    }

    // MARK: - Map

    private func mapSection(location: SDLocation, scan: ScanResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "Map of \(location.name)")
                Spacer()
                Button("Open") {
                    app.viewMode = .map
                    app.selection = .location(location.id)
                }
                .buttonStyle(.link).font(SDTheme.Font.secondary)
            }
            TreemapView(nodes: scan.topNodes, embedded: true)
                .frame(height: 300)
                .onAppear { if app.activeLocationID != location.id { app.activeLocationID = location.id } }
        }
    }

    // MARK: - Files

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "Largest files")
                Spacer()
                Button("See all") { app.selection = .largeFiles }
                    .buttonStyle(.link).font(SDTheme.Font.secondary)
            }
            ForEach(biggestFiles) { node in
                Button {
                    app.inspectedNodeID = node.id
                } label: {
                    HStack(spacing: 10) {
                        FileTypeIcon(node: node, size: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(node.name).font(SDTheme.Font.body).lineLimit(1)
                            Text(node.path).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if app.hasDiskHint(node) {
                            Text("\(SDFormat.bytesString(node.allocatedBytes ?? 0)) on disk")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        MonospaceBytes(bytes: app.bytes(node)).frame(width: 90, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(height: SDTheme.rowHeight + 6)
                .background(app.inspectedNodeID == node.id ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contextMenu { NodeContextMenu(node: node, source: "Overview") }
                if node.id != biggestFiles.last?.id { Divider() }
            }
        }
    }
}

// MARK: - Pieces

struct SegmentedCapacityBar: View {
    struct Segment: Identifiable {
        let id: String
        var bytes: Int64
        var color: Color
    }
    let segments: [Segment]
    let capacity: Int64

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1.5) {
                ForEach(segments) { seg in
                    let w = geo.size.width * CGFloat(Double(seg.bytes) / Double(max(capacity, 1)))
                    if w >= 1 {
                        Rectangle().fill(seg.color).frame(width: w)
                    }
                }
                Spacer(minLength: 0)
            }
            .background(Color.primary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .accessibilityLabel("Volume usage by location")
    }
}

private struct LocationRow: View {
    @Environment(AppState.self) private var app
    let location: SDLocation
    let color: Color

    private var scan: ScanResult? { app.scans[location.id] }
    private var scanning: Bool { app.isScanning && app.scanningLocationID == location.id }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3).fill(scan == nil ? Color.primary.opacity(0.15) : color).frame(width: 10, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(location.name).font(.system(size: 14, weight: .medium))
                Text(detail).font(SDTheme.Font.secondary).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let scan {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(SDFormat.bytesString(scan.totalAllocated > 0 ? scan.totalAllocated : scan.totalBytes))
                        .font(.system(size: 14, weight: .medium).monospacedDigit())
                    Text(scan.totalAllocated > 0 ? "on disk" : "logical").font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                }
                .frame(width: 100, alignment: .trailing)
            }
            if scanning {
                ProgressView().controlSize(.small).frame(width: 90)
            } else if scan == nil {
                Button("Scan") { app.activeLocationID = location.id; app.rescanActive() }
                    .buttonStyle(.borderedProminent).frame(width: 90)
            } else {
                Button("Open") { app.selection = .location(location.id) }
                    .frame(width: 90)
            }
        }
        .frame(height: 56)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { app.selection = .location(location.id) }
        .contextMenu {
            Button("Open") { app.selection = .location(location.id) }
            Button("Rescan") { app.activeLocationID = location.id; app.rescanActive() }.disabled(scanning)
            Divider()
            Button("Forget Location…", role: .destructive) { app.forgetLocation(id: location.id) }
        }
    }

    private var detail: String {
        if scanning, let p = app.scanProgress { return "Scanning, \(p.itemsFound.formatted()) items" }
        if let scan {
            var s = "\(scan.itemCount.formatted()) items, scanned \(scan.finishedAt.formatted(.relative(presentation: .named)))"
            if !scan.issues.isEmpty { s += ", \(scan.issues.count) unreadable" }
            if let d = app.changes(for: location.id), d.bytesDelta != 0 {
                s += ", \(d.bytesDelta > 0 ? "+" : "−")\(SDFormat.bytesString(abs(d.bytesDelta))) since last scan"
            }
            return s
        }
        if !location.access.isOK { return location.access.label }
        return location.id
    }
}

/// One of three equal starting choices on first launch.
private struct StartCard: View {
    let symbol: String
    let title: String
    let detail: String
    var prominent = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(prominent ? Color.accentColor : .secondary)
                    .frame(height: 28)
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail).font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                Text(prominent ? "Analyze" : "Choose…")
                    .font(SDTheme.Font.secondary.weight(.medium))
                    .foregroundStyle(prominent ? Color.accentColor : .primary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(hovered ? 1 : 0.7), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(prominent ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.10), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("\(title). \(detail)")
    }
}
