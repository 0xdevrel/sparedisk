import CoreGraphics
import Testing
@testable import SpareDisk

/// Geometry-contract tests for the map (P2 review finding): conservation,
/// clamping, determinism, honest edge handling.
struct TreemapLayoutTests {
    private let box = CGRect(x: 0, y: 0, width: 600, height: 400)

    @Test func emptyAndZeroWeightsYieldNothing() {
        #expect(TreemapLayout.squarify([], in: box).isEmpty)
        #expect(TreemapLayout.squarify([("a", 0.0), ("b", -3.0)], in: box).isEmpty)
        #expect(TreemapLayout.squarify([("a", 5.0)], in: .zero).isEmpty)
    }

    @Test func singleItemFillsContainer() {
        let frames = TreemapLayout.squarify([("a", 10.0)], in: box)
        #expect(frames.count == 1)
        #expect(frames[0].rect == box)
    }

    @Test func areasConservedAndNonNegative() {
        let frames = TreemapLayout.squarify(
            [("a", 42.0), ("b", 28.0), ("c", 18.0), ("d", 12.0), ("e", 6.0), ("f", 2.0), ("g", 1.0)], in: box)
        #expect(frames.count == 7)
        for f in frames {
            #expect(f.rect.width >= 0)
            #expect(f.rect.height >= 0)
        }
        let area = frames.reduce(CGFloat(0)) { $0 + $1.rect.width * $1.rect.height }
        #expect(abs(area - box.width * box.height) < 1)
    }

    @Test func largerWeightGetsLargerArea() {
        let frames = TreemapLayout.squarify([("big", 3.0), ("small", 1.0)], in: box)
        let areas = Dictionary(uniqueKeysWithValues: frames.map {
            ($0.id, $0.rect.width * $0.rect.height)
        })
        #expect(abs(areas["big"]! / areas["small"]! - 3) < 0.05)
    }

    @Test func layoutIsDeterministic() {
        let input: [(id: String, weight: CGFloat)] = [("a", 9.0), ("b", 9.0), ("c", 4.0), ("d", 4.0), ("e", 1.0)]
        let first = TreemapLayout.squarify(input, in: box)
        let second = TreemapLayout.squarify(input, in: box)
        #expect(first == second)
    }

    /// Regression for the inverted-side bug: real Downloads data at the real
    /// map size produced a 918×11 strip (aspect 80). Proper squarify keeps
    /// every cell readable.
    @Test func realWorldDataKeepsAspectRatiosBounded() {
        let mb: [(id: String, weight: CGFloat)] = [
            ("android", 1520), ("mp4", 798.7), ("other", 594), ("lm", 553.2), ("ollama", 452.2),
            ("blender", 346.3), ("bs1", 326.2), ("bs2", 297.1), ("cursor", 246.5), ("zcode", 235.5),
            ("comet", 224.1), ("grok", 152), ("void", 147.1), ("zed", 133.7), ("cf", 130.3), ("dyad", 123.5),
        ]
        let frames = TreemapLayout.squarify(mb, in: CGRect(x: 0, y: 0, width: 918, height: 580))
        #expect(frames.count == mb.count)
        for f in frames {
            let aspect = max(f.rect.width / f.rect.height, f.rect.height / f.rect.width)
            #expect(aspect < 4, "\(f.id) has aspect \(aspect)")
            #expect(f.rect.width >= 40 && f.rect.height >= 40, "\(f.id) is \(f.rect.size)")
        }
        let area = frames.reduce(CGFloat(0)) { $0 + $1.rect.width * $1.rect.height }
        #expect(abs(area - 918 * 580) < 1)
    }
}
