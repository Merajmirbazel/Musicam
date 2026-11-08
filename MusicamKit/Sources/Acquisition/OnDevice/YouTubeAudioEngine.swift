import Foundation
import Synchronization
import MerajCore

/// What the iPhone app provides so Musicam can fetch audio without a Mac: a search and an audio download that run inside
/// the app itself. The app target implements it (it embeds Python and yt-dlp); this package only knows the shape, so
/// Musicam's own modules stay free of Python.
public protocol YouTubeAudioEngine: Sendable {
    /// A yt-dlp search such as "ytsearch5:song artist audio" -> flat results (id, title, duration).
    func search(_ query: String) async throws -> [YTCandidate]
    /// Downloads the AAC (m4a) audio of one video into `directory` and returns the file. `progress` runs 0...1.
    /// Stops promptly, and removes its partial file, when the calling task is cancelled.
    func downloadAudio(videoID: String, into directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}

/// The engine the app installed at start-up, if this build has one.
public enum OnDeviceEngine {
    private static let box = Mutex<(any YouTubeAudioEngine)?>(nil)
    public static func install(_ engine: any YouTubeAudioEngine) { box.withLock { $0 = engine } }
    public static var current: (any YouTubeAudioEngine)? { box.withLock { $0 } }
}

/// Whether the person turned on-device downloads on. The settings screen writes it; the provider reads it per request.
public final class OnDeviceSwitch: Sendable {
    private let value = Mutex(false)
    public init(_ on: Bool = false) { value.withLock { $0 = on } }
    public var isOn: Bool { value.withLock { $0 } }
    public func set(_ on: Bool) { value.withLock { $0 = on } }
}
