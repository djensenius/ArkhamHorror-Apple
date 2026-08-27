import ArkhamHorrorShared
import SwiftUI

@main
struct ArkhamHorrorMacApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }

        Settings {
            Text("Settings will be added in a later phase.")
                .padding()
        }
    }
}
