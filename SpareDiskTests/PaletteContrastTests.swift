import SwiftUI
import Testing
@testable import SpareDisk

/// Every map fill in every color mode must keep its label text at WCAG AA
/// (4.5:1) in both appearances, in normal and emphasized states. Labels
/// pick white or near-black against the fill they actually sit on.
struct PaletteContrastTests {
    private func check(_ base: (r: Double, g: Double, b: Double), scheme: ColorScheme, what: String) {
        for emphasized in [false, true] {
            let alpha = SDTheme.mapFillOpacity(scheme: scheme, emphasized: emphasized)
            let fill = SDTheme.effectiveFill(base, alpha: alpha, scheme: scheme)
            let ratio = SDTheme.contrast(fill, SDTheme.labelComponents(over: fill))
            #expect(ratio >= 4.5, "\(what) \(scheme) emphasized=\(emphasized) ratio \(ratio)")
        }
    }

    @Test func folderHuesClearAA() {
        for scheme in [ColorScheme.light, .dark] {
            for i in 0..<SDTheme.hueCount { check(SDTheme.hueComponents(i, scheme: scheme), scheme: scheme, what: "hue \(i)") }
        }
    }

    @Test func typeColorsClearAA() {
        for scheme in [ColorScheme.light, .dark] {
            for c in SDFileCategory.allCases { check(SDTheme.categoryComponents(c, scheme: scheme), scheme: scheme, what: c.rawValue) }
        }
    }

    @Test func ageColorsClearAA() {
        for scheme in [ColorScheme.light, .dark] {
            for b in 0..<SDTheme.ageBuckets.count { check(SDTheme.ageComponents(bucket: b, scheme: scheme), scheme: scheme, what: "age \(b)") }
        }
    }
    @Test func missingDatesAreNotOldFiles() {
        #expect(SDTheme.ageBucket(for: nil) == -1)
        for scheme in [ColorScheme.light, .dark] {
            check(SDTheme.ageComponents(bucket: -1, scheme: scheme), scheme: scheme, what: "unknown date")
            let unknown = SDTheme.ageComponents(bucket: -1, scheme: scheme)
            let oldest = SDTheme.ageComponents(bucket: 0, scheme: scheme)
            #expect(SDTheme.luminance(unknown) != SDTheme.luminance(oldest))
        }
    }

    @Test func colourIdentitySurvivesRankingAliasesAndSizeChanges() {
        let original = ScanNode(id: "tree-file", name: "file", path: "/review/folder/file", isFolder: false,
                                category: .documents, logicalBytes: 100, modified: nil, childCount: 0)
        let first = SDTheme.mapComponents(for: original, mode: .folder, scheme: .dark)
        let alias = ScanNode(id: "scan#/review/folder/file", name: "file", path: original.path, isFolder: false,
                             category: .documents, logicalBytes: 900_000, modified: nil, childCount: 0)
        let later = SDTheme.mapComponents(for: alias, mode: .folder, scheme: .dark)
        #expect(first.r == later.r && first.g == later.g && first.b == later.b)
        #expect(SDTheme.folderHueIndex(path: "/review/folder/../folder/file") == SDTheme.folderHueIndex(path: original.path))
    }

    @Test func nestedLabelsClearAAAndSemanticColoursKeepTheirMeaning() {
        for scheme in [ColorScheme.light, .dark] {
            for hue in 0..<SDTheme.hueCount {
                let parent = SDTheme.hueComponents(hue, scheme: scheme)
                for i in 0..<24 {
                    let node = ScanNode(id: "child-\(i)", name: "child", path: "/review/child-\(i)", isFolder: false,
                                        category: .archives, logicalBytes: 10, modified: nil, childCount: 0)
                    for mode in [SDMapColor.folder, .type, .age] {
                        let child = SDTheme.childMapComponents(for: node, parent: parent, mode: mode, scheme: scheme)
                        check(child, scheme: scheme, what: "nested \(mode) \(hue)")
                        if mode != .folder {
                            let own = SDTheme.mapComponents(for: node, mode: mode, scheme: scheme)
                            #expect(child.r == own.r && child.g == own.g && child.b == own.b)
                        }
                    }
                }
            }
        }
    }

    @Test func siblingsNeverShareAHueWhenEightOrFewer() {
        let nodes = (0..<8).map { i in
            ScanNode(id: "n\(i)", name: "n\(i)", path: "/level/item-\(i)", isFolder: true, category: .other,
                     logicalBytes: Int64(800 - i * 50), modified: nil, childCount: 1)
        }
        let hues = SDTheme.folderHues(for: nodes) { $0.logicalBytes }
        #expect(Set(hues.values).count == 8)
        // Stable for the same level, and a node with no collision keeps its hashed hue.
        #expect(SDTheme.folderHues(for: nodes) { $0.logicalBytes } == hues)
        let alone = SDTheme.folderHues(for: [nodes[0]]) { $0.logicalBytes }
        #expect(alone["n0"] == SDTheme.folderHueIndex(path: nodes[0].path))
    }

    @Test func syntheticGroupsWithoutPathsStillDiffer() {
        let groups = (0..<4).map { i in
            ScanNode(id: "dupgroup:\(i)", name: "g\(i)", path: "", isFolder: true, category: .other,
                     logicalBytes: Int64(100 - i), modified: nil, childCount: 2)
        }
        #expect(Set(SDTheme.folderHues(for: groups) { $0.logicalBytes }.values).count == 4)
    }

    @Test func neutralsAreDistinctFromEachOtherAndReadable() {
        for scheme in [ColorScheme.light, .dark] {
            let other = SDTheme.neutralComponents(scheme: scheme)
            let folded = SDTheme.foldedComponents(scheme: scheme)
            #expect(abs(SDTheme.luminance(other) - SDTheme.luminance(folded)) > 0.04)
            #expect(SDTheme.contrast(other, SDTheme.backgroundLuminanceComponents(scheme: scheme)) > 1.4)
            check(other, scheme: scheme, what: "other")
            check(folded, scheme: scheme, what: "folded")
        }
    }

    /// Fills must stand off the window they sit on, not only carry their
    /// labels: a shape that matches the background has no boundary.
    @Test func everyFillClearsTheWindowBackground() {
        for scheme in [ColorScheme.light, .dark] {
            let bg = SDTheme.backgroundLuminanceComponents(scheme: scheme)
            let floor = scheme == .dark ? 2.0 : 1.4
            var fills: [(String, SDTheme.RGB)] = []
            for i in 0..<SDTheme.hueCount { fills.append(("hue \(i)", SDTheme.hueComponents(i, scheme: scheme))) }
            for c in SDFileCategory.allCases { fills.append((c.rawValue, SDTheme.categoryComponents(c, scheme: scheme))) }
            for b in 0..<SDTheme.ageBuckets.count { fills.append(("age \(b)", SDTheme.ageComponents(bucket: b, scheme: scheme))) }
            fills.append(("neutral", SDTheme.neutralComponents(scheme: scheme)))
            for (name, fill) in fills {
                let ratio = SDTheme.contrast(fill, bg)
                #expect(ratio >= floor, "\(name) \(scheme) is \(ratio) against the window")
            }
        }
    }

    @Test func ageScaleHasOrderedLightness() {
        let light = SDTheme.ageBuckets.indices.map { SDTheme.luminance(SDTheme.ageComponents(bucket: $0, scheme: .light)) }
        let dark = SDTheme.ageBuckets.indices.map { SDTheme.luminance(SDTheme.ageComponents(bucket: $0, scheme: .dark)) }
        for i in 1..<light.count {
            #expect(light[i] > light[i - 1])
            #expect(dark[i] < dark[i - 1])
        }
    }

}
