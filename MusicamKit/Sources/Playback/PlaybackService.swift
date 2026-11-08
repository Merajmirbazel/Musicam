import Foundation
import Observation
import Domain

/// Owns what is playing and what comes next. UI reads its state; it never talks to the engine directly.
@MainActor
@Observable
public final class PlaybackService {
    public private(set) var current: Track?
    public private(set) var isPlaying = false
    public private(set) var elapsed: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var upcoming: [Track] = []
    public private(set) var isShuffled = false
    public private(set) var repeatMode: RepeatMode = .off
    /// A short, user-readable message when a file could not be played (for example, an unplugged drive).
    public private(set) var notice: String?
    /// True while the file is being opened, which can include downloading it from another device.
    public private(set) var isLoading = false
    public var volume: Float = 0.8 {
        didSet { engine.volume = volume }
    }

    @ObservationIgnored private var queue = PlayQueue()
    @ObservationIgnored private var catalog: [TrackID: Track] = [:]
    @ObservationIgnored private let engine: any PlaybackEngine
    @ObservationIgnored private let files: any FileAccessing
    @ObservationIgnored private let nowPlaying: (any NowPlayingPublishing)?
    @ObservationIgnored private let artwork: @Sendable (String) -> Data?
    @ObservationIgnored private var generation = 0
    /// Only the newest "prepare the next song" request may reach the engine; older ones finish later and must be dropped.
    @ObservationIgnored private var nextRefreshTicket = 0
    @ObservationIgnored private var listener: Task<Void, Never>?
    /// Called once per play, after the song has played for 5 seconds (or reached its end if it is shorter).
    @ObservationIgnored public var onPlayed: (@MainActor (Track) -> Void)?
    @ObservationIgnored private var playCounted = false
    static let secondsBeforeCounting: TimeInterval = 5

    public init(engine: any PlaybackEngine, files: any FileAccessing,
                nowPlaying: (any NowPlayingPublishing)? = nil,
                artwork: @escaping @Sendable (String) -> Data? = { _ in nil }) {
        self.engine = engine
        self.files = files
        self.nowPlaying = nowPlaying
        self.artwork = artwork
        engine.volume = volume

        nowPlaying?.connect(NowPlayingCommands(
            play: { [weak self] in self?.resume() },
            pause: { [weak self] in self?.pause() },
            toggle: { [weak self] in self?.togglePlay() },
            next: { [weak self] in self?.next() },
            previous: { [weak self] in self?.previous() },
            seek: { [weak self] in self?.seek(to: $0) }))

        let events = engine.events
        listener = Task { [weak self] in
            for await event in events { self?.handle(event) }
        }
    }

    // MARK: Commands

    /// Plays `tracks` as the queue, starting at `index`.
    public func play(_ tracks: [Track], startAt index: Int = 0) {
        guard tracks.indices.contains(index) else { return }
        catalog = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var newQueue = PlayQueue(items: tracks.map(\.id), startAt: index)
        newQueue.repeatMode = repeatMode
        if isShuffled {
            var rng = SystemRandomNumberGenerator()
            newQueue.setShuffle(true, using: &rng)
        }
        queue = newQueue
        startCurrent(autoplay: true)
    }

    public func togglePlay() { isPlaying ? pause() : resume() }

    public func resume() {
        guard current != nil else { return }
        engine.play()
        isPlaying = true
        publishNowPlaying()
    }

    public func pause() {
        engine.pause()
        isPlaying = false
        publishNowPlaying()
    }

    public func next() {
        guard queue.current != nil else { return }
        queue.advance(fromTrackEnd: false)
        startCurrent(autoplay: true)
    }

    public func previous() {
        guard queue.current != nil else { return }
        if elapsed > 3 { seek(to: 0); return }
        queue.previous()
        startCurrent(autoplay: true)
    }

    public func seek(to seconds: TimeInterval) {
        let clamped = min(max(0, seconds), duration > 0 ? duration : seconds)
        engine.seek(to: clamped)
        elapsed = clamped
        publishNowPlaying()
    }

    public func setShuffle(_ on: Bool) {
        var rng = SystemRandomNumberGenerator()
        queue.setShuffle(on, using: &rng)
        isShuffled = on
        queueDidChange()
    }

    public func cycleRepeat() {
        repeatMode = repeatMode.next
        queue.repeatMode = repeatMode
        queueDidChange()
    }

    public func playNext(_ track: Track) {
        catalog[track.id] = track
        queue.playNext(track.id)
        queueDidChange()
    }

    public func addToQueue(_ track: Track) {
        catalog[track.id] = track
        queue.append(track.id)
        queueDidChange()
    }

    public func stop() {
        generation += 1
        engine.stop()
        queue = PlayQueue()
        current = nil
        isPlaying = false
        elapsed = 0
        duration = 0
        upcoming = []
        nowPlaying?.publish(nil)
    }

    // MARK: Internals

    private func startCurrent(autoplay: Bool) {
        generation += 1
        let myGeneration = generation
        guard let id = queue.current, let track = catalog[id] else { return }
        playCounted = false
        current = track
        elapsed = 0
        duration = track.duration
        notice = nil
        refreshUpcoming()
        let nextTrack = peekNext()
        isLoading = true

        Task { [weak self] in
            guard let self else { return }
            guard let fileID = track.file?.id else { skipUnplayable(track, generation: myGeneration); return }
            let access: AccessedFile
            do { access = try await files.open(fileID) } catch {
                skipUnplayable(track, generation: myGeneration)
                return
            }
            guard myGeneration == generation else { access.release(); return }
            engine.load(current: access, next: nil, autoplay: autoplay)       // start playing as soon as this file is ready
            isLoading = false
            isPlaying = autoplay
            let nextAccess = await openFile(of: nextTrack)                     // then prepare the next one (may download)
            guard myGeneration == generation else { nextAccess?.release(); return }
            engine.setNext(nextAccess)
            publishNowPlaying()
        }
    }

    /// A file that cannot be opened is skipped with a visible message, never a silent jump.
    private func skipUnplayable(_ track: Track, generation g: Int) {
        guard g == generation else { return }
        isLoading = false
        notice = "“\(track.title)” could not be played. Its file may be on a drive that is not connected."
        guard queue.current == track.id else { return }
        let before = queue.current
        guard let moved = queue.advance(fromTrackEnd: true), moved != before else {
            isPlaying = false
            return
        }
        let message = notice
        startCurrent(autoplay: true)
        notice = message
    }

    private func handle(_ event: EngineEvent) {
        switch event {
        case .time(let t):
            elapsed = t
            if !playCounted, t >= Self.secondsBeforeCounting, let track = current { playCounted = true; onPlayed?(track) }
        case .duration(let d):
            duration = d
        case .failed(let message):
            notice = message
        case .itemEnded(let advancedToNext):
            if !playCounted, let finished = current { onPlayed?(finished) }      // a short song still counts when it ends
            playCounted = false
            guard let id = queue.advance(fromTrackEnd: true), let track = catalog[id] else {
                isPlaying = false
                elapsed = 0
                publishNowPlaying()
                return
            }
            if advancedToNext {
                current = track
                elapsed = 0
                duration = track.duration
                refreshUpcoming()
                publishNowPlaying()
                refreshNext()
            } else {
                startCurrent(autoplay: true)
            }
        }
    }

    private func queueDidChange() {
        refreshUpcoming()
        refreshNext()
    }

    /// Re-aims the preloaded item after the queue changed (shuffle, repeat, play next ...).
    private func refreshNext() {
        let myGeneration = generation
        nextRefreshTicket += 1
        let ticket = nextRefreshTicket
        let nextTrack = peekNext()
        Task { [weak self] in
            guard let self else { return }
            let access = await openFile(of: nextTrack)
            guard myGeneration == generation, ticket == nextRefreshTicket else { access?.release(); return }
            engine.setNext(access)
        }
    }

    private func peekNext() -> Track? {
        var probe = queue
        guard let id = probe.advance(fromTrackEnd: true) else { return nil }
        return catalog[id]
    }

    private func openFile(of track: Track?) async -> AccessedFile? {
        guard let id = track?.file?.id else { return nil }
        return try? await files.open(id)
    }

    private func refreshUpcoming() {
        upcoming = queue.upcoming.compactMap { catalog[$0] }
    }

    private func publishNowPlaying() {
        guard let nowPlaying else { return }
        guard let track = current else { nowPlaying.publish(nil); return }
        nowPlaying.publish(NowPlayingInfo(title: track.title, artist: track.artist, album: track.album, duration: duration,
                                          elapsed: elapsed, isPlaying: isPlaying,
                                          artworkData: track.artworkKey.flatMap(artwork)))
    }
}
