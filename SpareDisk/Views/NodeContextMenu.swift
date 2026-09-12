import AppKit
import SwiftUI

/// The one set of item actions, shared by list rows, map cells, Overview rows
/// and the inspector so every surface offers the same verbs.
struct NodeContextMenu: View {
    @Environment(AppState.self) private var app
    let node: ScanNode
    let source: String

    var body: some View {
        Button(app.isQueued(node.id) ? "Remove from Review" : "Add to Review") {
            app.toggleReview(node, source: source)
        }
        .disabled(!app.canReview(node))
        if let why = app.reviewBlocker(node) {
            Text(why)
        }
        if node.isPackage, node.name.hasSuffix(".app") {
            Button("Uninstall…") { app.prepareUninstall(node) }
                .disabled(!app.canReview(node) || app.homeLocation == nil)
        }
        Divider()
        Button("Quick Look") { app.preview(node) }
            .disabled(app.scopeForNode(node) == nil || node.isCloudPlaceholder)
        Button("Reveal in Finder") { app.reveal(node) }
            .disabled(app.scopeForNode(node) == nil)
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.path, forType: .string)
        }
    }
}
