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
}
