import SwiftUI
#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

extension Color {
    /// A colour from a 24-bit `0xRRGGBB` sRGB value.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// The shared light/dark adaptive colour: resolves to `light` in light appearances and
    /// `dark` in dark appearances (including the increased-contrast variants), backed by the
    /// platform's dynamic `UIColor`/`NSColor` provider so it follows appearance changes live.
    static func adaptive(light: Color, dark: Color) -> Color {
        #if canImport(UIKit)
            let lightColor = UIColor(light)
            let darkColor = UIColor(dark)
            return Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark ? darkColor : lightColor
            })
        #elseif canImport(AppKit)
            let lightColor = NSColor(light)
            let darkColor = NSColor(dark)
            return Color(nsColor: NSColor(name: nil) { appearance in
                let match = appearance.bestMatch(from: [
                    .aqua,
                    .darkAqua,
                    .accessibilityHighContrastAqua,
                    .accessibilityHighContrastDarkAqua,
                ])
                let isDark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
                return isDark ? darkColor : lightColor
            })
        #else
            return light
        #endif
    }

    /// ``adaptive(light:dark:)`` from two 24-bit `0xRRGGBB` sRGB values.
    static func adaptive(lightHex: UInt32, darkHex: UInt32) -> Color {
        adaptive(light: Color(hex: lightHex), dark: Color(hex: darkHex))
    }
}

/// WCAG 2.x relative luminance and contrast ratio for 24-bit `0xRRGGBB` sRGB colours, so
/// fixed palette choices (such as the dark-mode variant of an adaptive colour) can be
/// checked against the 3:1 non-text and 4.5:1 text guidelines in plain unit tests.
enum ArkhamColorContrast {
    /// WCAG 2.x minimum contrast for non-text UI elements such as rules and borders.
    static let minimumNonTextRatio: Double = 3

    static func relativeLuminance(_ hex: UInt32) -> Double {
        func linear(_ channel: UInt32) -> Double {
            let value = Double(channel & 0xFF) / 255
            return value <= 0.040_45 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(hex >> 16) + 0.7152 * linear(hex >> 8) + 0.0722 * linear(hex)
    }

    static func contrastRatio(_ first: UInt32, _ second: UInt32) -> Double {
        let firstLuminance = relativeLuminance(first)
        let secondLuminance = relativeLuminance(second)
        let lighter = max(firstLuminance, secondLuminance)
        let darker = min(firstLuminance, secondLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
}
