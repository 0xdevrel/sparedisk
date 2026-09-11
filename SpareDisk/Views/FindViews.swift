import SwiftUI

struct LargeFilesView: View {
    @Environment(AppState.self) private var app
    @AppStorage("largeFilesMinMB") private var thresholdMB = 500

    private var useReal: Bool { app.hasRealData }
    private var combined: [ScanNode] {
        app.scans.values.flatMap(\.largestFiles).sorted { $0.logicalBytes > $1.logicalBytes }
    }
    private var floor: Int64 { Int64(max(0, thresholdMB)) * 1_000_000 }
    private var shown: [ScanNode] {
        let list = useReal ? combined : MockData.largeFiles
        return list.filter { $0.logicalBytes >= floor && (app.searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(app.searchText)) }.prefix(200).map { $0 }
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
            } else {
                List(selection: Binding(get: { app.inspectedNodeID }, set: { app.inspectedNodeID = $0 })) {
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
                            MonospaceBytes(bytes: node.logicalBytes)
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

    private var useReal: Bool { app.hasRealData }
    private var cutoff: Date {
        let m = min(1200, max(0, monthsBack))
        return Calendar.current.date(byAdding: .month, value: -m, to: Date()) ?? .distantPast
    }
    private var shown: [ScanNode] {
        let list = useReal
            ? app.scans.values.flatMap(\.oldestFiles).sorted { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }
            : MockData.olderFiles
        return list.filter { ($0.modified ?? .distantFuture) <= cutoff && (app.searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(app.searchText)) }.prefix(200).map { $0 }
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
            if useReal && shown.isEmpty {
                emptyHint("Nothing this old in the scanned locations.")
            } else {
                List(selection: Binding(get: { app.inspectedNodeID }, set: { app.inspectedNodeID = $0 })) {
                    ForEach(shown) { node in
                        HStack(spacing: 10) {
                            FileTypeIcon(node: node, size: 24)
                            VStack(alignment: .leading) {
                                Text(node.name).font(SDTheme.Font.body)
                                Text("Modified \(SDFormat.date(node.modified)), \(SDFormat.bytesString(node.logicalBytes))")
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
