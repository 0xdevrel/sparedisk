import Foundation
import Testing
@testable import SpareDisk

/// Leftover classification and the Uninstall split are pure and tested.
struct LeftoverTests {
    @Test func entryNamesBecomeBundleIdentifiers() {
        #expect(LeftoverService.bundleID(fromEntryName: "com.acme.SuperApp", suffix: "") == "com.acme.SuperApp")
        #expect(LeftoverService.bundleID(fromEntryName: "com.acme.SuperApp.plist", suffix: ".plist") == "com.acme.SuperApp")
        #expect(LeftoverService.bundleID(fromEntryName: "com.acme.SuperApp.savedState", suffix: ".savedState") == "com.acme.SuperApp")
        #expect(LeftoverService.bundleID(fromEntryName: "ABCDE12345.com.acme.shared", suffix: "") == "com.acme.shared")
        #expect(LeftoverService.bundleID(fromEntryName: "group.com.acme.shared", suffix: "") == "com.acme.shared")
        // Not identifiers: plain names, two-part file names, missing suffix.
        #expect(LeftoverService.bundleID(fromEntryName: "Slack", suffix: "") == nil)
        #expect(LeftoverService.bundleID(fromEntryName: "default.store", suffix: "") == nil)
        #expect(LeftoverService.bundleID(fromEntryName: "com.acme.SuperApp", suffix: ".plist") == nil)
        #expect(LeftoverService.bundleID(fromEntryName: "notes.txt.backup", suffix: "") == nil)
    }

    @Test func displayNamesSkipGenericTails() {
        func g(_ id: String) -> LeftoverGroup { LeftoverGroup(bundleID: id, items: []) }
        #expect(g("com.acme.SuperApp").displayName == "SuperApp")
        #expect(g("com.murmur.app").displayName == "Murmur")
        #expect(g("jan.ai.app").displayName == "Ai")
        #expect(g("org.swift.swiftpm").displayName == "Swiftpm")
    }

    @Test func appleIdentifiersAreSystem() {
        #expect(LeftoverService.isSystem("com.apple.Safari"))
        #expect(!LeftoverService.isSystem("com.appleseed.Tool"))
    }

    @Test func helpersBelongToTheirOwner() {
        let owners = LeftoverService.ownerCandidates("com.acme.SuperApp.Helper.Renderer")
        #expect(owners.first == "com.acme.SuperApp.Helper.Renderer")
        #expect(owners.contains("com.acme.SuperApp"))
        #expect(owners.last == "com.acme.SuperApp")
        let installed: Set<String> = ["com.acme.SuperApp"]
        let entries = [
            LeftoverEntry(bundleID: "com.acme.SuperApp.Helper", path: "/L/Caches/com.acme.SuperApp.Helper", kind: "Cache"),
            LeftoverEntry(bundleID: "com.gone.OldApp", path: "/L/Containers/com.gone.OldApp", kind: "Container"),
        ]
        let orphans = LeftoverService.orphans(entries) { installed.contains($0) }
        #expect(orphans.map(\.bundleID) == ["com.gone.OldApp"])
    }

    @Test func realHomeIsNotTheContainer() {
        #expect(!LeftoverService.realHome.contains("/Library/Containers/"))
    }

    @Test func uninstallSplitsByEvidence() {
        func n(_ p: String) -> ScanNode {
            ScanNode(id: p, name: (p as NSString).lastPathComponent, path: p, isFolder: true, category: .system,
                     logicalBytes: 1, modified: nil, childCount: 1)
        }
        let related = [n("/L/Containers/com.acme.App"), n("/L/Application Support/App"), n("/L/Group Containers/T.com.acme.App")]
        let evidence = ["/L/Containers/com.acme.App": "Container. Bundle identifier com.acme.App.",
                        "/L/Application Support/App": "Application Support. Same name as the app.",
                        "/L/Group Containers/T.com.acme.App": "Group container. Shares identifier com.acme.App."]
        let split = UninstallPlan.split(related: related, evidence: evidence)
        #expect(split.strong.map(\.path) == ["/L/Containers/com.acme.App", "/L/Group Containers/T.com.acme.App"])
        #expect(split.weak.map(\.path) == ["/L/Application Support/App"])
    }
}
