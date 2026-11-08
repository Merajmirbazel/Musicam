import Foundation
import AVFoundation
import Domain

/// Engine v1: AVQueuePlayer with the next item preloaded. Whether the gap between songs is truly
/// inaudible is measured separately; this class makes no such promise.
@MainActor
public final class AVQueuePlayerEngine: PlaybackEngine {
    public let events: AsyncStream<EngineEvent>
    private let continuation: AsyncStream<EngineEvent>.Continuation
    private let player = AVQueuePlayer()

    private var currentItem: AVPlayerItem?
    private var currentFile: AccessedFile?
    private var nextItem: AVPlayerItem?
    private var nextFile: AccessedFile?
    private var timeToken: Any?
    private var observers: [NSObjectProtocol] = []

    public init() {
        let (stream, continuation) = AsyncStream<EngineEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        self.events = stream
        self.continuation = continuation
        player.actionAtItemEnd = .advance

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif

        timeToken = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            let seconds = time.seconds
            MainActor.assumeIsolated {
                if seconds.isFinite, let self { self.continuation.yield(.time(max(0, seconds))) }
            }
        }
        observers.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated { if let self { self.itemEnded(item) } }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError)?.localizedDescription ?? "Playback failed"
            MainActor.assumeIsolated { if let self { self.continuation.yield(.failed(message)) } }
        })
    }

    public var isPlaying: Bool { player.timeControlStatus != .paused }

    public var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    public func load(current: AccessedFile, next: AccessedFile?, autoplay: Bool) {
        player.removeAllItems()
        currentFile?.release()
        nextFile?.release()
        nextItem = nil
        nextFile = nil

        let item = AVPlayerItem(url: current.url)
        currentItem = item
        currentFile = current
        player.insert(item, after: nil)
        reportDuration(of: item)
        setNext(next)
        if autoplay { player.play() }
    }

    public func setNext(_ file: AccessedFile?) {
        if let old = nextItem { player.remove(old) }
        nextFile?.release()
        nextItem = nil
        nextFile = nil
        guard let file, let current = currentItem else { return }
        let item = AVPlayerItem(url: file.url)
        nextItem = item
        nextFile = file
        player.insert(item, after: current)
    }

    public func play() { player.play() }
    public func pause() { player.pause() }

    public func seek(to seconds: TimeInterval) {
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    public func stop() {
        player.pause()
        player.removeAllItems()
        currentFile?.release()
        nextFile?.release()
        currentItem = nil; currentFile = nil; nextItem = nil; nextFile = nil
    }

    private func itemEnded(_ item: AVPlayerItem?) {
        guard let item, item === currentItem else { return }
        let hadNext = nextItem != nil
        if hadNext {
            currentFile?.release()
            currentItem = nextItem
            currentFile = nextFile
            nextItem = nil
            nextFile = nil
            if let started = currentItem { reportDuration(of: started) }
        }
        continuation.yield(.itemEnded(advancedToNext: hadNext))
    }

    private func reportDuration(of item: AVPlayerItem) {
        Task { @MainActor in
            guard let duration = try? await item.asset.load(.duration), duration.seconds.isFinite, item === currentItem else { return }
            continuation.yield(.duration(duration.seconds))
        }
    }
}
