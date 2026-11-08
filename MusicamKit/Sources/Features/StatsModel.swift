import Foundation
import Observation
import Domain
import Persistence

/// What was played on this device and how often: the source of "Recently Played", "Most Played" and "Least Played".
@MainActor
@Observable
public final class StatsModel {
    public private(set) var stats: [TrackID: PlayStat] = [:]
    @ObservationIgnored private let device: DeviceStore

    public init(device: DeviceStore) { self.device = device }

    public func load() async { stats = (try? await device.playStats()) ?? [:] }

    public func recordPlay(_ id: TrackID) async {
        try? await device.recordPlay(trackID: id)
        await load()
    }

    public func recentlyPlayed(in tracks: [Track], limit: Int) -> [Track] {
        tracks.compactMap { t in stats[t.id]?.lastPlayedAt.map { (t, $0) } }
            .sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// Songs that were played, most plays first (ties: played most recently first).
    public func mostPlayed(in tracks: [Track], limit: Int) -> [Track] {
        tracks.filter { (stats[$0.id]?.count ?? 0) > 0 }
            .sorted { (stats[$0.id]!.count, stats[$0.id]!.lastPlayedAt ?? .distantPast) > (stats[$1.id]!.count, stats[$1.id]!.lastPlayedAt ?? .distantPast) }
            .prefix(limit).map { $0 }
    }

    /// Songs with the fewest plays (never played ones first), oldest additions first among equals.
    public func leastPlayed(in tracks: [Track], limit: Int) -> [Track] {
        tracks.sorted { (stats[$0.id]?.count ?? 0, $0.addedAt) < (stats[$1.id]?.count ?? 0, $1.addedAt) }
            .prefix(limit).map { $0 }
    }

    public func playCount(_ id: TrackID) -> Int { stats[id]?.count ?? 0 }
}
