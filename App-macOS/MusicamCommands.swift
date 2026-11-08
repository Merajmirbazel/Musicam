import SwiftUI
import Features

/// Menu bar commands: adding music and playback controls with the usual keyboard shortcuts.
struct MusicamCommands: Commands {
    let model: AppModel?

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Music…", action: addMusic)
                .keyboardShortcut("o")
                .disabled(model == nil)
        }
        CommandMenu("Playback") {
            Button("Play / Pause") { model?.playback.togglePlay() }
            Button("Next Song") { model?.playback.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Previous Song") { model?.playback.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Divider()
            Button("Shuffle") { model.map { $0.playback.setShuffle(!$0.playback.isShuffled) } }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Repeat") { model?.playback.cycleRepeat() }
                .keyboardShortcut("r", modifiers: [.command, .option])
        }
    }

    private func addMusic() {
        model?.showImporter = true
    }
}
