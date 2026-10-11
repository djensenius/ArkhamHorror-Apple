import CoreText
import Foundation

struct CoreTextWebIconFontRegistrar: WebIconFontRegistering {
    func validateAndRegister(
        _ data: Data,
        expectedFamily: WebIconFontFamily,
        requiredGlyphs: [StoryIconGlyph]
    ) throws -> WebIconFontRegistration {
        let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData)
            as? [CTFontDescriptor]
        let provider: CGDataProvider? = CGDataProvider(data: data as CFData)
        let cgFont: CGFont?
        if let provider {
            cgFont = CGFont(provider)
        } else {
            cgFont = nil
        }
        guard descriptors?.isEmpty == false || cgFont != nil else {
            throw WebIconFontFailure.invalidFont
        }
        guard let cgFont, let postScriptName = cgFont.postScriptName as String? else {
            throw WebIconFontFailure.invalidFont
        }
        let byteFont = CTFontCreateWithGraphicsFont(cgFont, 17, nil, nil)
        let byteSupportedScalars = Self.supportedScalars(
            requiredGlyphs.map(\.scalar),
            in: byteFont
        )
        guard !byteSupportedScalars.isEmpty else { throw WebIconFontFailure.invalidFont }

        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterGraphicsFont(cgFont, &error) {
            let cfError: CFError? = error?.takeRetainedValue()
            let nsError: NSError? = cfError.map { $0 as Error as NSError }
            let code: Int? = nsError?.code
            guard Self.isAlreadyRegistered(code), Self.resolvedFont(named: postScriptName) != nil
            else { throw WebIconFontFailure.registrationFailed(code) }
        }
        guard let resolvedFont = Self.resolvedFont(named: postScriptName) else {
            throw WebIconFontFailure.invalidFont
        }
        let supportedScalars = Self.supportedScalars(
            requiredGlyphs.map(\.scalar),
            in: resolvedFont
        )
        guard !supportedScalars.isEmpty else { throw WebIconFontFailure.invalidFont }
        return WebIconFontRegistration(
            family: expectedFamily,
            postScriptName: postScriptName,
            supportedScalars: supportedScalars
        )
    }

    private static func isAlreadyRegistered(_ code: Int?) -> Bool {
        code == CTFontManagerError.alreadyRegistered.rawValue
            || code == CTFontManagerError.duplicatedName.rawValue
    }

    private static func resolvedFont(named postScriptName: String) -> CTFont? {
        let font = CTFontCreateWithName(postScriptName as CFString, 17, nil)
        guard CTFontCopyPostScriptName(font) as String == postScriptName else { return nil }
        return font
    }

    private static func supportedScalars(
        _ scalars: [UnicodeScalar],
        in font: CTFont
    ) -> Set<UInt32> {
        Set(scalars.compactMap { scalar in
            let utf16 = Array(String(scalar).utf16)
            var glyphs = Array(repeating: CGGlyph(), count: utf16.count)
            var characters = utf16
            guard CTFontGetGlyphsForCharacters(font, &characters, &glyphs, utf16.count),
                  glyphs.allSatisfy({ $0 != 0 })
            else { return nil }
            return scalar.value
        })
    }
}
