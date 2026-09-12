import Foundation

// AppState actions for real locations. UI stays on mock data until the user
// makes an explicit choice — first launch is an invitation, not a demand (§7.6).
extension AppState {
    /// `-uiTestFixture`: a disposable folder inside the app container with a
    /// known layout replaces stored locations, so UI tests see the same
    /// screen on every machine. Never active without the argument.
    @MainActor
    func setUpUITestFixtureIfRequested() -> Bool {
        guard CommandLine.arguments.contains("-uiTestFixture") else { return false }
        if CommandLine.arguments.contains("-uiTestFirstLaunch") {
            locations = []
            scans = [:]
            return true
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UITestFixture", isDirectory: true)
        try? FileManager.default.removeItem(at: base)
        let root = base.appendingPathComponent("Fixture", isDirectory: true)
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("Nested"), withIntermediateDirectories: true)
        try? Data(count: 3_000_000).write(to: root.appendingPathComponent("big.bin"))
        try? Data(count: 1_000_000).write(to: root.appendingPathComponent("Nested/medium.bin"))
        try? Data(count: 10_000).write(to: root.appendingPathComponent("small.txt"))
        // The container is always readable inside the sandbox, so no bookmark
        // is needed and nothing is written to the real location list.
        LocationAccessService.forget(id: root.path)
        let grant = LocationAccessService.grantTransient(root)
        viewMode = .list
        sortField = .size
        sortAscending = false
        showInspector = true
        sizeBasis = .logical
        locations = [Self.describe(id: grant.id, url: grant.url, access: .available)]
        activeLocationID = grant.id
        rebuildIndex()
        startScan(locationID: grant.id, url: grant.url)
        return true
    }

    /// `-demoPath <folder>`: grant and scan one folder inside the container in
    /// place of stored locations, for screenshots with neutral data.
    @MainActor
    func setUpDemoPathIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-demoPath"), i + 1 < args.count else { return false }
        let url = URL(fileURLWithPath: args[i + 1])
        LocationAccessService.forget(id: url.path)
        let grant = LocationAccessService.grantTransient(url)
        LeftoverService.homeOverride = url.path
        locations = [Self.describe(id: grant.id, url: grant.url, access: .available)]
        activeLocationID = grant.id
        rebuildIndex()
        if let saved = ScanStore.load(locationID: grant.id) {
            scans[grant.id] = saved
            rebuildIndex()
        } else {
            startScan(locationID: grant.id, url: grant.url)
        }
        return true
    }

    @MainActor
    func restoreStoredLocations() {
        if setUpUITestFixtureIfRequested() { return }
        if setUpDemoPathIfRequested() { return }
        for id in LocationAccessService.orderedIDs() {
            guard !locations.contains(where: { $0.id == id }) else { continue }
            do {
                let (url, stale) = try LocationAccessService.resolve(id: id)
                if stale { notice = "A saved location needed re-authorization. Choose it again if its scan looks stale." }
                var loc = Self.describe(id: id, url: url, access: .available)
                if let saved = ScanStore.load(locationID: id) {
                    scans[id] = saved
                    previousScans[id] = ScanStore.loadPrevious(locationID: id)
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

    /// Add one or more folders. The first scan starts at once; the rest
    /// queue behind it. A first-ever location lands on Overview so the
    /// storage picture builds in front of the user.
    @MainActor
    func addLocationFlow(startingAt start: URL? = nil, message: String? = nil) async {
        scanError = nil
        notice = nil
        do {
            let grants = try await LocationAccessService.pickFolders(startingAt: start, message: message)
            let wasEmpty = locations.isEmpty
            for grant in grants {
                let loc = Self.describe(id: grant.id, url: grant.url, access: .available)
                if !locations.contains(where: { $0.id == loc.id }) { locations.append(loc) }
            }
            guard let first = grants.first else { return }
            activeLocationID = first.id
            selection = wasEmpty || grants.count > 1 ? .overview : .location(first.id)
            scanQueue = grants.dropFirst().map(\.id)
            startScan(locationID: first.id, url: first.url)
        } catch let e as LocationAccessError {
            switch e {
            case .cancelled: break // return to a usable screen, no error (§F01)
            default: scanError = e.localizedDescription
            }
        } catch {
            scanError = error.localizedDescription
        }
    }

    /// Home folder in one step: the picker opens inside it, so Analyze with
    /// nothing selected grants the folder that covers Desktop, Documents,
    /// Downloads and Library together.
    @MainActor
    func addHomeFolderFlow() async {
        await addLocationFlow(startingAt: URL(fileURLWithPath: NSHomeDirectory()),
                              message: "Click Analyze to add your home folder, or choose other folders.")
    }

    @MainActor
    func addApplicationsFlow() async {
        await addLocationFlow(startingAt: URL(fileURLWithPath: "/Applications"),
                              message: "Click Analyze to add Applications, or choose other folders.")
    }

    var overviewScanTitle: String {
        if locations.isEmpty { return "Scan My Mac" }
        return locations.allSatisfy { scans[$0.id] != nil } ? "Rescan" : "Scan"
    }

    /// Refresh every saved grant sequentially. First run still goes through
    /// the system chooser: My Mac is an overview, not blanket disk access.
    @MainActor
    func scanOverview() async {
        guard !isScanning else { return }
        if locations.isEmpty { await addHomeFolderFlow(); return }
        scanError = nil
        scanQueue = locations.map(\.id)
        startNextQueuedScan()
    }

    @MainActor
    func scanLocation(id: String) {
        guard locations.contains(where: { $0.id == id }), scanningLocationID != id else { return }
        if !scanQueue.contains(id) { scanQueue.append(id) }
        if !isScanning { startNextQueuedScan() }
    }

    @MainActor
    func cancelAllScans() {
        scanQueue.removeAll()
        cancelScan()
    }

    /// Start the next queued location after a scan finishes.
    @MainActor
    private func startNextQueuedScan() {
        while let next = scanQueue.first {
            scanQueue.removeFirst()
            do {
                let (url, stale) = try LocationAccessService.resolve(id: next)
                if stale, let location = locations.first(where: { $0.id == next }) {
                    refreshStoredAccess(id: next, url: url, name: location.name)
                }
                startScan(locationID: next, url: url)
                return
            } catch {
                if let index = locations.firstIndex(where: { $0.id == next }) {
                    locations[index].access = .reconnectRequired
                    scanError = "Choose \(locations[index].name) again to restore access. Other locations can still be scanned."
                }
            }
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
        guard LocationAccessService.beginAccess(url) else {
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
            let accessing = LocationAccessService.beginAccess(scope)
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
        // Only this location's work stops. A scan of another location keeps
        // running and keeps its progress state.
        scanQueue.removeAll { $0 == id }
        if scanningLocationID == id {
            cancelScan()
            scanGeneration += 1
            scanningLocationID = nil
            scanProgress = nil
        }
        if let d = drillScanningID, keyIs(d, withinLocation: id) {
            cancelDrill()
            drillGeneration += 1
            drillScanningID = nil
            drillProgress = nil
        }
        LocationAccessService.forget(id: id)
        ScanStore.remove(locationID: id)
        locations.removeAll(where: { $0.id == id })
        scans.removeValue(forKey: id)
        previousScans.removeValue(forKey: id)
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
            let accessing = LocationAccessService.beginAccess(url)
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
            guard gen == self.scanGeneration else {
                // A newer run owns the progress, even for the same location.
                return
            }
            self.applyScan(result, locationID: locationID, gen: gen)
            self.scanningLocationID = nil
            self.scanProgress = nil
            self.startNextQueuedScan()
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
        if let current = self.scans[locationID] { self.previousScans[locationID] = current }
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
               LocationAccessService.beginAccess(url) {
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
        let vals = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                                     .volumeUUIDStringKey, .volumeLocalizedNameKey, .volumeIsInternalKey])
        return SDLocation(id: id, name: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
                          symbol: "folder.fill", isExternal: vals?.volumeIsInternal == false, access: access,
                          capacityBytes: Int64(vals?.volumeTotalCapacity ?? 0),
                          availableBytes: Int64(vals?.volumeAvailableCapacity ?? 0),
                          volumeUUID: vals?.volumeUUIDString, volumeName: vals?.volumeLocalizedName,
                          scannedBytes: 0, scannedAt: Date(), issues: 0)
    }
}
