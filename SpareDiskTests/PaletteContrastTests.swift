import SwiftUI
import Testing
@testable import SpareDisk

/// Every map fill must keep its label text at WCAG AA (4.5:1) in both
/// appearances, in normal and emphasized states.
struct PaletteContrastTests {
    private func blend(_ c: (r: Double, g: Double, b: Double), alpha: Double, over bg: Double) -> (r: Double, g: Double, b: Double) {
        (c.r * alpha + bg * (1 - alpha), c.g * alpha + bg * (1 - alpha), c.b * alpha + bg * (1 - alpha))
    }

    @Test func everyMapFillClearsAAForLabelText() {
        for scheme in [ColorScheme.light, .dark] {
            let bg = scheme == .dark ? 0.118 : 1.0
            let text: (r: Double, g: Double, b: Double) = scheme == .dark ? (1, 1, 1) : (0, 0, 0)
            for i in 0..<SDTheme.hueCount {
                for emphasized in [false, true] {
                    let fill = blend(SDTheme.hueComponents(i, scheme: scheme),
                                     alpha: SDTheme.mapFillOpacity(scheme: scheme, emphasized: emphasized), over: bg)
                    let ratio = SDTheme.contrast(fill, text)
                    #expect(ratio >= 4.5, "hue \(i) \(scheme) emphasized=\(emphasized) ratio \(ratio)")
                }
            }
        }
    }
}
