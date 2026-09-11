import AppKit
import Foundation

// Review-queue execution (§F10): the queue is a proposal until the user
// confirms. Only moved items (and descendants of moved folders) leave the
// queue; everything else stays with its reason. Never executes on relaunch.
extension AppState {
    @MainActor
    func runCleanup() async {
        cleanupResults = []
        lastCleanupSummary = nil
        // A verified group's last remaining copy is never staged (F07).
        let (keptPlan, keeperSkips) = DuplicateService.protectKeepers(
            plan: reviewPlan, groups: duplicateGroups, keepers: duplicateKeepers)
        let plan = keptPlan
        guard !plan.isEmpty else {
            cleanupResults = keeperSkips
            lastCleanupSummary = keeperSkips.isEmpty ? nil
                : "Nothing staged — every queued item is a protected last copy."
            return
        }

        // Match each item to an authorized scope; resolve each scope once,
        // refreshing stale stored access while it can still be renewed (P1).
        var scopes: [String: URL] = [:]
        var scoped: [(ReviewItem, URL)] = []
        var early: [CleanupResult] = []
        for item in plan {
            guard let loc = locations.first(where: { CleanupService.isWithin(item.node.path, root: $0.id) }) else {
                early.append(CleanupResult(id: item.id, name: item.node.name, path: item.node.path,
                                           bytes: item.node.logicalBytes,
                                           outcome: .blocked("Not in an authorized location anymore. Choose the folder again.")))
                continue
            }
            if scopes[loc.id] == nil {
                do {
                    let (url, stale) = try LocationAccessService.resolve(id: loc.id)
                    if stale, url.startAccessingSecurityScopedResource() {
                        try? LocationAccessService.refreshedURL(id: loc.id, url: url)
                        url.stopAccessingSecurityScopedResource()
                    }
                    scopes[loc.id] = url
                } catch {
                    early.append(CleanupResult(id: item.id, name: item.node.name, path: item.node.path,
                                               bytes: item.node.logicalBytes,
                                               outcome: .blocked("That location needs to be chosen again before removal.")))
                    continue
                }
            }
            if let scope = scopes[loc.id] {
                scoped.append((item, scope))
            }
        }

        // Hold every scope for the whole batch (balanced start/stop, §8.2).
        // A scope that fails to start excludes its items — they are reported,
        // never attempted without access (P1).
        var tokens: [URL] = []
        for url in Set(scoped.map { $0.1 }) where url.startAccessingSecurityScopedResource() {
            tokens.append(url)
        }
        defer { tokens.forEach { $0.stopAccessingSecurityScopedResource() } }
        let live = Set(tokens)
        var runnable: [(ReviewItem, URL)] = []
        for (item, scope) in scoped {
            if live.contains(scope) {
                runnable.append((item, scope))
            } else {
                early.append(CleanupResult(id: item.id, name: item.node.name, path: item.node.path,
                                           bytes: item.node.logicalBytes,
                                           outcome: .blocked("Access to this location couldn't be started. Choose the folder again.")))
            }
        }

        // Filesystem work runs off the main thread; progress streams back.
        // Cancellation: consumer break -> stream termination -> worker cancel
        // -> execute observes Task.isCancelled between items.
        cleanupRunning = true
        defer {
            cleanupRunning = false
            cleanupCurrent = nil
        }
        let (progressStream, progressCont) = AsyncStream<String>.makeStream()
        let worker = Task.detached(priority: .userInitiated) {
            let done = await CleanupService.execute(plan: runnable) { name in
                progressCont.yield(name)
            }
            progressCont.finish()
            return done
        }
        progressCont.onTermination = { _ in worker.cancel() }
        for await name in progressStream {
            if Task.isCancelled { break }
            self.cleanupCurrent = name
        }
        let done = await worker.value

        let results = early + keeperSkips + done
        cleanupResults = results

        let moved = results.filter(\.didMove)
        let movedBytes = moved.reduce(0) { $0 + $1.bytes }
        let stuck = results.count - moved.count
        if moved.isEmpty {
            lastCleanupSummary = "Nothing was moved. \(stuck) item\(stuck == 1 ? "" : "s") need\(stuck == 1 ? "s" : "") attention below."
        } else if stuck == 0 {
            lastCleanupSummary = "Moved \(moved.count) item\(moved.count == 1 ? "" : "s") (\(SDFormat.bytesString(movedBytes))) to Trash."
        } else {
            lastCleanupSummary = "Moved \(moved.count) item\(moved.count == 1 ? "" : "s") to Trash. \(stuck) could not be moved."
        }
        // Reconcile: moved items leave, plus anything nested under a moved
        // folder (normalize kept them out of the plan; the move took them).
        let movedIDs = Set(moved.map(\.id))
        let movedPaths = moved.map(\.path)
        reviewItems.removeAll(where: { item in
            movedIDs.contains(item.id)
                || movedPaths.contains(where: { CleanupService.isWithin(item.node.path, root: $0) })
        })
    }

    @MainActor
    func cancelCleanup() {
        cleanupTask?.cancel()
    }

    @MainActor
    func showTrash() {
        if let trash = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: trash.path)
        }
    }
}
