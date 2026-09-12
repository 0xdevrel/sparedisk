import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var app
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    private var isBrowsing: Bool {
        if case .location = app.selection { return true }
        return false
    }

    private var showsViewPicker: Bool {
        switch app.selection {
        case .location, .largeFiles, .olderFiles, .fileTypes, .duplicates, .leftovers: true
        default: false
        }
    }

    private var title: String {
        switch app.selection {
        case .overview: "My Mac"
        case .location: app.activeLocation?.name ?? "Location"
        case .largeFiles: "Large Files"
        case .olderFiles: "Older Files"
        case .fileTypes: "File Types"
        case .leftovers: "Leftovers"
        case .duplicates: "Duplicates"
        case .review: "Review Cleanup"
        }
    }

    private var subtitle: String {
        switch app.selection {
        case .location(let id):
            if let scan = app.scans[id] {
                return "\(SDFormat.bytesString(app.total(of: scan))), \(scan.itemCount.formatted()) items"
            }
            if app.scanningLocationID == id, let p = app.scanProgress {
                return "Scanning, \(p.itemsFound.formatted()) items"
            }
            return "Not scanned"
        case .overview:
            let scanned = app.locations.filter { app.scans[$0.id] != nil }.count
            return app.locations.isEmpty ? "" : "\(scanned) of \(app.locations.count) locations scanned"
        case .review:
            return app.reviewPlan.isEmpty ? "" : "\(app.reviewPlan.count) \(app.reviewPlan.count == 1 ? "item" : "items"), \(SDFormat.bytesString(app.reviewPlanBytes))"
        case .duplicates:
            return app.duplicateGroups.isEmpty ? "" : "\(app.duplicateGroups.count) groups"
        case .leftovers:
            return app.leftoverGroups.isEmpty ? "" : "\(app.leftoverGroups.count) \(app.leftoverGroups.count == 1 ? "app" : "apps"), \(SDFormat.bytesString(app.leftoverGroups.reduce(0) { $0 + $1.bytes }))"
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
                }
                if showsViewPicker {
                    Picker("View", selection: $app.viewMode) {
                        Image(systemName: "list.bullet").accessibilityLabel("List").help("List").tag(SDViewMode.list)
                        Image(systemName: "square.grid.2x2").accessibilityLabel("Map").help("Map").tag(SDViewMode.map)
                        Image(systemName: "circle.circle").accessibilityLabel("Sunburst").help("Sunburst").tag(SDViewMode.sunburst)
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
        .alert(app.directTrashItems.count == 1 ? "Move “\(app.directTrashItems[0].node.name)” to the Trash?"
               : "Move \(app.directTrashItems.count) items to the Trash?",
               isPresented: Binding(get: { !app.directTrashItems.isEmpty }, set: { if !$0 { app.directTrashItems = [] } })) {
            Button("Move to Trash", role: .destructive) { app.confirmDirectTrash() }
            Button("Cancel", role: .cancel) { app.directTrashItems = [] }
        } message: {
            Text("\(SDFormat.bytesString(app.directTrashItems.reduce(0) { $0 + $1.node.logicalBytes })). Each item is checked again first. Space is freed when you empty the Trash.")
        }
        .sheet(isPresented: $app.showAbout) { AboutView() }
        .sheet(isPresented: $app.showScanIssues) { ScanIssuesView() }
        .sheet(item: $app.uninstallPlan) { plan in UninstallSheet(plan: plan) }
        .task {
            // The window is not yet on screen when the view first appears.
            try? await Task.sleep(for: .milliseconds(400))
            Self.applyWindowSizeArgument()
        }
    }

    /// `-windowSize 1280x800`: a fixed content size for reproducible
    /// screenshots. Ignored without the argument.
    private static func applyWindowSizeArgument() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-windowSize"), i + 1 < args.count else { return }
        let parts = args[i + 1].split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, let window = NSApp.windows.first(where: { $0.isVisible }) else { return }
        window.setContentSize(NSSize(width: parts[0], height: parts[1]))
        window.center()
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
            case .fileTypes: FileTypesView()
            case .leftovers: LeftoversView()
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
