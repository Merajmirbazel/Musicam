import Foundation
import Domain

/// A totally ordered timestamp: wall clock, then a counter, then the device ID as a tiebreak.
/// Two devices can never produce the same stamp, so "last writer wins" is deterministic.
public struct HLCTimestamp: Hashable, Comparable, Codable, Sendable {
    public var wallMillis: UInt64
    public var counter: UInt32
    public var device: DeviceID

    public init(wallMillis: UInt64, counter: UInt32, device: DeviceID) {
        self.wallMillis = wallMillis
        self.counter = counter
        self.device = device
    }

    public static func < (a: Self, b: Self) -> Bool {
        if a.wallMillis != b.wallMillis { return a.wallMillis < b.wallMillis }
        if a.counter != b.counter { return a.counter < b.counter }
        return a.device.uuidString < b.device.uuidString
    }
}

/// Hybrid logical clock: never goes backwards, even if the phone's clock is wrong or jumps.
public struct HybridLogicalClock: Sendable {
    public private(set) var last: HLCTimestamp

    public init(device: DeviceID, now: UInt64 = 0) {
        last = HLCTimestamp(wallMillis: now, counter: 0, device: device)
    }

    /// Stamp for a local change.
    public mutating func tick(now: UInt64) -> HLCTimestamp {
        let wall = max(last.wallMillis, now)
        let counter: UInt32 = wall == last.wallMillis ? last.counter + 1 : 0
        last = HLCTimestamp(wallMillis: wall, counter: counter, device: last.device)
        return last
    }

    /// Absorb a stamp seen from another device so later local changes sort after it.
    public mutating func receive(_ remote: HLCTimestamp, now: UInt64) {
        let wall = max(last.wallMillis, remote.wallMillis, now)
        let counter: UInt32
        if wall == last.wallMillis && wall == remote.wallMillis { counter = max(last.counter, remote.counter) + 1 }
        else if wall == last.wallMillis { counter = last.counter + 1 }
        else if wall == remote.wallMillis { counter = remote.counter + 1 }
        else { counter = 0 }
        last = HLCTimestamp(wallMillis: wall, counter: counter, device: last.device)
    }
}
