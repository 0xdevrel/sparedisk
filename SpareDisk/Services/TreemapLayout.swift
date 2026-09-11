import CoreGraphics
import Foundation

// Bounded squarified treemap layout (Bruls–Huizing–van Wijk, simplified).
// Pure geometry: deterministic input order, clamped non-negative rects, zero
// weights skipped. No view code, no filesystem — unit-tested.
nonisolated struct TreemapFrame: Hashable {
    let id: String
    var rect: CGRect
}

nonisolated enum TreemapLayout {
    /// Lay out `(id, weight)` pairs inside `rect`. Weights are area shares.
    static func squarify(_ entries: [(id: String, weight: CGFloat)], in rect: CGRect) -> [TreemapFrame] {
        let items = entries
            .filter { $0.weight > 0 }
            .sorted { $0.weight == $1.weight ? $0.id < $1.id : $0.weight > $1.weight }
        guard !items.isEmpty, rect.width > 0, rect.height > 0 else { return [] }
        let total = items.reduce(CGFloat(0)) { $0 + $1.weight }
        guard total > 0 else { return [] }
        let scale = (rect.width * rect.height) / total

        var out: [TreemapFrame] = []
        var row: [(id: String, weight: CGFloat)] = []
        var rowSum: CGFloat = 0
        var rest = rect
        var i = 0
        while i < items.count {
            guard rest.width > 0, rest.height > 0 else { break }
            // Rows are laid along the SHORTER side (Bruls et al.): a wide
            // leftover gets a full-height column on its left, a tall one gets
            // a full-width strip on top. Using the longer side inverts the
            // algorithm and produces hairline strips for the last items.
            let side = min(rest.width, rest.height)
            let next = items[i]
            if row.isEmpty
                || worst(row, sum: rowSum, side: side, scale: scale)
                    >= worst(row + [next], sum: rowSum + next.weight, side: side, scale: scale) {
                row.append(next)
                rowSum += next.weight
                i += 1
            } else {
                rest = emit(row, sum: rowSum, from: rest, scale: scale, into: &out)
                row.removeAll(keepingCapacity: true)
                rowSum = 0
            }
        }
        if !row.isEmpty {
            rest = emit(row, sum: rowSum, from: rest, scale: scale, into: &out)
        }
        return out
    }

    /// Worst aspect ratio in a candidate row (lower is better).
    static func worst(_ row: [(id: String, weight: CGFloat)], sum: CGFloat, side: CGFloat, scale: CGFloat) -> CGFloat {
        guard !row.isEmpty, sum > 0, side > 0, scale > 0 else { return .greatestFiniteMagnitude }
        let areas = row.map { $0.weight * scale }
        guard let mx = areas.max(), let mn = areas.min(), mn > 0 else { return .greatestFiniteMagnitude }
        let s = sum * scale
        return max((side * side * mx) / (s * s), (s * s) / (side * side * mn))
    }

    /// Emit one row along the shorter side of `rect`; return the leftover.
    @discardableResult
    private static func emit(_ row: [(id: String, weight: CGFloat)], sum: CGFloat,
                             from rect: CGRect, scale: CGFloat,
                             into out: inout [TreemapFrame]) -> CGRect {
        guard sum > 0 else { return rect }
        if rect.width >= rect.height {
            // Column on the left spanning the full height.
            let w = max(0, (sum * scale) / max(rect.height, 1))
            var y = rect.minY
            for (index, item) in row.enumerated() {
                var h = max(0, (item.weight * scale) / max(w, 1))
                if index == row.count - 1 { h = max(0, rect.maxY - y) } // absorb float error
                out.append(TreemapFrame(id: item.id, rect: CGRect(x: rect.minX, y: y, width: w, height: h)))
                y += h
            }
            return CGRect(x: rect.minX + w, y: rect.minY, width: max(0, rect.width - w), height: rect.height)
        } else {
            // Strip on top spanning the full width.
            let h = max(0, (sum * scale) / max(rect.width, 1))
            var x = rect.minX
            for (index, item) in row.enumerated() {
                var w = max(0, (item.weight * scale) / max(h, 1))
                if index == row.count - 1 { w = max(0, rect.maxX - x) }
                out.append(TreemapFrame(id: item.id, rect: CGRect(x: x, y: rect.minY, width: w, height: h)))
                x += w
            }
            return CGRect(x: rect.minX, y: rect.minY + h, width: rect.width, height: max(0, rect.height - h))
        }
    }
}
