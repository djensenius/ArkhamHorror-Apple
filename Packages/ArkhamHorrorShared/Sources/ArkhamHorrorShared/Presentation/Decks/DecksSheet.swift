import SwiftUI

/// Keep the presenter attached to the sheet's navigation container, including
/// when the deck browser (which can also relink) replaces the root deck list.
struct DecksSheet: View {
    let model: AppModel
    let profile: ServerProfile

    #if !os(tvOS)
        @State private var authentication = ArkhamDBAuthenticationSession()
    #endif

    var body: some View {
        NavigationStack {
            #if os(tvOS)
                DecksView(model: model, profile: profile, authentication: nil)
            #else
                DecksView(model: model, profile: profile, authentication: authentication)
            #endif
        }
        #if !os(tvOS)
        .background {
            ArkhamDBPresentationAnchorReader { [weak authentication] anchor in
                authentication?.updatePresentationAnchor(anchor)
            }
            .accessibilityHidden(true)
        }
        .onDisappear {
            authentication.updatePresentationAnchor(nil)
        }
        #endif
    }
}
