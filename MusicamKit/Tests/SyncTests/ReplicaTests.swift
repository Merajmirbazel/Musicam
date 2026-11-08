import Testing
import Foundation
import Domain
@testable import Sync

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

private let devA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
private let devB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
private let devC = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!

/// One round of two-way sync, the same exchange the real protocol performs.
private func sync(_ a: inout Replica, _ b: inout Replica, now: UInt64 = 0) {
    let toB = a.entries(missingFrom: b.vector)
    let toA = b.entries(missingFrom: a.vector)
    b.ingest(toB, now: now)
    a.ingest(toA, now: now)
}

@Suite struct HybridLogicalClockTests {
    @Test func neverGoesBackwardsWhenWallClockDoes() {
        var c = HybridLogicalClock(device: devA, now: 1000)
        let s1 = c.tick(now: 1000)
        let s2 = c.tick(now: 500)      // clock jumped back
        let s3 = c.tick(now: 500)
        #expect(s1 < s2)
        #expect(s2 < s3)
    }

    @Test func receivingAFutureStampOrdersLaterLocalChangesAfterIt() {
        var c = HybridLogicalClock(device: devA, now: 100)
        let remote = HLCTimestamp(wallMillis: 9_000, counter: 5, device: devB)
        c.receive(remote, now: 100)
        #expect(c.tick(now: 100) > remote)
    }

    @Test func tiesAreBrokenByDeviceIDDeterministically() {
        let x = HLCTimestamp(wallMillis: 5, counter: 1, device: devA)
        let y = HLCTimestamp(wallMillis: 5, counter: 1, device: devB)
        #expect(x < y)
        #expect(!(y < x))
    }
}

@Suite struct ReplicaTests {
    private let track = EntityKey(entity: "Track", id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)

    @Test func latestStampWinsPerField() {
        var a = Replica(device: devA)
        a.set(track, "title", .string("Old"), now: 10)
        a.set(track, "title", .string("New"), now: 20)
        a.set(track, "rating", .int(4), now: 5)
        #expect(a.value(of: track, field: "title") == .string("New"))
        #expect(a.value(of: track, field: "rating") == .int(4))
    }

    @Test func aLaterEditOnADeviceWithASlowClockStillWinsAfterSeeingTheOtherEdit() {
        var a = Replica(device: devA, now: 1_000)
        var b = Replica(device: devB, now: 10)        // slow clock
        a.set(track, "title", .string("From A"), now: 1_000)
        sync(&a, &b, now: 10)
        b.set(track, "title", .string("From B, made later"), now: 10)
        sync(&a, &b, now: 1_000)
        #expect(a.value(of: track, field: "title") == .string("From B, made later"))
        #expect(a.snapshot == b.snapshot)
    }

    @Test func redeliveryAndReorderingChangeNothing() {
        var a = Replica(device: devA)
        let entries = (0..<20).map { i in
            a.set(track, "f\(i % 4)", .int(Int64(i)), now: UInt64(i))
        }
        var ordered = Replica(device: devB)
        ordered.ingest(entries, now: 0)

        var rng = SplitMix64(state: 99)
        var messy = Replica(device: devC)
        messy.ingest(entries.shuffled(using: &rng), now: 0)
        messy.ingest(entries, now: 0)                 // duplicates
        messy.ingest(entries.shuffled(using: &rng), now: 0)

        #expect(ordered.snapshot == messy.snapshot)
        #expect(ordered.entryCount == 20)
        #expect(messy.entryCount == 20)
    }

    @Test func threeDevicesWithRandomEditsAndSkewedClocksConverge() {
        for seed in 1...25 {
            var rng = SplitMix64(state: UInt64(seed))
            var replicas = [Replica(device: devA, now: 0), Replica(device: devB, now: 0), Replica(device: devC, now: 0)]
            let keys = (0..<4).map { EntityKey(entity: "Track", id: UUID(uuid: (UInt8($0), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))) }
            let fields = ["title", "artist", "rating", "favorite"]

            for step in 0..<120 {
                let r = Int.random(in: 0..<3, using: &rng)
                if Int.random(in: 0..<4, using: &rng) == 0 {
                    // two devices meet, possibly only a partial transfer (connection dropped)
                    let o = (r + 1 + Int.random(in: 0..<2, using: &rng)) % 3
                    var x = replicas[r], y = replicas[o]
                    let toY = x.entries(missingFrom: y.vector)
                    y.ingest(Array(toY.prefix(Int.random(in: 0...toY.count, using: &rng))), now: UInt64(step))
                    let toX = y.entries(missingFrom: x.vector)
                    x.ingest(toX, now: UInt64(step))
                    replicas[r] = x; replicas[o] = y
                } else {
                    let skew = UInt64(Int.random(in: 0..<500, using: &rng))   // each device's clock is wrong by a different amount
                    replicas[r].set(keys.randomElement(using: &rng)!, fields.randomElement(using: &rng)!,
                                    .int(Int64.random(in: 0..<1000, using: &rng)), now: UInt64(step) + skew)
                }
            }
            // final full mesh sync, twice, as the app would do whenever devices meet
            for _ in 0..<2 {
                var (a, b, c) = (replicas[0], replicas[1], replicas[2])
                sync(&a, &b); sync(&b, &c); sync(&a, &c); sync(&a, &b)
                replicas = [a, b, c]
            }
            #expect(replicas[0].snapshot == replicas[1].snapshot, "seed \(seed)")
            #expect(replicas[1].snapshot == replicas[2].snapshot, "seed \(seed)")
            #expect(replicas[0].entryCount == replicas[2].entryCount, "seed \(seed)")
        }
    }

    @Test func interruptedTransferResumesWithoutLossOrDuplicates() {
        var a = Replica(device: devA)
        for i in 0..<50 { a.set(track, "f\(i % 7)", .int(Int64(i)), now: UInt64(i)) }
        var b = Replica(device: devB)

        let all = a.entries(missingFrom: b.vector)
        b.ingest(Array(all.prefix(20)), now: 0)       // connection drops after 20 entries
        #expect(b.entryCount == 20)

        let rest = a.entries(missingFrom: b.vector)    // reconnect: only the missing 30
        #expect(rest.count == 30)
        b.ingest(rest, now: 0)
        #expect(a.snapshot == b.snapshot)
        #expect(b.entryCount == 50)
    }
}
