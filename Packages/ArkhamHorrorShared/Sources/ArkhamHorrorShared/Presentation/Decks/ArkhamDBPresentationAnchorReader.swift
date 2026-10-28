#if !os(tvOS)
    import AuthenticationServices
    import SwiftUI

    #if os(macOS)
        struct ArkhamDBPresentationAnchorReader: NSViewRepresentable {
            let onChange: @MainActor (ASPresentationAnchor?) -> Void

            func makeNSView(context _: Context) -> ArkhamDBAnchorView {
                let view = ArkhamDBAnchorView()
                view.onChange = onChange
                return view
            }

            func updateNSView(_: ArkhamDBAnchorView, context _: Context) {}

            static func dismantleNSView(_ view: ArkhamDBAnchorView, coordinator _: ()) {
                view.onChange(nil)
            }
        }

        final class ArkhamDBAnchorView: NSView {
            var onChange: @MainActor (ASPresentationAnchor?) -> Void = { _ in }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                onChange(window)
            }
        }
    #else
        struct ArkhamDBPresentationAnchorReader: UIViewRepresentable {
            let onChange: @MainActor (ASPresentationAnchor?) -> Void

            func makeUIView(context _: Context) -> ArkhamDBAnchorView {
                let view = ArkhamDBAnchorView()
                view.isUserInteractionEnabled = false
                view.isHidden = true
                view.onChange = onChange
                return view
            }

            func updateUIView(_: ArkhamDBAnchorView, context _: Context) {}

            static func dismantleUIView(_ view: ArkhamDBAnchorView, coordinator _: ()) {
                view.onChange(nil)
            }
        }

        final class ArkhamDBAnchorView: UIView {
            var onChange: @MainActor (ASPresentationAnchor?) -> Void = { _ in }

            override func didMoveToWindow() {
                super.didMoveToWindow()
                onChange(window)
            }
        }
    #endif
#endif
