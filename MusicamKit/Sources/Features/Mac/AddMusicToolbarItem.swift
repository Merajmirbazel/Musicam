#if os(macOS)
import SwiftUI

struct AddMusicToolbarItem: ToolbarContent {
    @Environment(AppModel.self) private var app

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("Add from Link…", systemImage: "link.badge.plus") { app.showLinkSheet = true }
                .help("Paste a link")
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Add Music", systemImage: "plus", action: addMusic)
                .help("Add songs or folders (⌘O)")
        }
    }

    private func addMusic() {
        app.showImporter = true
    }
}
#endif
