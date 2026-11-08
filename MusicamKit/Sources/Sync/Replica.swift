import Foundation
import Domain

public enum ChangeValue: Hashable, Codable, Sendable {
    case null
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
}

public struct EntityKey: Hashable, Codable, Sendable {
    public var entity: String
    public var id: UUID
    public init(entity: String, id: UUID) { self.entity = entity; self.id = id }
}

/// One immutable change to one field of one record. The unit that devices exchange.
public struct ChangeEntry: Hashable, Codable, Sendable {
    public var key: EntityKey
    public var field: String
    public var value: ChangeValue
    public var stamp: HLCTimestamp
    public init(key: EntityKey, field: String, value: ChangeValue, stamp: HLCTimestamp) {
        self.key = key; self.field = field; self.value = value; self.stamp = stamp
    }
}

/// For each device, the newest stamp this replica holds. Per-device history is prefix-closed
/// because entries are always applied in stamp order per device (see `entries(missingFrom:)`).
public struct VersionVector: Equatable, Codable, Sendable {
    public var newest: [DeviceID: HLCTimestamp] = [:]
    public init() {}
}

/// A device's copy of the shared data: an append-only change log plus the merged field values.
/// Merge rule: per field, the entry with the greatest stamp wins. That rule is commutative,
/// associative and idempotent, so any delivery order, repeat or interruption converges.
public struct Replica: Sendable {
    public let device: DeviceID
    private var clock: HybridLogicalClock
    private var log: [HLCTimestamp: ChangeEntry] = [:]
    private var fields: [EntityKey: [String: ChangeEntry]] = [:]
    public private(set) var vector = VersionVector()

    public init(device: DeviceID, now: UInt64 = 0) {
        self.device = device
        self.clock = HybridLogicalClock(device: device, now: now)
    }

    public var entryCount: Int { log.count }

    /// Record a local change.
    @discardableResult
    public mutating func set(_ key: EntityKey, _ field: String, _ value: ChangeValue, now: UInt64) -> ChangeEntry {
        let entry = ChangeEntry(key: key, field: field, value: value, stamp: clock.tick(now: now))
        apply(entry)
        return entry
    }

    /// Apply entries from a peer. Safe to call with repeats and any order. Returns how many were new.
    @discardableResult
    public mutating func ingest(_ entries: [ChangeEntry], now: UInt64) -> Int {
        var added = 0
        for entry in entries.sorted(by: { $0.stamp < $1.stamp }) where log[entry.stamp] == nil {
            clock.receive(entry.stamp, now: now)
            apply(entry)
            added += 1
        }
        return added
    }

    public func value(of key: EntityKey, field: String) -> ChangeValue? {
        fields[key]?[field]?.value
    }

    /// Everything this replica has that a peer with `remote` is missing, oldest first.
    public func entries(missingFrom remote: VersionVector) -> [ChangeEntry] {
        log.values
            .filter { entry in
                guard let seen = remote.newest[entry.stamp.device] else { return true }
                return entry.stamp > seen
            }
            .sorted { $0.stamp < $1.stamp }
    }

    /// The merged state, for comparison and persistence.
    public var snapshot: [EntityKey: [String: ChangeValue]] {
        fields.mapValues { $0.mapValues(\.value) }
    }

    private mutating func apply(_ entry: ChangeEntry) {
        log[entry.stamp] = entry
        if let current = fields[entry.key]?[entry.field], current.stamp >= entry.stamp {
            // an older write for this field: keep it in the log, ignore it in the state
        } else {
            fields[entry.key, default: [:]][entry.field] = entry
        }
        if let seen = vector.newest[entry.stamp.device], seen >= entry.stamp { return }
        vector.newest[entry.stamp.device] = entry.stamp
    }
}
