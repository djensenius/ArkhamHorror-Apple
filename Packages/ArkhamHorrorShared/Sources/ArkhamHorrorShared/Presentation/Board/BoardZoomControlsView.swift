import SwiftUI

/// A small on-screen zoom control cluster for touch/pointer platforms. These buttons mutate
/// camera zoom directly so they never inherit prompt-specific keyboard +/- amount behavior.
struct BoardZoomControlsView: View {
    let controller: BoardCommandController

    var body: some View {
        HStack(spacing: 12) {
            Button {
                controller.zoomOut()
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .accessibilityLabel(Text("Zoom out"))
            Button {
                controller.handle(.command(.resetCamera))
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .accessibilityLabel(Text("Reset view"))
            Button {
                controller.zoomIn()
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .accessibilityLabel(Text("Zoom in"))
        }
        .buttonStyle(.bordered)
    }
}
