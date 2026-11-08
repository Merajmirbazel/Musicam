import Foundation
import Domain

public enum EngineEvent: Sendable, Equatable {
    case time(TimeInterval)
    case duration(TimeInterval)
    /// The current item finished. `advancedToNext` is true when a preloaded next item is already playing.
    case itemEnded(advancedToNext: Bool)
    case failed(String)
}

/// The seam between queue logic and audio. v1 is AVQueuePlayer; an AVAudioEngine version can replace it later.
@MainActor
public protocol PlaybackEngine: AnyObject {
    var events: AsyncStream<EngineEvent> { get }
    var isPlaying: Bool { get }
    var volume: Float { get set }

    /// Replaces whatever is playing. `next`, when given, is preloaded for a seamless transition.
    func load(current: AccessedFile, next: AccessedFile?, autoplay: Bool)
    /// Replaces (or clears) the preloaded next item.
    func setNext(_ file: AccessedFile?)
    func play()
    func pause()
    func seek(to seconds: TimeInterval)
    func stop()
}
