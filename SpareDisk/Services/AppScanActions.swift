import Foundation

// AppState actions for real locations. UI stays on mock data until the user
// makes an explicit choice — first launch is an invitation, not a demand (§7.6).
extension AppState {
    @MainActor
    func restoreStoredLocations() {
        for id in LocationAccessService.orderedIDs() {
            guard !locations.contains(where: { $0.id == id }) else { continue }
            do {
                let (url, stale) = try LocationAccessService.resolve(id: id)
                if stale { notice = "A saved location needed re-authorization. Choose it again if its scan looks stale." }
                var loc = Self.describe(id: id, url: url, access: .available)
                if let saved = ScanStore.load(locationID: id) {
                    scans[id] = saved
                    loc.scannedBytes = saved.totalBytes
                    loc.scannedAt = saved.finishedAt
                    loc.issues = saved.issues.count
                }
                locations.append(loc)
            } catch {
                locations.append(SDLocation(id: id, name: URL(fileURLWithPath: id).lastPathComponent,
                                            symbol: "folder.fill", isExternal: false,
                                            access: .reconnectRequired, capacityBytes: 0, availableBytes: 0,
                                            scannedBytes: 0, scannedAt: Date(), issues: 0))
            }
        }
        if activeLocation == nil { activeLocationID = locations.first?.id ?? "home" }
        rebuildIndex()
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
            let worker = Task.detached(priority: .userInitiated) {
                // Namespaced under the folder path: ids can never collide
                // with siblings elsewhere in the tree.
                await ScanEngine.scan(locationID: "\(locID)#\(node.path)",
                                      rootName: node.name, root: nodeURL) { p in
                    Task { @MainActor in
                        guard gen == self.drillGeneration else { return }
                        self.drillProgress = p
                    }
                }
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard gen == self.drillGeneration else { return }
            self.applyDrill(result, parentID: drillID, gen: gen)
            self.drillScanningID = nil
            self.drillProgress = nil
        }
    }

    @MainActor
    private func applyDrill(_ result: ScanResult, parentID: String, gen: Int) {
        guard !result.wasCancelled, gen == drillGeneration else { return }
        focusedScans[parentID] = result
        rebuildIndex()
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
        ScanStore.remove(locationID: id)
        locations.removeAll(where: { $0.id == id })
        scans.removeValue(forKey: id)
        focusedScans = focusedScans.filter { !(keyIs($0.key, withinLocation: id)) }
        rebuildIndex()
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
            // worker has terminated.
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            let name = self.locations.first(where: { $0.id == locationID })?.name ?? url.lastPathComponent
            // Enumeration runs off the main thread; each progress report hops
            // to the main actor and is dropped if a newer scan has started.
            let worker = Task.detached(priority: .userInitiated) {
                await ScanEngine.scan(locationID: locationID, rootName: name, root: url) { p in
                    Task { @MainActor in
                        guard gen == self.scanGeneration else { return }
                        self.scanProgress = p
                    }
                }
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard gen == self.scanGeneration else { return }
            self.applyScan(result, locationID: locationID, gen: gen)
            self.scanningLocationID = nil
            self.scanProgress = nil
        }
    }

    /// Top-level rows to show for a location right now: the completed scan,
    /// or the growing partial while its first scan runs.
    @MainActor
    func visibleTopNodes(for locationID: String) -> [ScanNode] {
        if let scan = scans[locationID] { return scan.topNodes }
        if scanningLocationID == locationID, let p = scanProgress { return p.partialTop }
        return []
    }

    @MainActor
    private func applyScan(_ result: ScanResult, locationID: String, gen: Int) {
        // A cancelled or superseded run keeps the previous usable results —
        // never an error state, never stale data over a newer scan.
        guard !result.wasCancelled, gen == scanGeneration else { return }
        self.scans[locationID] = result
        // Fresh results invalidate focused drills into the old tree.
        self.focusedScans = self.focusedScans.filter { !(self.keyIs($0.key, withinLocation: locationID)) }
        self.expandedIDs.removeAll()
        self.rebuildIndex()
        ScanStore.save(result)
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
        // Selection stays with the user: nothing is auto-selected and the
        // inspector does not open on its own.
        if let id = self.inspectedNodeID, self.nodeIndex[id] == nil { self.inspectedNodeID = nil }
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
