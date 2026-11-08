import Foundation
import Observation
import Acquisition

/// The person's choices for the Merajfy helper (the program that fetches Spotify songs). It is on by default; while it
/// cannot work (no built-in helper, or no address on the iPhone) Spotify links still go to the Wishlist by name.
///
/// On the Mac the helper can be built in (it ships inside Musicam.app and runs in the app's sandbox) or an external
/// Merajfy; on the iPhone it is always an external Merajfy on a Mac.
/// Every change is saved and pushed into `store`, which the acquisition provider reads.
@MainActor
@Observable
public final class MerajfySettings {
    public enum Status: Equatable {
        case idle
        case testing
        case ok(String)
        case failed(String)
    }

    /// Where the songs come from. `builtIn` runs inside this app: the helper programs on the Mac, Python + yt-dlp on the iPhone.
    public enum Mode: String, Sendable {
        case builtIn, external
    }

    public static let formats = ["mp3", "m4a", "flac", "opus", "wav"]
    /// Where an external Merajfy listens when it runs on this Mac.
    public static let localAddress = "127.0.0.1:8787"

    public var isEnabled: Bool { didSet { changed() } }
    public var mode: Mode { didSet { changed() } }
    public var address: String { didSet { changed() } }
    public var token: String { didSet { changed() } }
    public var format: String { didSet { changed() } }
    /// Built-in mode only: also answer other devices on the network (the iPhone), protected by `lanToken`.
    public var shareWithIPhone: Bool { didSet { changed() } }
    public private(set) var lanToken: String
    public private(set) var status: Status = .idle

    /// What the acquisition provider reads.
    @ObservationIgnored public let store: MerajfyConfigStore
    /// Read by the on-device provider (iPhone): on only while the feature is on, the mode is built in, and the app has an engine.
    @ObservationIgnored public let onDevice = OnDeviceSwitch()
    /// True when this build can download on the device itself (the iPhone app with embedded Python).
    public var onDeviceAvailable: Bool { OnDeviceEngine.current != nil }
    @ObservationIgnored private let defaults: UserDefaults
    #if os(macOS)
    public let embedded: EmbeddedMerajfy
    @ObservationIgnored private var embeddedKey = ""
    #endif

    private enum Key {
        static let enabled = "musicam.merajfy.enabled"
        static let mode = "musicam.merajfy.mode"
        static let address = "musicam.merajfy.address"
        static let token = "musicam.merajfy.token"
        static let format = "musicam.merajfy.format"
        static let share = "musicam.merajfy.share"
        static let lanToken = "musicam.merajfy.lanToken"
    }

    #if os(macOS)
    public init(defaults: UserDefaults = .standard, embedded: EmbeddedMerajfy = EmbeddedMerajfy()) {
        self.embedded = embedded
        self.defaults = defaults
        isEnabled = (defaults.object(forKey: Key.enabled) as? Bool) ?? true
        mode = Mode(rawValue: defaults.string(forKey: Key.mode) ?? "") ?? (embedded.isAvailable ? .builtIn : .external)
        address = defaults.string(forKey: Key.address) ?? Self.localAddress
        token = defaults.string(forKey: Key.token) ?? ""
        let saved = defaults.string(forKey: Key.format) ?? "mp3"
        format = Self.formats.contains(saved) ? saved : "mp3"
        shareWithIPhone = defaults.bool(forKey: Key.share)
        lanToken = defaults.string(forKey: Key.lanToken) ?? Self.makeToken()
        store = MerajfyConfigStore()
        finishInit()
    }
    #else
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = (defaults.object(forKey: Key.enabled) as? Bool) ?? true
        mode = Mode(rawValue: defaults.string(forKey: Key.mode) ?? "") ?? (OnDeviceEngine.current != nil ? .builtIn : .external)
        address = defaults.string(forKey: Key.address) ?? ""
        token = defaults.string(forKey: Key.token) ?? ""
        let saved = defaults.string(forKey: Key.format) ?? "mp3"
        format = Self.formats.contains(saved) ? saved : "mp3"
        shareWithIPhone = false
        lanToken = ""
        store = MerajfyConfigStore()
        finishInit()
    }
    #endif

    private func finishInit() {
        defaults.set(lanToken, forKey: Key.lanToken)
        store.set(config)
        onDevice.set(onDeviceWanted)
        // before each download, make sure the built-in helper is up
        store.setPrepare { [weak self] in await self?.prepareForDownload() }
        syncEmbedded()
    }

    private static func makeToken() -> String {
        String((0..<10).map { _ in "abcdefghjkmnpqrstuvwxyz23456789".randomElement()! })
    }

    private var onDeviceWanted: Bool {
        #if os(macOS)
        false
        #else
        isEnabled && mode == .builtIn && OnDeviceEngine.current != nil
        #endif
    }

    /// The settings as the provider needs them, or nil while the feature is off or unusable.
    public var config: MerajfyConfig? {
        guard isEnabled else { return nil }
        #if os(macOS)
        if mode == .builtIn {
            guard embedded.isAvailable else { return nil }
            return MerajfyConfig(baseURL: EmbeddedMerajfy.localURL(), token: shareWithIPhone ? lanToken : nil, format: format)
        }
        #endif
        #if os(iOS)
        if mode == .builtIn { return nil }          // the on-device provider handles it
        #endif
        guard let url = MerajfyConfig.parseAddress(address) else { return nil }
        return MerajfyConfig(baseURL: url, token: token, format: format)
    }

    /// What to type on the iPhone to reach this Mac's built-in helper.
    public var iPhoneAddress: String { "\(ProcessInfo.processInfo.hostName):\(Self.builtInPort)" }
    #if os(macOS)
    private static let builtInPort = Int(EmbeddedMerajfy.port)
    #else
    private static let builtInPort = 18787
    #endif

    private func changed() {
        defaults.set(isEnabled, forKey: Key.enabled)
        defaults.set(mode.rawValue, forKey: Key.mode)
        defaults.set(address, forKey: Key.address)
        defaults.set(token, forKey: Key.token)
        defaults.set(format, forKey: Key.format)
        defaults.set(shareWithIPhone, forKey: Key.share)
        store.set(config)
        onDevice.set(onDeviceWanted)
        status = .idle
        syncEmbedded()
    }

    /// Starts or stops the built-in helper so it matches the settings. Only restarts when something that matters changed.
    private func syncEmbedded() {
        #if os(macOS)
        let wanted = isEnabled && mode == .builtIn && embedded.isAvailable
        let key = wanted ? "on|\(shareWithIPhone)|\(lanToken)" : "off"
        guard key != embeddedKey else { return }
        embeddedKey = key
        if wanted {
            let share = shareWithIPhone, secret = lanToken
            Task { await embedded.start(allowLAN: share, token: secret) }
        } else {
            embedded.stop()
        }
        #endif
    }

    private func prepareForDownload() async {
        #if os(macOS)
        guard isEnabled, mode == .builtIn else { return }
        await embedded.ensureRunning(allowLAN: shareWithIPhone, token: lanToken)
        store.set(config)
        #endif
    }

    /// Asks Merajfy whether it is there and has what it needs. Works even while the feature is switched off.
    public func testConnection(session: URLSession = .shared) async {
        status = .testing
        var target: MerajfyConfig?
        #if os(macOS)
        if mode == .builtIn {
            guard embedded.isAvailable else {
                status = .failed(String(localized: "This build of Musicam has no built-in downloader."))
                return
            }
            await embedded.ensureRunning(allowLAN: shareWithIPhone, token: lanToken)
            if case .failed(let reason) = embedded.state { status = .failed(reason); return }
            target = MerajfyConfig(baseURL: EmbeddedMerajfy.localURL(), token: shareWithIPhone ? lanToken : nil, format: format)
        }
        #endif
        #if os(iOS)
        if mode == .builtIn {
            guard let engine = OnDeviceEngine.current else {
                status = .failed(String(localized: "This build of Musicam has no built-in downloader."))
                return
            }
            do {
                let hits = try await engine.search("ytsearch1:Me at the zoo")
                status = hits.isEmpty ? .failed(String(localized: "The downloader started but found nothing. Check the connection."))
                                      : .ok(String(localized: "Merajfy is ready on this iPhone."))
            } catch { status = .failed(error.localizedDescription) }
            return
        }
        #endif
        if target == nil {
            guard let url = MerajfyConfig.parseAddress(address) else {
                status = .failed(String(localized: "Type the address of the Mac, for example 192.168.1.20:8787."))
                return
            }
            target = MerajfyConfig(baseURL: url, token: token, format: format)
        }
        let client = MerajfyClient(config: target!, session: session)
        do {
            let health = try await client.health()
            status = health.toolsReady
                ? .ok(String(localized: "Merajfy is ready."))
                : .failed(String(localized: "Merajfy is running but yt-dlp or ffmpeg is missing on the Mac."))
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}
