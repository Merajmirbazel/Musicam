import SwiftUI

/// Shown instead of a crash if the library cannot be opened.
struct LaunchFailureView: View {
    let message: String

    var body: some View {
        ContentUnavailableView("Musicam could not open your library", systemImage: "exclamationmark.triangle",
                               description: Text(message))
            .frame(minWidth: 480, minHeight: 320)
    }
}
