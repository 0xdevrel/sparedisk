import Foundation
import Testing
@testable import SpareDisk

/// Related-data discovery must find identifier-based matches, label
/// name-based ones as weaker evidence, and skip anything that is not there.
struct RelatedDataTests {
    @Test func findsContainersByBundleIdentifierAndName() throws {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let home = base.appendingPathComponent("SpareDiskTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        let app = home.appendingPathComponent("Apps/Demo.app/Contents")
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.example.demo"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        for rel in ["Library/Preferences", "Library/Containers/com.example.demo/Data", "Library/Caches/com.example.demo",
                    "Library/Application Support/Demo", "Library/Group Containers/ABCD.com.example.demo"] {
            try fm.createDirectory(at: home.appendingPathComponent(rel), withIntermediateDirectories: true)
        }
        try Data([1]).write(to: home.appendingPathComponent("Library/Preferences/com.example.demo.plist"),
                            options: .atomic)

        #expect(RelatedDataService.bundleIdentifier(appPath: home.appendingPathComponent("Apps/Demo.app").path) == "com.example.demo")
        let found = RelatedDataService.candidates(appPath: home.appendingPathComponent("Apps/Demo.app").path, home: home.path)
        let paths = Set(found.map { $0.path.replacingOccurrences(of: home.path + "/", with: "") })
        #expect(paths.contains("Library/Containers/com.example.demo"))
        #expect(paths.contains("Library/Caches/com.example.demo"))
        #expect(paths.contains("Library/Preferences/com.example.demo.plist"))
        #expect(paths.contains("Library/Group Containers/ABCD.com.example.demo"))
        #expect(paths.contains("Library/Application Support/Demo"))
        #expect(!paths.contains("Library/Logs/com.example.demo"))
        let byName = try #require(found.first { $0.path.hasSuffix("Application Support/Demo") })
        #expect(byName.evidence.contains("name"))
        let byID = try #require(found.first { $0.path.hasSuffix("Containers/com.example.demo") })
        #expect(byID.evidence.contains("com.example.demo"))
    }

    @Test @MainActor func droppedURLsStageOnlyKnownReviewableItems() {
        let app = AppState()
        app.locations = [SDLocation(id: "/tmp/scope", name: "Scope", symbol: "folder", isExternal: false,
                                    access: .available, capacityBytes: 0, availableBytes: 0,
                                    scannedBytes: 0, scannedAt: Date(), issues: 0)]
        let ok = ScanNode(id: "/tmp/scope/a.txt", name: "a.txt", path: "/tmp/scope/a.txt", isFolder: false,
                          category: .documents, logicalBytes: 10, modified: nil, childCount: 0)
        let root = ScanNode(id: "/tmp/scope/r.txt", name: "r.txt", path: "/tmp/scope/r.txt", isFolder: false,
                            category: .documents, logicalBytes: 10, modified: nil, childCount: 0, ownedByOthers: true)
        app.nodeIndex = [ok.id: ok, root.id: root]
        let staged = app.stage(urls: [URL(fileURLWithPath: ok.path), URL(fileURLWithPath: root.path),
                                      URL(fileURLWithPath: "/tmp/scope/unknown.txt")], source: "Test")
        #expect(staged == 1)
        #expect(app.reviewItems.map(\.id) == [ok.id])
    }
}
