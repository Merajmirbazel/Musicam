import Domain

public enum RepeatMode: String, Sendable, Codable, CaseIterable {
    case off, all, one

    /// The mode the repeat button cycles to: off, all, one, off ...
    public var next: RepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }
}

/// Pure queue logic with no audio dependency, so it can be unit-tested and reused by any engine.
/// `items` keeps the original order; `order` is the play order (indexes into `items`).
public struct PlayQueue: Equatable, Sendable {
    public private(set) var items: [TrackID]
    private var order: [Int]
    private var position: Int?
    public var repeatMode: RepeatMode = .off
    public private(set) var isShuffled = false

    public init(items: [TrackID] = [], startAt index: Int? = nil) {
        self.items = items
        self.order = Array(items.indices)
        if let index, items.indices.contains(index) { position = index }
    }

    public var current: TrackID? { position.map { items[order[$0]] } }
    public var currentItemIndex: Int? { position.map { order[$0] } }

    /// Tracks that will play after the current one, in play order.
    public var upcoming: [TrackID] {
        let start = (position ?? -1) + 1
        guard start < order.count else { return [] }
        return order[start...].map { items[$0] }
    }

    /// Moves to the next track. `fromTrackEnd` is true when a track finished by itself;
    /// repeat-one only repeats in that case, a manual Next still moves on.
    @discardableResult
    public mutating func advance(fromTrackEnd: Bool = false) -> TrackID? {
        guard !items.isEmpty else { return nil }
        guard let p = position else { position = 0; return current }
        if repeatMode == .one && fromTrackEnd { return current }
        if p + 1 < order.count { position = p + 1; return current }
        if repeatMode == .off && fromTrackEnd { return nil }   // end of queue: stop, keep position
        position = 0                                           // wrap (repeat all, or manual Next)
        return current
    }

    @discardableResult
    public mutating func previous() -> TrackID? {
        guard let p = position else { return nil }
        if p > 0 { position = p - 1 }
        else if repeatMode == .all { position = order.count - 1 }
        return current
    }

    /// Turning shuffle on keeps the current track first; turning it off restores the original order.
    public mutating func setShuffle(_ on: Bool, using rng: inout some RandomNumberGenerator) {
        let cur = currentItemIndex
        if on {
            var rest = items.indices.filter { $0 != cur }
            rest.shuffle(using: &rng)
            order = (cur.map { [$0] } ?? []) + rest
            position = cur == nil ? nil : 0
        } else {
            order = Array(items.indices)
            position = cur
        }
        isShuffled = on
    }

    public mutating func append(_ id: TrackID) {
        items.append(id)
        order.append(items.count - 1)
    }

    /// Inserts right after the current track in play order.
    public mutating func playNext(_ id: TrackID) {
        let orderSlot = (position ?? -1) + 1
        let itemSlot = isShuffled ? items.count : orderSlot
        items.insert(id, at: itemSlot)
        order = order.map { $0 >= itemSlot ? $0 + 1 : $0 }
        order.insert(itemSlot, at: orderSlot)
    }

    /// Returns true if the current track was the one removed.
    @discardableResult
    public mutating func remove(itemAt k: Int) -> Bool {
        guard items.indices.contains(k), let removedPos = order.firstIndex(of: k) else { return false }
        items.remove(at: k)
        order.remove(at: removedPos)
        order = order.map { $0 > k ? $0 - 1 : $0 }
        guard let p = position else { return false }
        if removedPos < p { position = p - 1; return false }
        if removedPos > p { return false }
        position = order.isEmpty ? nil : min(p, order.count - 1)
        return true
    }
}
