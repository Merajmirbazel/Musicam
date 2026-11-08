import SwiftUI
import Features

@main
struct MusicamMacApp: App {
    private let model: AppModel?
    private let launchError: String?

    init() {
        do {
            model = try AppModel.live()
            launchError = nil
        } catch {
            model = nil
            launchError = error.localizedDescription
        }
    }

    var body: some Scene {
        WindowGroup {
            if let model {
                MacRootView()
                    .environment(model)
                    .frame(minWidth: 980, minHeight: 620)
                    #if DEBUG
                    .task { await DebugSupport.run(model) }
                    #endif
            } else {
                LaunchFailureView(message: launchError ?? "Unknown error")
            }
        }
        .defaultSize(width: 1180, height: 760)
        .commands { MusicamCommands(model: model) }
        #if os(macOS)
        Settings {
            if let model {
                NavigationStack { SettingsView() }
                .environment(model)
                .frame(width: 520, height: 440)
            }
        }
        #endif
    }
}
