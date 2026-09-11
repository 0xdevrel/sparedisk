import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var app
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    private var isBrowsing: Bool {
        if case .location = app.selection { return true }
        return false
    }

    private var canSearch: Bool {
        switch app.selection {
        case .location, .largeFiles, .olderFiles: return true
        default: return false
        }
    }

    var body: some View {
        @Bindable var app = app
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 260)
        } detail: {
            if canSearch {
                CenterView().searchable(text: $app.searchText, prompt: app.searchPrompt)
            } else {
                CenterView()
            }
        }
        .inspector(isPresented: $app.showInspector) {
            InspectorView()
                .inspectorColumnWidth(min: 280, ideal: 300, max: 340)
        }
        .navigationTitle("SpareDisk")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button("Back", systemImage: "chevron.left", action: app.goBack)
                    .disabled(!app.canGoBack).help("Back (⌘[)")
                Button("Forward", systemImage: "chevron.right", action: app.goForward)
                    .disabled(!app.canGoForward).help("Forward (⌘])")
            }
            ToolbarItem(placement: .primaryAction) {
                if isBrowsing {
                    Picker("View", selection: $app.viewMode) {
                        Label("List", systemImage: "list.bullet").tag(SDViewMode.list)
                        Label("Map", systemImage: "square.grid.2x2").tag(SDViewMode.map)
                    }
                    .pickerStyle(.segmented).frame(width: 150)
                    .help("Choose how to view this location")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Choose a Folder", systemImage: "folder.badge.plus") {
                    Task { await app.addLocationFlow() }
                }.help("Choose a folder (⌘O)")
            }
            ToolbarItem(placement: .primaryAction) {
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
