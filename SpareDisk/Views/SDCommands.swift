import SwiftUI

struct AppCommands: Commands {
    let app: AppState
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About SpareDisk") { app.showAbout = true }
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
            Button("Rescan Current Location") { app.rescanActive() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(app.activeLocation == nil || app.isScanning)
        }
    }
}

struct SettingsView: View {
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
            Section("Privacy") {
                Text("Your files are analyzed on this Mac. SpareDisk does not upload file names, paths, or contents.")
                Text("Saved folder permissions stay in the app's local storage. Forget a location from its sidebar menu to remove the saved permission.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(SDTheme.Font.body)
        .formStyle(.grouped)
        .padding(12)
        .frame(width: 460, height: 290)
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
            Text("Understand your storage. Make room for what matters.")
                .font(SDTheme.Font.body).multilineTextAlignment(.center)
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
            Text("Analyzes the folders you choose. Files move to Trash only after you review and confirm.")
                .font(SDTheme.Font.secondary).foregroundStyle(.secondary).multilineTextAlignment(.center)
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
            Text("Scan details").font(SDTheme.Font.screenTitle)
            if let error = app.scanError { Text(error).font(SDTheme.Font.body) }
            let issues = app.activeScan?.issues ?? []
            if issues.isEmpty {
                Text("No additional file-access details are available.").foregroundStyle(.secondary)
            } else {
                Text("Some items couldn't be read. Their contents may be missing from the scan totals.")
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
