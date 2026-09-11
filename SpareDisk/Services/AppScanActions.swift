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

    @MainActor
    func forgetLocation(id: String) {
        cancelScan()
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
        if activeLocationID == id { activeLocationID = locations.first?.id ?? "home" }
    }

    // MARK: - Internals

    @MainActor
    private func startScan(locationID: String, url: URL) {
        cancelScan()
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
