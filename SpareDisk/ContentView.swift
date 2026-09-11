import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var app
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    private var isBrowsing: Bool {
        if case .location = app.selection { return true }
        return false
    }

    private var title: String {
        switch app.selection {
        case .overview: "Overview"
        case .location: app.activeLocation?.name ?? "Location"
        case .largeFiles: "Large Files"
        case .olderFiles: "Older Files"
        case .duplicates: "Duplicates"
        case .review: "Review Cleanup"
        }
    }

    private var subtitle: String {
        switch app.selection {
        case .location(let id):
            if let scan = app.scans[id] {
                return "\(SDFormat.bytesString(scan.totalBytes)), \(scan.itemCount.formatted()) items"
            }
            if app.scanningLocationID == id, let p = app.scanProgress {
                return "Scanning, \(p.itemsFound.formatted()) items"
            }
            return "Not scanned"
        case .overview:
            let scanned = app.locations.filter { app.scans[$0.id] != nil }.count
            return app.locations.isEmpty ? "" : "\(scanned) of \(app.locations.count) locations scanned"
        case .review:
            return app.reviewPlan.isEmpty ? "" : "\(app.reviewPlan.count) items, \(SDFormat.bytesString(app.reviewPlanBytes))"
        case .duplicates:
            return app.duplicateGroups.isEmpty ? "" : "\(app.duplicateGroups.count) groups"
        default:
            return ""
        }
    }

    var body: some View {
        @Bindable var app = app
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 260)
        } detail: {
            CenterView()
        }
        .inspector(isPresented: $app.showInspector) {
            InspectorView()
                .inspectorColumnWidth(min: 280, ideal: 300, max: 340)
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button("Back", systemImage: "chevron.left", action: app.goBack)
                    .disabled(!app.canGoBack).help("Back (⌘[)")
                Button("Forward", systemImage: "chevron.right", action: app.goForward)
                    .disabled(!app.canGoForward).help("Forward (⌘])")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if isBrowsing {
                    if app.isScanning && app.scanningLocationID == app.activeLocationID {
                        Button("Cancel Scan", systemImage: "xmark.circle") { app.cancelScan() }
                            .help("Cancel the scan")
                    } else {
                        Button("Rescan", systemImage: "arrow.clockwise") { app.rescanActive() }
                            .help("Rescan this location (⌘R)")
                            .disabled(app.activeLocation == nil)
                    }
                    Picker("View", selection: $app.viewMode) {
                        Label("List", systemImage: "list.bullet").tag(SDViewMode.list)
                        Label("Map", systemImage: "square.grid.2x2").tag(SDViewMode.map)
                    }
                    .pickerStyle(.segmented)
                    .help("View as list or map")
                }
                Button("Add Location", systemImage: "folder.badge.plus") {
                    Task { await app.addLocationFlow() }
                }.help("Add a folder to analyze (⌘O)")
                Button("Toggle Inspector", systemImage: "sidebar.trailing") {
                    app.showInspector.toggle()
                }.help("Toggle inspector (⌘I)")
            }
        }
        .sheet(isPresented: $app.showAbout) { AboutView() }
        .sheet(isPresented: $app.showScanIssues) { ScanIssuesView() }
    }
}

struct CenterView: View {
    @Environment(AppState.self) private var app
    var body: some View {
        VStack(spacing: 0) {
            switch app.selection {
            case .overview: OverviewView()
            case .location(let id): BrowseView(locationID: id)
            case .largeFiles: LargeFilesView()
            case .olderFiles: OlderFilesView()
            case .duplicates: DuplicatesView()
            case .review: ReviewQueueView()
            }
            StatusBarView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

#Preview {
    ContentView().environment(AppState())
        .frame(width: 1180, height: 780)
}
