#if DEBUG
import Foundation
import Features

/// Debug builds only: `-MusicamDemo YES` makes sample songs and imports them, so the app can be tried without music.
/// `-MusicamPairCode <code>` joins an existing pairing.
@MainActor
enum DebugSupport {
    static func run(_ model: AppModel) async {
        if let code = UserDefaults.standard.string(forKey: "MusicamPairCode") {
            await model.library.load()
            await model.sync.join(code: code)
            if UserDefaults.standard.bool(forKey: "MusicamOffline") {
                model.offline.settings.enabled = true     // keeps favorites
            }
        }
        if let link = UserDefaults.standard.string(forKey: "MusicamAddLink") {
            await model.wishlist.load()
            let t0 = Date()
            let outcome = await model.wishlist.submit(link)
            // debug only: what happened, and how long it took, for automated checks
            let text = "\(outcome) after \(Int(Date().timeIntervalSince(t0))) s"
            try? text.write(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("link-outcome.txt"), atomically: true, encoding: .utf8)
        }
        guard UserDefaults.standard.bool(forKey: "MusicamDemo") else { return }
        await model.library.load()
        guard model.library.tracks.isEmpty else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MusicamSamples", isDirectory: true)
        guard let urls = try? await SampleSongs.generate(into: folder) else { return }
        model.library.startImport(urls)
    }
}
#endif
