import Charts
import SwiftUI

struct LargeFilesView: View {
    @Environment(AppState.self) private var app
    @AppStorage("largeFilesMinMB") private var thresholdMB = 500

    private var useReal: Bool { app.hasRealData }
    private var combined: [ScanNode] {
        app.scans.values.flatMap(\.largestFiles).sorted { app.bytes($0) > app.bytes($1) }
    }
    private var floor: Int64 { Int64(max(0, thresholdMB)) * 1_000_000 }
    private var shown: [ScanNode] {
        let list = useReal ? combined : MockData.largeFiles
        return list.filter { app.bytes($0) >= floor && (app.searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(app.searchText)) }.prefix(200).map { $0 }
    }

    var body: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: 0) {
            ScreenBar {
                Text(useReal ? "The 200 largest files from each scanned location" : "Sample data")
            } trailing: {
                Picker("Larger than", selection: $thresholdMB) {
                    Text("100 MB").tag(100)
                    Text("500 MB").tag(500)
                    Text("1 GB").tag(1000)
                    Text("5 GB").tag(5000)
                }
                .frame(width: 170)
                SearchField(text: $app.searchText, prompt: "Search large files")
            }
            if useReal && shown.isEmpty {
                emptyHint("No files this large in the scanned locations.")
            } else if app.viewMode == .map {
                TreemapView(nodes: shown, rootTitle: "Large Files")
            } else {
                List(selection: Binding(get: { app.selectedIDs }, set: { app.selectedIDs = $0 })) {
                    ForEach(shown) { node in
                        HStack(spacing: 10) {
                            FileTypeIcon(node: node, size: 24)
                            VStack(alignment: .leading) {
                                Text(node.name).font(SDTheme.Font.body)
                                Text(node.path).font(SDTheme.Font.secondary).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            if node.isCloudPlaceholder {
                                Image(systemName: "icloud").foregroundStyle(.secondary).help("Not downloaded")
                            }
                            if app.isQueued(node.id) {
                                Image(systemName: "tray.full").foregroundStyle(Color.accentColor).help("In Review")
                            }
                            Spacer()
                            if app.hasDiskHint(node) {
                                Text("\(SDFormat.bytesString(node.allocatedBytes ?? 0)) on disk")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                    .help("Sparse, cloned or not downloaded: occupies less than its size")
                            }
                            MonospaceBytes(bytes: app.bytes(node))
                        }
                        .frame(minHeight: SDTheme.rowHeight)
                        .contentShape(Rectangle())
                        .contextMenu { NodeContextMenu(node: node, source: "Large Files") }
                        .tag(node.id)
                    }
                }.listStyle(.inset)
            }
        }
    }
}

struct OlderFilesView: View {
    @Environment(AppState.self) private var app
    @AppStorage("olderFilesMonths") private var monthsBack = 12
    @State private var yearFilter: Int?

    private var useReal: Bool { app.hasRealData }
    private var cutoff: Date {
        let m = min(1200, max(0, monthsBack))
        return Calendar.current.date(byAdding: .month, value: -m, to: Date()) ?? .distantPast
    }
    private var candidates: [ScanNode] {
        useReal
            ? app.scans.values.flatMap(\.oldestFiles).sorted { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }
            : MockData.olderFiles
    }
    private var shown: [ScanNode] {
        candidates.filter {
            ($0.modified ?? .distantFuture) <= cutoff
                && (yearFilter == nil || $0.modified.map { Calendar.current.component(.year, from: $0) } == yearFilter)
                && (app.searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(app.searchText))
        }.prefix(200).map { $0 }
    }

    /// Bytes per modification year among the retained oldest files.
    private var byYear: [(year: Int, bytes: Int64, count: Int)] {
        var acc: [Int: (Int64, Int)] = [:]
        for n in candidates where (n.modified ?? .distantFuture) <= cutoff {
            guard let m = n.modified else { continue }
            let y = Calendar.current.component(.year, from: m)
            acc[y, default: (0, 0)].0 += app.bytes(n)
            acc[y, default: (0, 0)].1 += 1
        }
        return acc.keys.sorted().map { (year: $0, bytes: acc[$0]!.0, count: acc[$0]!.1) }
    }

    var body: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: 0) {
            ScreenBar {
                Text(useReal ? "The 200 oldest files from each scanned location, by modification date" : "Sample data")
            } trailing: {
                Picker("Not modified in", selection: $monthsBack) {
                    Text("6 months").tag(6)
                    Text("1 year").tag(12)
                    Text("2 years").tag(24)
                    Text("5 years").tag(60)
                }
                .frame(width: 190)
                SearchField(text: $app.searchText, prompt: "Search older files")
            }
            if byYear.count > 1 {
                AgeChart(data: byYear, selected: $yearFilter)
                    .padding(.horizontal, SDTheme.Space.md).padding(.vertical, SDTheme.Space.sm)
                Divider()
            }
            if useReal && shown.isEmpty {
                emptyHint("Nothing this old in the scanned locations.")
            } else if app.viewMode == .map {
                TreemapView(nodes: shown, rootTitle: "Older Files")
            } else {
                List(selection: Binding(get: { app.selectedIDs }, set: { app.selectedIDs = $0 })) {
                    ForEach(shown) { node in
                        HStack(spacing: 10) {
                            FileTypeIcon(node: node, size: 24)
                            VStack(alignment: .leading) {
                                Text(node.name).font(SDTheme.Font.body)
                                Text("Modified \(SDFormat.date(node.modified)), \(SDFormat.bytesString(app.bytes(node)))")
                                    .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                            }
                            if app.isQueued(node.id) {
                                Image(systemName: "tray.full").foregroundStyle(Color.accentColor).help("In Review")
                            }
                            Spacer()
                        }
                        .frame(minHeight: SDTheme.rowHeight)
                        .contentShape(Rectangle())
                        .contextMenu { NodeContextMenu(node: node, source: "Older Files") }
                        .tag(node.id)
                    }
                }.listStyle(.inset)
            }
        }
    }
}

private func emptyHint(_ text: String) -> some View {
    VStack(spacing: 8) {
        Text(text).font(SDTheme.Font.body).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}

/// Bytes by modification year. Click a bar to filter the list to that year.
private struct AgeChart: View {
    let data: [(year: Int, bytes: Int64, count: Int)]
    @Binding var selected: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("By year modified").font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                Spacer()
                if let y = selected {
                    Button("Showing \(String(y)). Clear") { selected = nil }
                        .buttonStyle(.link).font(SDTheme.Font.secondary)
                } else {
                    Text("Click a year to filter").font(SDTheme.Font.secondary).foregroundStyle(.tertiary)
                }
            }
            Chart(data, id: \.year) { item in
                BarMark(x: .value("Year", String(item.year)), y: .value("Size", item.bytes))
                    .foregroundStyle(selected == nil || selected == item.year ? Color.accentColor : Color.accentColor.opacity(0.3))
                    .cornerRadius(3)
                    .annotation(position: .top, spacing: 2) {
                        Text(SDFormat.bytesString(item.bytes))
                            .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                    }
            }
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks { _ in AxisValueLabel().font(.system(size: 11)) }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onTapGesture { location in
                            let origin = geo[proxy.plotFrame!].origin
                            let x = location.x - origin.x
                            if let label: String = proxy.value(atX: x), let year = Int(label) {
                                selected = selected == year ? nil : year
                            }
                        }
                }
            }
            .frame(height: 110)
        }
    }
}
