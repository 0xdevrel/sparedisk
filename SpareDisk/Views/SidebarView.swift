import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var app
    @State private var locationsExpanded = true

    var body: some View {
        @Bindable var app = app
        List(selection: $app.selection) {
            Section("Storage") {
                Label("My Mac", systemImage: SDTheme.macSymbol)
                    .tag(SDSidebarSelection.overview)
                DisclosureGroup(isExpanded: $locationsExpanded) {
                    if app.locations.isEmpty {
                        Button {
                            Task { await app.addLocationFlow() }
                        } label: {
                            Label("Add Location…", systemImage: "plus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    } else {
                        ForEach(app.locations) { loc in
                            HStack {
                                Label(loc.name, systemImage: loc.symbol)
                                Spacer()
                                if !loc.access.isOK {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .foregroundStyle(.orange)
                                        .help(loc.access.label)
                                }
                            }
                            .tag(SDSidebarSelection.location(loc.id))
                            .contextMenu {
                                Button("Rescan") { app.selection = .location(loc.id); app.rescanActive() }
                                Button("Forget Location…", role: .destructive) { app.forgetLocation(id: loc.id) }
                            }
                        }
                        Button {
                            Task { await app.addLocationFlow() }
                        } label: {
                            Label("Add Location…", systemImage: "plus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                } label: {
                    Label("Locations", systemImage: "folder.fill")
                }
            }
            Section("Find") {
                Label("Large Files", systemImage: "doc.text.magnifyingglass").tag(SDSidebarSelection.largeFiles)
                Label("Older Files", systemImage: "calendar").tag(SDSidebarSelection.olderFiles)
                Label("File Types", systemImage: "rectangle.3.group.fill").tag(SDSidebarSelection.fileTypes)
                HStack {
                    Label("Duplicates", systemImage: "doc.on.doc")
                    Spacer()
                    if !app.duplicateGroups.isEmpty && !app.duplicateRunning {
                        Text("\(app.duplicateGroups.count)")
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
                .tag(SDSidebarSelection.duplicates)
                HStack {
                    Label("Leftovers", systemImage: "app.dashed")
                    Spacer()
                    if !app.leftoverGroups.isEmpty && !app.leftoverRunning {
                        Text("\(app.leftoverGroups.count)")
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
                .tag(SDSidebarSelection.leftovers)
            }
            Section("Cleanup") {
                HStack {
                    Label("Review Cleanup", systemImage: "tray.full")
                    Spacer()
                    if !app.reviewItems.isEmpty {
                        Text("\(app.reviewItems.count)")
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
                .tag(SDSidebarSelection.review)
                .dropDestination(for: URL.self) { urls, _ in
                    app.stage(urls: urls, source: "Drag") > 0
                } isTargeted: { _ in }
            }
        }
        .listStyle(.sidebar)
        .task { app.restoreStoredLocations() }
    }
}
