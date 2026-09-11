import AppKit
import Foundation

// Centralized scoped file operations (P1): every action on a scanned path
// resolves the containing grant and holds its security scope for exactly the
// synchronous operation — except Quick Look, whose panel reads asynchronously
// and therefore owns its scope until it closes.
extension AppState {
    /// Resolve the granted scope containing a node. Returns nil when the node
    /// is sample data, its location is gone, or the grant cannot be resolved.
    @MainActor
    func scopeForNode(_ node: ScanNode) -> URL? {
        guard let loc = locations.first(where: { CleanupService.isWithin(node.path, root: $0.id) }),
              let (url, _) = try? LocationAccessService.resolve(id: loc.id) else { return nil }
        return url
    }

    @MainActor
    @discardableResult
    func reveal(_ node: ScanNode) -> String? {
        guard let scope = scopeForNode(node),
              scope.startAccessingSecurityScopedResource() else {
            return unreachableMessage
        }
        defer { scope.stopAccessingSecurityScopedResource() }
        let u = URL(fileURLWithPath: node.path)
        guard (try? u.checkResourceIsReachable()) ?? false else { return unreachableMessage }
        NSWorkspace.shared.activateFileViewerSelecting([u])
        return nil
    }

    @MainActor
    @discardableResult
    func preview(_ node: ScanNode) -> String? {
        guard let scope = scopeForNode(node),
              scope.startAccessingSecurityScopedResource() else {
            return unreachableMessage
        }
        let u = URL(fileURLWithPath: node.path)
        guard (try? u.checkResourceIsReachable()) ?? false else {
            scope.stopAccessingSecurityScopedResource()
            return unreachableMessage
        }
        // The bridge owns the scope from here until the panel closes.
        QuickLookBridge.shared.show(url: u, holding: scope)
        return nil
    }

    private var unreachableMessage: String {
        "That item is not reachable. It may have moved, its volume may be offline, or access may have expired. Add the folder again if this persists."
    }
}
