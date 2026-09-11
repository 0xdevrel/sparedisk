import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var app
    @State private var locationsExpanded = true

    var body: some View {
        @Bindable var app = app
        List(selection: $app.selection) {
            Section("Storage") {
                Label("Overview", systemImage: "gauge.with.dots.needle.67percent")
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
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 8) {
                Image("SpareDiskLogo").resizable().scaledToFit().frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("SpareDisk").font(.system(size: 15, weight: .semibold))
                    Text("Storage, understood.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(.horizontal, 14).padding(.vertical, 14)
        }
        .navigationTitle("SpareDisk")
        .task { app.restoreStoredLocations() }
    }
}
