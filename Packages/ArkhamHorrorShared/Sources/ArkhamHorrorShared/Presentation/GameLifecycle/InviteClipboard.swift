import Foundation

#if canImport(AppKit)
    import AppKit
#endif
#if canImport(UIKit)
    import UIKit
#endif

enum InviteClipboard {
    static var canCopy: Bool {
        #if os(tvOS)
            false
        #elseif canImport(UIKit) || canImport(AppKit)
            true
        #else
            false
        #endif
    }

    @MainActor
    static func copy(_ value: String) {
        #if os(tvOS)
            _ = value
        #elseif canImport(UIKit)
            UIPasteboard.general.string = value
        #elseif canImport(AppKit)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        #else
            _ = value
        #endif
    }
}
