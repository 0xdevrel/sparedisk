import Foundation

// AppState actions for real locations. UI stays on mock data until the user
// makes an explicit choice — first launch is an invitation, not a demand (§7.6).
extension AppState {
    @MainActor
    func restoreStoredLocations() {
        for (id, _) in LocationAccessService.loadBookmarks() {
            guard !locations.contains(where: { $0.id == id }) else { continue }
            do {
                let (url, stale) = try LocationAccessService.resolve(id: id)
                if stale { notice = "A saved location needed re-authorization. Choose it again if its scan looks stale." }
                locations.append(Self.describe(id: id, url: url, access: .available))
            } catch {
                locations.append(SDLocation(id: id, name: URL(fileURLWithPath: id).lastPathComponent,
                                            symbol: "folder.fill", isExternal: false,
                                            access: .reconnectRequired, capacityBytes: 0, availableBytes: 0,
                                            scannedBytes: 0, scannedAt: Date(), issues: 0))
            }
        }
        if activeLocation == nil { activeLocationID = locations.first?.id ?? "home" }
    }

    @MainActor
    func addLocationFlow() async {
        scanError = nil
        notice = nil
        do {
            let grant = try await LocationAccessService.pickFolder()
            let loc = Self.describe(id: grant.id, url: grant.url, access: .available)
            if !locations.contains(where: { $0.id == loc.id }) { locations.append(loc) }
            activeLocationID = loc.id
            selection = .location(loc.id)
            startScan(locationID: loc.id, url: grant.url)
        } catch let e as LocationAccessError {
            switch e {
            case .cancelled: break // return to usable overview, no error (§F01)
            default: scanError = e.localizedDescription
            }
        } catch {
            scanError = error.localizedDescription
        }
    }

    @MainActor
    func rescanActive() {
        guard let id = Optional(activeLocationID),
              let idx = locations.firstIndex(where: { $0.id == id }) else { return }
        do {
            let (url, stale) = try LocationAccessService.resolve(id: id)
            if stale { refreshStoredAccess(id: id, url: url, name: locations[idx].name) }
            startScan(locationID: id, url: url)
        } catch {
            locations[idx].access = .reconnectRequired
            scanError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Rebuild stale bookmark data while holding access — the only honest
    /// "re-authorization": no prompt is shown, stored data is renewed (P1).
    @MainActor
    private func refreshStoredAccess(id: String, url: URL, name: String) {
        guard url.startAccessingSecurityScopedResource() else {
            notice = "Stored access for \(name) couldn't be renewed. If its scan looks stale, choose the folder again."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            try LocationAccessService.refreshedURL(id: id, url: url)
            notice = "Refreshed stored access for \(name)."
        } catch {
            notice = "Stored access for \(name) couldn't be renewed. If its scan looks stale, choose the folder again."
        }
    }

    @MainActor
    func cancelScan() {
        scanTask?.cancel()
    }

    // MARK: - Focused drill-down ("rescan focused folder", §F02)

    /// Retained children for a node: embedded (mock / depth ≤ 2) or a
    /// completed focused scan. Nil means unknown — expand to read them.
    @MainActor
    func children(of node: ScanNode) -> [ScanNode]? {
        if let c = node.children, !c.isEmpty { return c }
        return focusedScans[node.id]?.topNodes
    }

    /// Called when the user expands or drills into a folder whose contents
    /// are not retained. Reads exactly that folder under the existing grant.
    @MainActor
    func ensureChildren(_ node: ScanNode) {
        guard node.isFolder, !node.isCloudPlaceholder else { return }
        guard children(of: node) == nil, drillScanningID != node.id else { return }
        guard locations.contains(where: { CleanupService.isWithin(node.path, root: $0.id) }) else { return }
        startDrill(node)
    }

    @MainActor
    func cancelDrill() {
        drillTask?.cancel()
    }

    @MainActor
    private func startDrill(_ node: ScanNode) {
        cancelDrill()
        drillGeneration += 1
        let gen = drillGeneration
        let nodeURL = URL(fileURLWithPath: node.path)
        let drillID = node.id
        drillScanningID = drillID
        drillProgress = ScanProgress(itemsFound: 0, elapsed: 0, currentPath: node.name)
        drillTask = Task {
            // Scope is the containing granted location; the scan root is the folder.
            guard let locID = self.locations.first(where: { CleanupService.isWithin(node.path, root: $0.id) })?.id,
                  let (scope, _) = try? LocationAccessService.resolve(id: locID) else {
                self.drillScanningID = nil
                self.drillProgress = nil
                return
            }
            let accessing = scope.startAccessingSecurityScopedResource()
            defer { if accessing { scope.stopAccessingSecurityScopedResource() } }
            let (stream, continuation) = AsyncStream<ScanProgress>.makeStream()
            let worker = Task.detached(priority: .userInitiated) {
                // Namespaced under the folder path: ids can never collide
                // with siblings elsewhere in the tree (P2 identity note).
                let result = await ScanEngine.scan(locationID: "\(locID)#\(node.path)",
                                                   rootName: node.name, root: nodeURL) { p in
                    continuation.yield(p)
                }
                continuation.finish()
                await MainActor.run { self.applyDrill(result, parentID: drillID, gen: gen) }
            }
            continuation.onTermination = { _ in worker.cancel() }
            for await p in stream {
                guard gen == self.drillGeneration else { break }
                if Task.isCancelled { break }
                self.drillProgress = p
            }
            await worker.value
            guard gen == self.drillGeneration else { return }
            self.drillScanningID = nil
            self.drillProgress = nil
        }
    }

    @MainActor
    private func applyDrill(_ result: ScanResult, parentID: String, gen: Int) {
        guard !result.wasCancelled, gen == drillGeneration else { return }
        focusedScans[parentID] = result
    }

    @MainActor
    func forgetLocation(id: String) {
        cancelScan()
        cancelDrill()
        drillGeneration += 1
        drillScanningID = nil
        drillProgress = nil
        // Invalidate any unwinding worker so it cannot re-apply results,
        // and clear progress if it belonged to this location.
        scanGeneration += 1
        if scanningLocationID == id {
            scanningLocationID = nil
            scanProgress = nil
        }
        LocationAccessService.forget(id: id)
        locations.removeAll(where: { $0.id == id })
        scans.removeValue(forKey: id)
        focusedScans = focusedScans.filter { !(keyIs($0.key, withinLocation: id)) }
        if activeLocationID == id { activeLocationID = locations.first?.id ?? "home" }
    }

    private func keyIs(_ key: String, withinLocation id: String) -> Bool {
        key == id || key.hasPrefix(id + "/") || key.hasPrefix(id + "#")
    }

    // MARK: - Internals

    @MainActor
    private func startScan(locationID: String, url: URL) {
        cancelScan()
        // A fresh location scan invalidates focused drills (their basis changed).
        cancelDrill()
        drillGeneration += 1
        // Own this run: stale workers and their progress never touch current state (P1).
        scanGeneration += 1
        let gen = scanGeneration
        scanningLocationID = locationID
        scanProgress = ScanProgress(itemsFound: 0, elapsed: 0, currentPath: "")
        scanTask = Task {
            // Hold the grant for the whole batch; released only after the
            // worker has terminated (see `await worker.value` below).
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            let name = self.locations.first(where: { $0.id == locationID })?.name ?? url.lastPathComponent
            // Enumeration runs off the main thread (§9.4); progress streams back.
            // Cancellation flows: consumer break -> stream termination ->
            // worker cancel -> engine observes Task.isCancelled.
            let (stream, continuation) = AsyncStream<ScanProgress>.makeStream()
            let worker = Task.detached(priority: .userInitiated) {
                let result = await ScanEngine.scan(locationID: locationID, rootName: name, root: url) { p in
                    continuation.yield(p)
                }
                continuation.finish()
                await MainActor.run { self.applyScan(result, locationID: locationID, gen: gen) }
            }
            continuation.onTermination = { _ in worker.cancel() }
            for await p in stream {
                guard gen == self.scanGeneration else { break }
                if Task.isCancelled { break }
                self.scanProgress = p
            }
            // Await the worker BEFORE releasing the grant and clearing state:
            // no scope use-after-release, no newer-progress wipe (P1).
            await worker.value
            guard gen == self.scanGeneration else { return }
            self.scanningLocationID = nil
            self.scanProgress = nil
        }
    }

    @MainActor
    private func applyScan(_ result: ScanResult, locationID: String, gen: Int) {
        // A cancelled or superseded run keeps the previous usable results —
        // never an error state, never stale data over a newer scan.
        guard !result.wasCancelled, gen == scanGeneration else { return }
        self.scans[locationID] = result
        // Fresh results invalidate focused drills into the old tree.
        self.focusedScans = self.focusedScans.filter { !(self.keyIs($0.key, withinLocation: locationID)) }
        if let i = self.locations.firstIndex(where: { $0.id == locationID }) {
            self.locations[i].scannedBytes = result.totalBytes
            self.locations[i].scannedAt = result.finishedAt
            self.locations[i].issues = result.issues.count
            self.locations[i].access = result.issues.isEmpty ? .available : .partiallyAccessible("\(result.issues.count) unreadable")
            // Refresh volume availability at completion time — capacity shown
            // is timestamped by scannedAt, not by when the folder was added (P2).
            if let (url, _) = try? LocationAccessService.resolve(id: locationID),
               url.startAccessingSecurityScopedResource() {
                defer { url.stopAccessingSecurityScopedResource() }
                if let vals = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]) {
                    if let t = vals.volumeTotalCapacity { self.locations[i].capacityBytes = Int64(t) }
                    if let a = vals.volumeAvailableCapacity { self.locations[i].availableBytes = Int64(a) }
                }
            }
        }
        self.inspectedNodeID = result.topNodes.first?.id
    }

    private static func describe(id: String, url: URL, access: SDLocation.Access) -> SDLocation {
        let vals = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        return SDLocation(id: id, name: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
                          symbol: "folder.fill", isExternal: false, access: access,
                          capacityBytes: Int64(vals?.volumeTotalCapacity ?? 0),
                          availableBytes: Int64(vals?.volumeAvailableCapacity ?? 0),
                          scannedBytes: 0, scannedAt: Date(), issues: 0)
    }
}
