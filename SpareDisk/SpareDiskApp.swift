import SwiftUI

@main
struct SpareDiskApp: App {
    @State private var appState = AppState()
    @AppStorage("appearance") private var appearance = "System"

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .frame(minWidth: 900, minHeight: 620)
                .preferredColorScheme(appearance == "System" ? nil : appearance == "Dark" ? .dark : .light)
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            AppCommands(app: appState)
        }

        Settings {
            SettingsView()
                .environment(appState)
        }

        Window("SpareDisk Help", id: "help") {
            HelpView()
        }
        .defaultSize(width: 760, height: 520)
        .keyboardShortcut("?", modifiers: .command)
    }
}
