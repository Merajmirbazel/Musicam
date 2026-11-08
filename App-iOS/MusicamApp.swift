import SwiftUI
import Domain
import Features
import Acquisition

@main
struct MusicamApp: App {
    private let model: AppModel?

    init() {
        // downloads that run on this iPhone (Python + yt-dlp inside the app); must be installed before the model reads its settings
        OnDeviceEngine.install(OnDeviceYouTubeEngine())
        model = try? AppModel.live()
    }

    var body: some Scene {
        WindowGroup {
            if let model {
                IOSRootView()
                    .environment(model)
                    // "Open in Musicam" / Copy to Musicam from the Share Sheet, Files, Telegram and so on
                    .onOpenURL { url in
                        if url.scheme?.lowercased() == "musicam" {
                            // musicam://add?link=… comes from the "Musicam" share extension; musicam://pair?… is a pairing code
                            if url.host?.lowercased() == "add",
                               let link = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "link" })?.value {
                                model.pendingLink = link
                                model.showLinkSheet = true
                            } else {
                                Task { await model.sync.join(code: url.absoluteString) }
                            }
                        }
                        else { model.importPicked([url], source: TrackSource.shared.raw) }
                    }
                    #if DEBUG
                    .task { await DebugSupport.run(model) }
                    #endif
            } else {
                ContentUnavailableView("Musicam could not open your library", systemImage: "exclamationmark.triangle")
            }
        }
    }
}
