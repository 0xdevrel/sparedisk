import Foundation

// Related-data lookup for an application bundle (§F09). Runs focused scans
// of each candidate folder under the granted home location so sizes are
// real, then exposes them through the node index like any other item.
extension AppState {
    @MainActor
    var homeLocation: SDLocation? {
        let home = NSHomeDirectory()
        return locations.first { $0.id == home || CleanupService.isWithin(home + "/Library", root: $0.id) }
    }

    /// Related data found for an app node id.
    @MainActor
    func relatedData(for node: ScanNode) -> [ScanNode]? {
        focusedScans["related#\(node.id)"]?.topNodes
    }

    @MainActor
    func findRelatedData(for app: ScanNode) {
        guard app.isPackage, app.name.hasSuffix(".app"), let home = homeLocation,
              relatedScanningID == nil else { return }
        guard let (scope, _) = try? LocationAccessService.resolve(id: home.id) else { return }
        relatedScanningID = app.id
        let appPath = app.path
        let homePath = NSHomeDirectory()
        let key = "related#\(app.id)"
        relatedTask = Task {
            let accessing = LocationAccessService.beginAccess(scope)
            defer { if accessing { scope.stopAccessingSecurityScopedResource() } }
            let candidates = await Task.detached(priority: .userInitiated) {
                RelatedDataService.candidates(appPath: appPath, home: homePath)
            }.value
            var nodes: [ScanNode] = []
            for c in candidates {
                if Task.isCancelled { break }
                guard let st = ScanEngine.lstat(path: c.path) else { continue }
                let url = URL(fileURLWithPath: c.path)
                let name = url.lastPathComponent
                if st.isDir {
                    let result = await Task.detached(priority: .userInitiated) {
                        await ScanEngine.scan(locationID: "\(home.id)#\(c.path)", rootName: name, root: url) { _ in }
                    }.value
                    nodes.append(ScanNode(id: "\(home.id)#\(c.path)", name: name, path: c.path,
                                          isFolder: true, isPackage: false, category: .system,
                                          logicalBytes: result.totalBytes, modified: st.modified,
                                          childCount: result.itemCount,
                                          fsFileNumber: st.ino, fsVolumeNumber: st.dev,
                                          allocatedBytes: result.totalAllocated,
                                          ownedByOthers: st.uid != ScanEngine.currentUID))
                } else {
                    nodes.append(ScanNode(id: "\(home.id)#\(c.path)", name: name, path: c.path,
                                          isFolder: false, category: .system,
                                          logicalBytes: st.size, modified: st.modified, childCount: 0,
                                          fsFileNumber: st.ino, fsVolumeNumber: st.dev,
                                          allocatedBytes: st.allocated, hardLinkCount: st.links,
                                          ownedByOthers: st.uid != ScanEngine.currentUID))
                }
            }
            guard !Task.isCancelled else { self.relatedScanningID = nil; return }
            self.relatedEvidence[key] = Dictionary(uniqueKeysWithValues: candidates.map { ($0.path, "\($0.kind). \($0.evidence).") })
            self.focusedScans[key] = ScanResult(locationID: key, rootName: app.name,
                                                totalBytes: nodes.reduce(0) { $0 + $1.logicalBytes },
                                                totalAllocated: nodes.reduce(0) { $0 + ($1.allocatedBytes ?? 0) },
                                                itemCount: nodes.count,
                                                topNodes: nodes.sorted { $0.logicalBytes > $1.logicalBytes },
                                                issues: [], startedAt: Date(), finishedAt: Date(), wasCancelled: false)
            self.rebuildIndex()
            self.relatedScanningID = nil
        }
    }

    @MainActor
    func cancelRelatedData() {
        relatedTask?.cancel()
        relatedScanningID = nil
    }

    // MARK: - Drag and drop

    /// Stage dropped file URLs that belong to a scanned location.
    @MainActor
    func stage(urls: [URL], source: String) -> Int {
        var staged = 0
        let byPath = Dictionary(nodeIndex.values.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        for url in urls {
            let path = url.standardizedFileURL.path
            guard let node = byPath[path], canReview(node), !isQueued(node.id) else { continue }
            toggleReview(node, source: source)
            staged += 1
        }
        return staged
    }
}
