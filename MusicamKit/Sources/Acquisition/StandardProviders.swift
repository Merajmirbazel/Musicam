import Foundation

extension ProviderRegistry {
    /// The providers Musicam ships with. Internet Archive goes first because it is the more specific one: its file links
    /// are also plain audio links, which the direct-audio provider would accept too.
    /// When `onDevice` is given, Spotify links are fetched on this device by the engine the app installed (iPhone).
    /// When `merajfy` is given, Spotify links are fetched through the Merajfy helper (while its config is set).
    public static func standard(downloadsDirectory: URL, session: URLSession = .shared, merajfy: MerajfyConfigStore? = nil,
                                onDevice: OnDeviceSwitch? = nil) -> ProviderRegistry {
        let registry = ProviderRegistry()
        if let onDevice {
            try? registry.register(MerajfyLocalProvider(directory: downloadsDirectory, gate: onDevice, session: session))
        }
        if let merajfy {
            try? registry.register(MerajfyProvider(directory: downloadsDirectory, config: merajfy, session: session))
        }
        try? registry.register(InternetArchiveProvider(directory: downloadsDirectory, session: session))
        try? registry.register(DirectAudioProvider(directory: downloadsDirectory, session: session))
        return registry
    }
}
