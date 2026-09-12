import AppKit
import Foundation

// Leftovers and Uninstall. Both end in the same review queue and Trash
// flow as everything else; neither removes anything on its own.
extension AppState {
    static let leftoverKey = "leftovers"

    /// An application with this identifier, or one of its owning prefixes,
    /// exists on this Mac or is running. LaunchServices answers without any
    /// folder grant.
    @MainActor
    func isAppInstalled(_ bundleID: String) -> Bool {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            // A copy in the Trash or in a build folder is not an installation.
            let p = url.path
            let discarded = p.contains("/.Trash/") || p.contains("/DerivedData/") || p.contains("/Build/Products/")
            if !discarded { return true }
        }
        return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    @MainActor
    func findLeftovers() {
        guard let home = homeLocation, leftoverTask == nil else { return }
        guard let (scope, _) = try? LocationAccessService.resolve(id: home.id) else {
            leftoverNotice = "Your home folder needs to be chosen again before its Library can be read."
            return
        }
        leftoverRunning = true
        leftoverNotice = nil
        let homePath = LeftoverService.realHome
        leftoverTask = Task {
            defer { leftoverTask = nil; leftoverRunning = false }
            let accessing = LocationAccessService.beginAccess(scope)
            defer { if accessing { scope.stopAccessingSecurityScopedResource() } }
            let all = await Task.detached(priority: .userInitiated) { LeftoverService.entries(home: homePath) }.value
            let orphans = LeftoverService.orphans(all) { self.isAppInstalled($0) }
            var nodes: [ScanNode] = []
            var kinds: [String: String] = [:]
            for e in orphans {
                if Task.isCancelled { return }
                guard let st = ScanEngine.lstat(path: e.path) else { continue }
                let url = URL(fileURLWithPath: e.path)
                let id = "\(home.id)#\(e.path)"
                kinds[e.path] = e.kind
                if st.isDir {
                    let result = await Task.detached(priority: .utility) {
                        await ScanEngine.scan(locationID: id, rootName: url.lastPathComponent, root: url) { _ in }
                    }.value
                    nodes.append(ScanNode(id: id, name: url.lastPathComponent, path: e.path,
                                          isFolder: true, isPackage: false, category: .system,
                                          logicalBytes: result.totalBytes, modified: st.modified,
                                          childCount: result.itemCount,
                                          fsFileNumber: st.ino, fsVolumeNumber: st.dev,
                                          allocatedBytes: result.totalAllocated,
                                          ownedByOthers: st.uid != ScanEngine.currentUID))
                } else {
                    nodes.append(ScanNode(id: id, name: url.lastPathComponent, path: e.path,
                                          isFolder: false, category: .system,
                                          logicalBytes: st.size, modified: st.modified, childCount: 0,
                                          fsFileNumber: st.ino, fsVolumeNumber: st.dev,
                                          allocatedBytes: st.allocated, hardLinkCount: st.links,
                                          ownedByOthers: st.uid != ScanEngine.currentUID))
                }
            }
            var byID: [String: [ScanNode]] = [:]
            for (e, n) in zip(orphans.filter { ScanEngine.lstat(path: $0.path) != nil }, nodes) { byID[e.bundleID, default: []].append(n) }
            let groups = byID.map { LeftoverGroup(bundleID: $0.key, items: $0.value.sorted { $0.logicalBytes > $1.logicalBytes }) }
                .sorted { $0.bytes > $1.bytes }
            self.leftoverKinds = kinds
            self.leftoverGroups = groups
            self.focusedScans[Self.leftoverKey] = ScanResult(
                locationID: Self.leftoverKey, rootName: "Leftovers",
                totalBytes: nodes.reduce(0) { $0 + $1.logicalBytes },
                totalAllocated: nodes.reduce(0) { $0 + ($1.allocatedBytes ?? 0) },
                itemCount: nodes.count, topNodes: nodes, issues: [],
                startedAt: Date(), finishedAt: Date(), wasCancelled: false)
            self.rebuildIndex()
            self.leftoverNotice = groups.isEmpty
                ? "No leftovers found. Every identifier under your Library belongs to an installed or running app."
                : "\(groups.count) \(groups.count == 1 ? "app" : "apps") left data behind, \(SDFormat.bytesString(groups.reduce(0) { $0 + $1.bytes })) in all."
        }
    }

    @MainActor
    func cancelLeftovers() {
        leftoverTask?.cancel()
        leftoverTask = nil
        leftoverRunning = false
    }

    // MARK: - Uninstall

    /// Build the proposal for an app: run the related-data lookup if it has
    /// not run yet, then split matches by evidence. Nothing is staged here.
    @MainActor
    func prepareUninstall(_ app: ScanNode) {
        guard app.isPackage, app.name.hasSuffix(".app") else { return }
        uninstallPreparingID = app.id
        Task {
            defer { uninstallPreparingID = nil }
            if relatedData(for: app) == nil, homeLocation != nil {
                findRelatedData(for: app)
                await relatedTask?.value
            }
            let related = relatedData(for: app) ?? []
            let split = UninstallPlan.split(related: related, evidence: relatedEvidence["related#\(app.id)"] ?? [:])
            uninstallPlan = UninstallPlan(app: app, strong: split.strong, weak: split.weak)
        }
    }

    /// Stage the chosen items and go to Review.
    @MainActor
    func stageUninstall(_ plan: UninstallPlan, chosen: Set<String>) {
        let items = ([plan.app] + plan.strong + plan.weak).filter { chosen.contains($0.id) }
        addToReview(items, source: "Uninstall")
        uninstallPlan = nil
        selection = .review
    }
}
