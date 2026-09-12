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
}
