import Testing
import Foundation
import AVFoundation
import Domain
@testable import Playback

// MARK: Test doubles

@MainActor
final class MockEngine: PlaybackEngine {
    let events: AsyncStream<EngineEvent>
    private let continuation: AsyncStream<EngineEvent>.Continuation
    var isPlaying = false
    var volume: Float = 1
    struct Load: Equatable { var current: String; var next: String?; var autoplay: Bool }
    var loads: [Load] = []
    var nextCalls: [String?] = []
    var seeks: [TimeInterval] = []
    var stopped = false

    init() {
        (events, continuation) = AsyncStream<EngineEvent>.makeStream()
    }

    func emit(_ event: EngineEvent) { continuation.yield(event) }

    func load(current: AccessedFile, next: AccessedFile?, autoplay: Bool) {
        loads.append(Load(current: current.url.lastPathComponent, next: next?.url.lastPathComponent, autoplay: autoplay))
        isPlaying = autoplay
    }
    func setNext(_ file: AccessedFile?) { nextCalls.append(file?.url.lastPathComponent) }
    func play() { isPlaying = true }
    func pause() { isPlaying = false }
    func seek(to seconds: TimeInterval) { seeks.append(seconds) }
    func stop() { stopped = true; isPlaying = false }
}

struct MockFiles: FileAccessing {
    var missing: Set<LibraryFileID> = []
    func open(_ fileID: LibraryFileID) async throws -> AccessedFile {
        if missing.contains(fileID) { throw FileAccessError.missing(fileID) }
        return AccessedFile(url: URL(fileURLWithPath: "/fake/\(fileID.uuidString)"))
    }
}

@MainActor
func waitUntil(_ timeout: Double = 2, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

func makeTracks(_ n: Int) -> [Track] {
    (0..<n).map { i in
        let fileID = UUID()
        return Track(title: "Song \(i)", artist: "Artist", duration: 180,
                     file: AudioFileInfo(id: fileID, contentHash: "h\(i)", byteSize: 1, originalFilename: "f\(i)",
                                         format: AudioFormat(codec: "WAV"), duration: 180))
    }
}

func name(_ track: Track) -> String { track.file!.id.uuidString }

// MARK: Service logic

@MainActor
@Suite struct PlaybackServiceTests {
    private func make(_ n: Int = 4, files: MockFiles = MockFiles()) -> (PlaybackService, MockEngine, [Track]) {
        let engine = MockEngine()
        return (PlaybackService(engine: engine, files: files), engine, makeTracks(n))
    }

    @Test func playLoadsTheTrackAndPreloadsTheNextOne() async {
        let (service, engine, tracks) = make()
        service.play(tracks, startAt: 1)
        #expect(await waitUntil { !engine.loads.isEmpty })
        // the current song starts as soon as it is ready; the next one is prepared right after (it may need a download)
        #expect(engine.loads == [.init(current: name(tracks[1]), next: nil, autoplay: true)])
        #expect(await waitUntil { engine.nextCalls.last == name(tracks[2]) })
        #expect(!service.isLoading)
        #expect(service.current?.id == tracks[1].id)
        #expect(service.isPlaying)
        #expect(service.upcoming.map(\.id) == [tracks[2].id, tracks[3].id])
    }

    @Test func whenASongEndsAndTheNextIsAlreadyPlayingTheServiceCatchesUpAndPreloadsAgain() async {
        let (service, engine, tracks) = make()
        service.play(tracks, startAt: 0)
        #expect(await waitUntil { !engine.loads.isEmpty })

        engine.emit(.itemEnded(advancedToNext: true))
        #expect(await waitUntil { service.current?.id == tracks[1].id })
        #expect(await waitUntil { engine.nextCalls.last == name(tracks[2]) })
        #expect(engine.loads.count == 1)   // no reload: the engine had already moved on by itself
    }

    @Test func aPlayIsCountedOnceAfterFiveSecondsAndShortSongsCountAtTheEnd() async {
        let (service, engine, tracks) = make(3)
        var counted: [String] = []
        service.onPlayed = { counted.append($0.title) }
        service.play(tracks, startAt: 0)
        #expect(await waitUntil { !engine.loads.isEmpty })

        engine.emit(.time(2))
        engine.emit(.time(4.9))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(counted.isEmpty)                                    // skipped early: not a play
        engine.emit(.time(5))
        engine.emit(.time(6))
        engine.emit(.time(7))
        #expect(await waitUntil { counted == ["Song 0"] })          // exactly once

        engine.emit(.itemEnded(advancedToNext: true))               // the next song starts, and ends before 5 seconds
        #expect(await waitUntil { service.current?.id == tracks[1].id })
        engine.emit(.time(1))
        engine.emit(.itemEnded(advancedToNext: true))
        #expect(await waitUntil { counted == ["Song 0", "Song 1"] })
    }

    @Test func reachingTheEndOfTheQueueStops() async {
        let (service, engine, tracks) = make(2)
        service.play(tracks, startAt: 1)
        #expect(await waitUntil { !engine.loads.isEmpty })
        engine.emit(.itemEnded(advancedToNext: false))
        #expect(await waitUntil { !service.isPlaying })
        #expect(service.current?.id == tracks[1].id)
    }

    @Test func ifPreloadingFailedTheServiceLoadsTheNextSongItself() async {
        let (service, engine, tracks) = make(3)
        service.play(tracks, startAt: 0)
        #expect(await waitUntil { engine.loads.count == 1 })
        engine.emit(.itemEnded(advancedToNext: false))
        #expect(await waitUntil { engine.loads.count == 2 })
        #expect(engine.loads[1].current == name(tracks[1]))
    }

    @Test func previousRestartsAfterThreeSecondsOtherwiseGoesBack() async {
        let (service, engine, tracks) = make()
        service.play(tracks, startAt: 2)
        #expect(await waitUntil { engine.loads.count == 1 })
        engine.emit(.time(10))
        #expect(await waitUntil { service.elapsed == 10 })
        service.previous()
        #expect(engine.seeks == [0])
        #expect(service.current?.id == tracks[2].id)

        engine.emit(.time(1))
        #expect(await waitUntil { service.elapsed == 1 })
        service.previous()
        #expect(await waitUntil { service.current?.id == tracks[1].id })
    }

    @Test func repeatOnePreloadsTheSameSongAndKeepsIt() async {
        let (service, engine, tracks) = make(3)
        service.play(tracks, startAt: 0)
        #expect(await waitUntil { engine.loads.count == 1 })
        service.cycleRepeat()   // all
        service.cycleRepeat()   // one
        #expect(service.repeatMode == .one)
        #expect(await waitUntil { engine.nextCalls.last == name(tracks[0]) })
        engine.emit(.itemEnded(advancedToNext: true))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(service.current?.id == tracks[0].id)
    }

    @Test func togglingShuffleKeepsTheCurrentSongAndRepointsTheNextOne() async {
        let (service, engine, tracks) = make(8)
        service.play(tracks, startAt: 3)
        #expect(await waitUntil { engine.loads.count == 1 })
        service.setShuffle(true)
        #expect(service.isShuffled)
        #expect(service.current?.id == tracks[3].id)
        #expect(await waitUntil { !engine.nextCalls.isEmpty })
        #expect(Set(service.upcoming.map(\.id)) == Set(tracks.map(\.id)).subtracting([tracks[3].id]))
    }

    @Test func aMissingFileIsSkippedWithAVisibleMessage() async {
        var files = MockFiles()
        let tracks = makeTracks(3)
        files.missing = [tracks[0].file!.id]
        let engine = MockEngine()
        let service = PlaybackService(engine: engine, files: files)
        service.play(tracks, startAt: 0)
        #expect(await waitUntil { !engine.loads.isEmpty })
        #expect(engine.loads[0].current == name(tracks[1]))
        #expect(service.current?.id == tracks[1].id)
        #expect(service.notice?.contains("Song 0") == true)
    }

    @Test func rapidNextPressesEndOnTheRightSongWithoutLoadingStaleOnes() async {
        let (service, engine, tracks) = make(6)
        service.play(tracks, startAt: 0)
        #expect(await waitUntil { engine.loads.count >= 1 })
        service.next(); service.next(); service.next()
        #expect(await waitUntil { service.current?.id == tracks[3].id })
        try? await Task.sleep(for: .milliseconds(80))
        #expect(engine.loads.last?.current == name(tracks[3]))
        #expect(engine.isPlaying)
    }

    @Test func playPauseVolumeAndSeekReachTheEngine() async {
        let (service, engine, tracks) = make()
        service.play(tracks)
        #expect(await waitUntil { engine.loads.count == 1 })
        service.pause()
        #expect(!engine.isPlaying)
        service.togglePlay()
        #expect(engine.isPlaying)
        service.volume = 0.25
        #expect(engine.volume == 0.25)
        service.seek(to: 9_999)           // clamped to the song's length
        #expect(engine.seeks.last == 180)
    }

    @Test func stopClearsEverything() async {
        let (service, engine, tracks) = make()
        service.play(tracks)
        #expect(await waitUntil { engine.loads.count == 1 })
        service.stop()
        #expect(service.current == nil)
        #expect(service.upcoming.isEmpty)
        #expect(engine.stopped)
    }
}

// MARK: Real audio engine (silent files, so nothing is audible)

private func writeSilentWAV(_ url: URL, seconds: Double) throws {
    let rate = 8000
    let frames = Int(Double(rate) * seconds)
    func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    let pcm = Data(count: frames * 2)
    var wav = Data("RIFF".utf8)
    wav += le32(UInt32(36 + pcm.count)) + Data("WAVEfmt ".utf8) + le32(16) + le16(1) + le16(1)
    wav += le32(UInt32(rate)) + le32(UInt32(rate * 2)) + le16(2) + le16(16)
    wav += Data("data".utf8) + le32(UInt32(pcm.count)) + pcm
    try wav.write(to: url)
}

@MainActor
@Suite struct RealEngineTests {
    @Test func playsOneFileIntoThePreloadedNextAndThenEnds() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("musicam-engine-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.wav"), b = dir.appendingPathComponent("b.wav")
        try writeSilentWAV(a, seconds: 0.4)
        try writeSilentWAV(b, seconds: 0.4)

        let engine = AVQueuePlayerEngine()
        engine.load(current: AccessedFile(url: a), next: AccessedFile(url: b), autoplay: true)

        var durations: [TimeInterval] = []
        var ended: [Bool] = []
        let collector = Task { @MainActor in
            for await event in engine.events {
                switch event {
                case .duration(let d): durations.append(d)
                case .itemEnded(let advanced): ended.append(advanced)
                default: break
                }
                if ended.count == 2 { break }
            }
        }
        let finished = await waitUntil(6) { ended.count == 2 }
        collector.cancel()
        #expect(finished)
        #expect(ended == [true, false])           // A flowed into the preloaded B, then B ended with nothing after it
        #expect(durations.count >= 2)
        #expect(durations.allSatisfy { abs($0 - 0.4) < 0.05 })
    }
}
