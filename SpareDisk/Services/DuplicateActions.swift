import Foundation

// Duplicate runs (§F07): on demand, over retained large-file candidates,
// with every grant held for the whole pass. Cancel discards the partial run;
// the previous groups stay on screen.
extension AppState {
    @MainActor
    func findDuplicates() async {
        duplicateGroups = []
        duplicateSkips = []
        duplicateKeepers = [:]
        duplicateNotice = nil
        duplicateChecked = 0
        duplicateTotal = 0
        duplicateCurrent = nil

        let files = scans.values.flatMap(\.largestFiles)
        guard !files.isEmpty else {
            duplicateNotice = "Scan a location first. Duplicates are found among its large files."
            return
        }

        // Resolve one scope per containing location; unreadable files are
        // reported as skips rather than attempted without access.
        var scopes: [String: URL] = [:]
        var readable: [ScanNode] = []
        var early: [DuplicateSkip] = []
        for f in files {
            guard let loc = locations.first(where: { CleanupService.isWithin(f.path, root: $0.id) }) else {
                early.append(DuplicateSkip(id: f.id, name: f.name, path: f.path,
                                           reason: "Not in an authorized location anymore."))
                continue
            }
            if scopes[loc.id] == nil {
                guard let (url, _) = try? LocationAccessService.resolve(id: loc.id) else {
                    early.append(DuplicateSkip(id: f.id, name: f.name, path: f.path,
                                               reason: "Its location needs to be chosen again."))
                    continue
                }
                scopes[loc.id] = url
            }
            readable.append(f)
        }

        var tokens: [URL] = []
        for url in Set(scopes.values) where url.startAccessingSecurityScopedResource() {
            tokens.append(url)
        }
        defer { tokens.forEach { $0.stopAccessingSecurityScopedResource() } }
        let live = Set(tokens)
        var runnable: [ScanNode] = []
        for f in readable {
            let ok = scopes.values.contains { scope in
                live.contains(scope)
                    && CleanupService.isWithin(f.path, root: scope.standardizedFileURL.path)
            }
            if ok {
                runnable.append(f)
            } else {
                early.append(DuplicateSkip(id: f.id, name: f.name, path: f.path,
                                           reason: "Access to its location couldn't be started."))
            }
        }

        duplicateRunning = true
        defer {
            duplicateRunning = false
            duplicateCurrent = nil
        }
        duplicateTotal = runnable.count
        let (stream, continuation) = AsyncStream<DuplicateProgress>.makeStream()
        let worker = Task.detached(priority: .userInitiated) {
            let result = await DuplicateService.findDuplicates(files: runnable) { p in
                continuation.yield(p)
            }
            continuation.finish()
            return result
        }
        continuation.onTermination = { _ in worker.cancel() }
        for await p in stream {
            if Task.isCancelled { break }
            self.duplicateChecked = p.checked
            self.duplicateTotal = p.total
            self.duplicateCurrent = p.current
        }
        let result = await worker.value
        if Task.isCancelled { return } // keep the previous groups, no error state

        duplicateGroups = result.groups
        duplicateSkips = early + result.skipped
        // Default keeper: the newest copy in each group.
        for g in result.groups where duplicateKeepers[g.id] == nil {
            duplicateKeepers[g.id] = g.files.max(by: {
                ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast)
            })?.id ?? g.files[0].id
        }
        if result.groups.isEmpty {
            duplicateNotice = "No identical contents among \(runnable.count) compared files (≥1 MB, retained large files)."
        }
    }

    @MainActor
    func cancelDuplicates() {
        duplicateTask?.cancel()
    }

    /// Stage every copy except the chosen keeper. The keeper itself can only
    /// enter review file-by-file, and cleanup still refuses the last copy.
    @MainActor
    func stageGroupExceptKeeper(_ group: DuplicateGroup) {
        let keeper = duplicateKeepers[group.id] ?? group.files[0].id
        for f in group.files where f.id != keeper && !isQueued(f.id) {
            toggleReview(f, source: "Duplicates")
        }
    }
}
