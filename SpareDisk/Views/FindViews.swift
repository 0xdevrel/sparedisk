import SwiftUI

struct LargeFilesView: View {
    @Environment(AppState.self) private var app
    @State private var thresholdMB = "500"

    private var useReal: Bool { app.hasRealData }
    private var combined: [ScanNode] {
        app.scans.values.flatMap(\.largestFiles).sorted { $0.logicalBytes > $1.logicalBytes }
    }
    private var floor: Int64 {
        guard let value = Double(thresholdMB), value.isFinite, value >= 0, value < Double(Int64.max) / 1_000_000 else { return Int64.max }
        return Int64(value * 1_000_000)
    }
    private var shown: [ScanNode] {
        let list = useReal ? combined : MockData.largeFiles
        return list.filter { $0.logicalBytes >= floor && (app.searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(app.searchText)) }.prefix(200).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(title: "Large Files",
                   sub: useReal ? "Files only · across \(app.scans.count) scanned location\(app.scans.count == 1 ? "" : "s") · packages count as units in Browse"
                                : "Sample · descending by size · scope Home folder")
            filterBar(threshold: $thresholdMB, extra: "Minimum size (MB)")
            if useReal && shown.isEmpty {
                emptyHint("No files above this size in the scanned locations.")
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
                                Image(systemName: "icloud").foregroundStyle(.secondary).help("Cloud placeholder — excluded from bulk removal")
                            }
                            Spacer()
                            MonospaceBytes(bytes: node.logicalBytes)
                            Button(app.isQueued(node.id) ? "Queued" : "Add to Review") {
                                app.toggleReview(node, source: "Large Files")
                                app.inspectedNodeID = node.id
                            }.buttonStyle(.link).disabled(!app.canReview(node))
                        }
                        .frame(minHeight: SDTheme.rowHeight)
                        .tag(node.id)
                    }
                }.listStyle(.inset)
            }
        }
    }
}

struct OlderFilesView: View {
    @Environment(AppState.self) private var app
    @State private var monthsBack = "12"

    private var useReal: Bool { app.hasRealData }
    private var cutoff: Date {
        let m = min(1200, max(0, Int(monthsBack) ?? 12))
        return Calendar.current.date(byAdding: .month, value: -m, to: Date()) ?? .distantPast
    }
    private var shown: [ScanNode] {
        let list = useReal
            ? app.scans.values.flatMap(\.oldestFiles).sorted { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }
            : MockData.olderFiles
        return list.filter { ($0.modified ?? .distantFuture) <= cutoff && (app.searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(app.searchText)) }.prefix(200).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(title: "Older Files", sub: useReal ? "By modification date · review before removing" : "Sample data · not your files")
            filterBar(threshold: $monthsBack, extra: "Not modified in (months)")
            if useReal && shown.isEmpty {
                emptyHint("Nothing this old in the scanned locations.")
            } else {
                List(selection: Binding(get: { app.inspectedNodeID }, set: { app.inspectedNodeID = $0 })) {
                    ForEach(shown) { node in
                        HStack(spacing: 10) {
                            FileTypeIcon(node: node, size: 24)
                            VStack(alignment: .leading) {
                                Text(node.name).font(SDTheme.Font.body)
                                Text("Modified \(SDFormat.date(node.modified)) · \(SDFormat.bytesString(node.logicalBytes))")
                                    .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(app.isQueued(node.id) ? "Queued" : "Add to Review") {
                                app.toggleReview(node, source: "Older Files")
                                app.inspectedNodeID = node.id
                            }.buttonStyle(.link).disabled(!app.canReview(node))
                        }
                        .frame(minHeight: SDTheme.rowHeight)
                        .tag(node.id)
                    }
                }.listStyle(.inset)
            }
            Text(useReal
                 ? "Age uses modification date only. Files without dates aren't ranked — they appear in Browse with an Unknown label."
                 : "Age uses modification date only. A directory's date is not the age of its descendants.")
                .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                .padding(SDTheme.Space.sm)
        }
    }
}

private func header(title: String, sub: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.system(size: 20, weight: .semibold))
        Text(sub).font(SDTheme.Font.secondary).foregroundStyle(.secondary)
    }
    .padding(.horizontal, SDTheme.Space.md).padding(.vertical, SDTheme.Space.sm)
}

private func filterBar(threshold: Binding<String>, extra: String) -> some View {
    HStack(spacing: 8) {
        Text(extra).font(SDTheme.Font.secondary).foregroundStyle(.secondary)
        TextField("Threshold", text: threshold).textFieldStyle(.roundedBorder).frame(width: 160)
        Spacer()
        Text("Up to 200 retained results").font(SDTheme.Font.secondary).foregroundStyle(.secondary)
    }
    .padding(.horizontal, SDTheme.Space.md).padding(.bottom, SDTheme.Space.xs)
}

private func emptyHint(_ text: String) -> some View {
    VStack(spacing: 8) {
        Text("No files match these filters.").font(SDTheme.Font.body)
        Text(text).font(SDTheme.Font.secondary).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}
