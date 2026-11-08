import Foundation
import MediaPlayer
import Domain
#if os(macOS)
import AppKit
#else
import UIKit
#endif

public struct NowPlayingInfo: Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var duration: TimeInterval
    public var elapsed: TimeInterval
    public var isPlaying: Bool
    public var artworkData: Data?

    public init(title: String, artist: String, album: String, duration: TimeInterval, elapsed: TimeInterval, isPlaying: Bool, artworkData: Data?) {
        self.title = title; self.artist = artist; self.album = album
        self.duration = duration; self.elapsed = elapsed; self.isPlaying = isPlaying; self.artworkData = artworkData
    }
}

/// What the system's media controls (lock screen, Control Center, keyboard media keys) can ask for.
public struct NowPlayingCommands {
    public var play: @MainActor () -> Void
    public var pause: @MainActor () -> Void
    public var toggle: @MainActor () -> Void
    public var next: @MainActor () -> Void
    public var previous: @MainActor () -> Void
    public var seek: @MainActor (TimeInterval) -> Void
}

@MainActor
public protocol NowPlayingPublishing: AnyObject {
    func connect(_ commands: NowPlayingCommands)
    func publish(_ info: NowPlayingInfo?)
}

/// Bridges to MPNowPlayingInfoCenter and MPRemoteCommandCenter (same API on macOS and iOS).
@MainActor
public final class SystemNowPlaying: NowPlayingPublishing {
    public init() {}

    public func connect(_ commands: NowPlayingCommands) {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { _ in Task { @MainActor in commands.play() }; return .success }
        center.pauseCommand.addTarget { _ in Task { @MainActor in commands.pause() }; return .success }
        center.togglePlayPauseCommand.addTarget { _ in Task { @MainActor in commands.toggle() }; return .success }
        center.nextTrackCommand.addTarget { _ in Task { @MainActor in commands.next() }; return .success }
        center.previousTrackCommand.addTarget { _ in Task { @MainActor in commands.previous() }; return .success }
        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in commands.seek(position) }
            return .success
        }
    }

    public func publish(_ info: NowPlayingInfo?) {
        let center = MPNowPlayingInfoCenter.default()
        guard let info else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var dict: [String: Any] = [
            MPMediaItemPropertyTitle: info.title,
            MPMediaItemPropertyArtist: info.artist,
            MPMediaItemPropertyAlbumTitle: info.album,
            MPMediaItemPropertyPlaybackDuration: info.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: info.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: info.isPlaying ? 1.0 : 0.0,
        ]
        if let data = info.artworkData, let artwork = Self.makeArtwork(from: data) {
            dict[MPMediaItemPropertyArtwork] = artwork
        }
        center.nowPlayingInfo = dict
        center.playbackState = info.isPlaying ? .playing : .paused
    }

    /// MediaPlayer calls the artwork closure on its own background queue, so it must not be MainActor-isolated
    /// (a closure built inside this class would be, and the runtime stops the app). It captures only `Data`.
    private nonisolated static func makeArtwork(from data: Data) -> MPMediaItemArtwork? {
        guard let probe = image(from: data) else { return nil }
        return MPMediaItemArtwork(boundsSize: probe.size) { _ in image(from: data) ?? probe }
    }

    #if os(macOS)
    private nonisolated static func image(from data: Data) -> NSImage? { NSImage(data: data) }
    #else
    private nonisolated static func image(from data: Data) -> UIImage? { UIImage(data: data) }
    #endif
}
