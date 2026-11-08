import Testing
import Foundation
import Domain
@testable import Playback

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

private func ids(_ n: Int) -> [TrackID] { (0..<n).map { _ in UUID() } }

@Suite struct PlayQueueTests {
    @Test func advanceWalksQueueAndStopsAtEndWhenRepeatOff() {
        let t = ids(3)
        var q = PlayQueue(items: t, startAt: 0)
        #expect(q.current == t[0])
        #expect(q.advance(fromTrackEnd: true) == t[1])
        #expect(q.advance(fromTrackEnd: true) == t[2])
        #expect(q.advance(fromTrackEnd: true) == nil)
        #expect(q.current == t[2])   // position is kept so the UI can show the last track
    }

    @Test func repeatAllWraps() {
        let t = ids(2)
        var q = PlayQueue(items: t, startAt: 1)
        q.repeatMode = .all
        #expect(q.advance(fromTrackEnd: true) == t[0])
    }

    @Test func repeatOneRepeatsAtTrackEndButManualNextMovesOn() {
        let t = ids(3)
        var q = PlayQueue(items: t, startAt: 0)
        q.repeatMode = .one
        #expect(q.advance(fromTrackEnd: true) == t[0])
        #expect(q.advance() == t[1])
    }

    @Test func previousWrapsOnlyWithRepeatAll() {
        let t = ids(3)
        var q = PlayQueue(items: t, startAt: 0)
        #expect(q.previous() == t[0])
        q.repeatMode = .all
        #expect(q.previous() == t[2])
    }

    @Test func shuffleKeepsCurrentFirstAndVisitsEveryTrackOnce() {
        let t = ids(10)
        var q = PlayQueue(items: t, startAt: 3)
        var rng = SplitMix64(state: 42)
        q.setShuffle(true, using: &rng)
        #expect(q.current == t[3])
        var seen = [q.current!]
        while let next = q.advance(fromTrackEnd: true) { seen.append(next) }
        #expect(seen.count == 10)
        #expect(Set(seen) == Set(t))
    }

    @Test func turningShuffleOffRestoresOriginalOrderAroundCurrent() {
        let t = ids(6)
        var q = PlayQueue(items: t, startAt: 1)
        var rng = SplitMix64(state: 7)
        q.setShuffle(true, using: &rng)
        q.advance()
        let playing = q.current!
        q.setShuffle(false, using: &rng)
        #expect(q.current == playing)
        let idx = t.firstIndex(of: playing)!
        #expect(q.upcoming == Array(t[(idx + 1)...]))
    }

    @Test func playNextInsertsAfterCurrentInBothModes() {
        let t = ids(4)
        let extra = UUID()
        var q = PlayQueue(items: t, startAt: 1)
        q.playNext(extra)
        #expect(q.upcoming.first == extra)
        #expect(q.items.count == 5)

        var s = PlayQueue(items: t, startAt: 1)
        var rng = SplitMix64(state: 1)
        s.setShuffle(true, using: &rng)
        s.playNext(extra)
        #expect(s.upcoming.first == extra)
    }

    @Test func removingCurrentMovesToNextAndRemovingEarlierKeepsCurrent() {
        let t = ids(4)
        var q = PlayQueue(items: t, startAt: 2)
        #expect(q.remove(itemAt: 0) == false)
        #expect(q.current == t[2])
        #expect(q.remove(itemAt: q.currentItemIndex!) == true)
        #expect(q.current == t[3])
    }

    @Test func removingLastRemainingItemEmptiesQueue() {
        let t = ids(1)
        var q = PlayQueue(items: t, startAt: 0)
        #expect(q.remove(itemAt: 0) == true)
        #expect(q.current == nil)
        #expect(q.advance() == nil)
    }
}
