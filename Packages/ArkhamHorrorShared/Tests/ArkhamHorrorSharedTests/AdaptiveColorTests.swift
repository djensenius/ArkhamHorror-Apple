@testable import ArkhamHorrorShared
import SwiftUI
import Testing
#if canImport(AppKit)
    import AppKit
#endif
#if canImport(UIKit)
    import UIKit
#endif

@MainActor
@Suite("Adaptive colour")
struct AdaptiveColorTests {
    @Test("The Return to colour resolves to the dark teal in dark mode and #2d6a62 in light")
    func returnToColorResolvesPerAppearance() throws {
        let color = StoryReturnToEntryPresentation.color
        #if os(macOS)
            let dark = try resolved(color, appearance: .darkAqua)
            let light = try resolved(color, appearance: .aqua)
        #elseif canImport(UIKit)
            let dark = try resolved(color, style: .dark)
            let light = try resolved(color, style: .light)
        #endif
        expect(dark, matches: StoryReturnToEntryPresentation.darkColorHex)
        expect(light, matches: StoryReturnToEntryPresentation.colorHex)
    }

    private func expect(_ components: [Double], matches hex: UInt32) {
        let expected = [hex >> 16, hex >> 8, hex].map { Double($0 & 0xFF) / 255 }
        #expect(components.count == 3)
        for (actual, wanted) in zip(components, expected) {
            #expect(abs(actual - wanted) < 1.0 / 255, "component of \(String(hex, radix: 16))")
        }
    }

    #if os(macOS)
        private func resolved(
            _ color: Color,
            appearance name: NSAppearance.Name
        ) throws -> [Double] {
            let appearance = try #require(NSAppearance(named: name))
            var components: [Double] = []
            appearance.performAsCurrentDrawingAppearance {
                if let sRGB = NSColor(color).usingColorSpace(.sRGB) {
                    components = [sRGB.redComponent, sRGB.greenComponent, sRGB.blueComponent]
                        .map { Double($0) }
                }
            }
            return components
        }

    #elseif canImport(UIKit)
        private func resolved(_ color: Color, style: UIUserInterfaceStyle) throws -> [Double] {
            let resolvedColor = UIColor(color)
                .resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            try #require(resolvedColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
            return [red, green, blue].map { Double($0) }
        }
    #endif
}
