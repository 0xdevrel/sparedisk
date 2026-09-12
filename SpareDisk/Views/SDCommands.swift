import AppKit
import SwiftUI

struct AppCommands: Commands {
    let app: AppState
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About SpareDisk") { app.showAbout = true }
        }
        CommandGroup(replacing: .help) {
            Button("SpareDisk Help") { openWindow(id: "help") }
                .keyboardShortcut("?", modifiers: .command)
        }
        CommandGroup(after: .newItem) {
            Button("Choose a Location…") { Task { await app.addLocationFlow() } }
                .keyboardShortcut("o", modifiers: .command)
        }
        CommandGroup(after: .sidebar) {
            Button(app.showInspector ? "Hide Inspector" : "Show Inspector") { app.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: .command)
            Divider()
            Button("Back", action: app.goBack).keyboardShortcut("[", modifiers: .command).disabled(!app.canGoBack)
            Button("Forward", action: app.goForward).keyboardShortcut("]", modifiers: .command).disabled(!app.canGoForward)
        }
        CommandGroup(after: .toolbar) {
            Picker("Size Basis", selection: Binding(get: { app.sizeBasis }, set: { app.sizeBasis = $0 })) {
                Text("Logical Size").tag(SDSizeBasis.logical)
                Text("Size on Disk").tag(SDSizeBasis.onDisk)
            }
            .pickerStyle(.inline)
            Divider()
            Button("Rescan Current Location") { app.rescanActive() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(app.activeLocation == nil || app.isScanning)
        }
        CommandMenu("Item") {
            Button(app.selectedNodes.count > 1 ? "Add \(app.selectedNodes.count) Items to Review"
                   : app.inspectedNode.map { app.isQueued($0.id) } == true ? "Remove from Review" : "Add to Review") {
                if app.selectedNodes.count > 1 { app.addToReview(app.selectedNodes, source: "Menu") }
                else if let n = app.inspectedNode { app.toggleReview(n, source: "Menu") }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!app.selectedNodes.contains { app.canReview($0) })
            Button(app.selectedNodes.count > 1 ? "Move \(app.selectedNodes.count) Items to Trash…" : "Move to Trash…") {
                app.requestTrash(app.selectedNodes)
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(!app.selectedNodes.contains { app.canReview($0) })
            Divider()
            Button("Quick Look") { if let n = app.inspectedNode { app.preview(n) } }
                .keyboardShortcut("y", modifiers: .command)
                .disabled(app.inspectedNode.map { app.scopeForNode($0) == nil || $0.isCloudPlaceholder } ?? true)
            Button("Reveal in Finder") { if let n = app.inspectedNode { app.reveal(n) } }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(app.inspectedNode.map { app.scopeForNode($0) == nil } ?? true)
            Button("Copy Path") {
                if let n = app.inspectedNode {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(n.path, forType: .string)
                }
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(app.inspectedNode == nil)
        }
    }
}

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @AppStorage("appearance") private var appearance = "System"
    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    Text("System").tag("System")
                    Text("Light").tag("Light")
                    Text("Dark").tag("Dark")
                }
            }
            Section("Sizes") {
                Picker("Show", selection: Binding(get: { app.sizeBasis }, set: { app.sizeBasis = $0 })) {
                    Text("Logical size").tag(SDSizeBasis.logical)
                    Text("Size on disk").tag(SDSizeBasis.onDisk)
                }
                Text("Logical size is what a file would hold if fully downloaded and uncompressed. Size on disk is what it occupies now.")
                    .foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Text("Analysis happens on this Mac. File names, paths, and contents are never uploaded.")
                Text("Use Forget Location in the sidebar to remove a saved folder permission and its saved scan.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(SDTheme.Font.body)
        .formStyle(.grouped)
        .padding(12)
        .frame(width: 460, height: 380)
        .preferredColorScheme(appearance == "System" ? nil : appearance == "Dark" ? .dark : .light)
    }
}

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 12) {
            Image("SpareDiskLogo").resizable().scaledToFit().frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("SpareDisk").font(.system(size: 26, weight: .semibold))
            Text("See where your space goes.")
                .font(SDTheme.Font.body).multilineTextAlignment(.center)
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
            Text("Analyzes the folders you choose. Files move to the Trash only after you confirm.")
                .font(SDTheme.Font.secondary).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 14) {
                Link("sparedisk.minilabs.cc", destination: URL(string: "https://sparedisk.minilabs.cc/")!)
                Link("support@minilabs.cc", destination: URL(string: "mailto:support@minilabs.cc")!)
            }
            .font(SDTheme.Font.secondary)
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).padding(.top, 8)
        }
        .padding(32).frame(width: 390)
    }
}

struct ScanIssuesView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Unreadable Folders").font(SDTheme.Font.screenTitle)
            if let error = app.scanError { Text(error).font(SDTheme.Font.body) }
            let issues = app.activeScan?.issues ?? []
            if issues.isEmpty {
                Text("Every folder in this location was read.").foregroundStyle(.secondary)
            } else {
                Text("These folders could not be read, so their contents are missing from the totals.")
                    .font(SDTheme.Font.body)
                List(issues) { issue in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(issue.path).textSelection(.enabled)
                        Text(issue.message).foregroundStyle(.secondary)
                    }.font(SDTheme.Font.secondary).padding(.vertical, 4)
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 540, height: 380)
    }
}
