import AppKit
import Foundation

// Review-queue execution (§F10): the queue is a proposal until the user
// confirms. Only moved items (and descendants of moved folders) leave the
// queue; everything else stays with its reason. Never executes on relaunch.
extension AppState {
    /// Ask to move one item straight to the Trash. Same revalidation and
    /// confirmation as the queue, without staging first.
    @MainActor
    func requestTrash(_ node: ScanNode) { requestTrash([node]) }

    @MainActor
    func requestTrash(_ nodes: [ScanNode]) {
        guard !cleanupRunning else { return }
        directTrashSkipped = nodes.filter { !canReview($0) }.map { node in
            CleanupResult(id: node.id, name: node.name, path: node.path, bytes: node.logicalBytes,
                          outcome: .blocked(reviewBlocker(node) ?? "This item is no longer in the current scan. Find it again before moving it."))
        }
        let items = nodes.filter { canReview($0) }.map {
            ReviewItem(id: $0.id, node: $0, source: "Direct", reason: "Direct", risk: $0.isFolder ? "Folder" : "File",
                       verifiedAt: verificationTime(for: $0))
        }
        guard !items.isEmpty else {
            cleanupResults = directTrashSkipped
            directTrashSkipped = []
            lastCleanupSummary = cleanupResults.isEmpty ? nil : "Nothing was moved. See the report for each item's reason."
            return
        }
        directTrashItems = items
    }

    @MainActor
    func confirmDirectTrash() {
        let items = directTrashItems
        let skipped = directTrashSkipped
        directTrashItems = []
        directTrashSkipped = []
        guard !items.isEmpty else { return }
        cleanupTask = Task { await runCleanup(items: items, preflightResults: skipped) }
    }

    /// Stage every reviewable node that is not already staged.
    @MainActor
    func addToReview(_ nodes: [ScanNode], source: String) {
        for n in nodes where canReview(n) && !isQueued(n.id) { toggleReview(n, source: source) }
    }

    @MainActor
    func runCleanup(items overridePlan: [ReviewItem]? = nil, preflightResults: [CleanupResult] = []) async {
        cleanupResults = []
        lastCleanupSummary = nil
        // A verified group's last remaining copy is never staged (F07).
        let (protectedPlan, protectedSkips) = DuplicateService.protectKeepers(
            plan: overridePlan.map(CleanupService.normalize) ?? reviewPlan, groups: duplicateGroups, keepers: duplicateKeepers)
        let (plan, keeperGone) = DuplicateService.requireKeepers(plan: protectedPlan, groups: duplicateGroups, keepers: duplicateKeepers)
        let keeperSkips = preflightResults + protectedSkips + keeperGone
        guard !plan.isEmpty else {
            cleanupResults = keeperSkips
            lastCleanupSummary = keeperSkips.isEmpty ? nil
                : "Nothing moved. See the report for each item’s reason."
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
                    if stale, LocationAccessService.beginAccess(url) {
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
        for url in Set(scoped.map { $0.1 }) where LocationAccessService.beginAccess(url) {
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
            lastCleanupSummary = "Nothing was moved. \(stuck) item\(stuck == 1 ? "" : "s") need\(stuck == 1 ? "s" : "") attention. View the report for details."
        } else if stuck == 0 {
            lastCleanupSummary = "Moved \(moved.count) item\(moved.count == 1 ? "" : "s") (\(SDFormat.bytesString(movedBytes))) to Trash."
        } else {
            lastCleanupSummary = "Moved \(moved.count) item\(moved.count == 1 ? "" : "s") to Trash. \(stuck) could not be moved."
        }
        // Reconcile: moved items leave, whichever id staged them, plus
        // anything nested under a moved folder.
        reviewItems = CleanupService.remaining(reviewItems, afterMoving: moved)
        // Moved leftovers leave their groups; an emptied group disappears.
        let movedPaths = moved.map { CleanupService.standardized($0.path) }
        let leftoverCountBefore = leftoverGroups.reduce(0) { $0 + $1.items.count }
        leftoverGroups = leftoverGroups.compactMap { g in
            var g = g
            g.items.removeAll { item in
                let p = CleanupService.standardized(item.path)
                return movedPaths.contains { $0 == p || CleanupService.isWithin(p, root: $0) }
            }
            return g.items.isEmpty ? nil : g
        }
        if leftoverGroups.reduce(0, { $0 + $1.items.count }) != leftoverCountBefore {
            leftoverNotice = leftoverGroups.isEmpty ? "All listed leftovers were moved to Trash."
                : "\(leftoverGroups.count) apps still have listed data, \(SDFormat.bytesString(leftoverGroups.reduce(0) { $0 + $1.bytes })) remaining."
        }
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
