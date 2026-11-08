import Foundation
import Domain

public enum RepairReason: String, Codable, Sendable {
    case garbledText, junkRemoved, fromFilename, persianLetters, fromMusicBrainz
}

public enum RepairField: String, Codable, Sendable, CaseIterable {
    case title, artist, album, albumArtist, artwork
}

/// One suggested change to one field, with the value it replaces.
public struct FieldChange: Codable, Hashable, Sendable {
    public var field: RepairField
    public var before: String
    public var after: String
    public var reason: RepairReason

    public init(field: RepairField, before: String, after: String, reason: RepairReason) {
        self.field = field; self.before = before; self.after = after; self.reason = reason
    }
}

public struct RepairProposal: Identifiable, Hashable, Sendable {
    public var id: TrackID { trackID }
    public let trackID: TrackID
    public var changes: [FieldChange]
    /// 0...1: how sure the rule is. Text repairs are high; guessing from a filename is lower.
    public var confidence: Double
    public var isSafe: Bool { confidence >= 0.85 }

    public init(trackID: TrackID, changes: [FieldChange], confidence: Double) {
        self.trackID = trackID; self.changes = changes; self.confidence = confidence
    }

    public var edit: TrackEdit {
        var e = TrackEdit()
        for c in changes {
            switch c.field {
            case .title: e.title = c.after
            case .artist: e.artist = c.after
            case .album: e.album = c.after
            case .albumArtist: e.albumArtist = c.after
            case .artwork: e.artworkKey = c.after
            }
        }
        return e
    }

    /// The edit that puts every changed field back as it was.
    public var undoEdit: TrackEdit {
        var e = TrackEdit()
        for c in changes {
            switch c.field {
            case .title: e.title = c.before
            case .artist: e.artist = c.before
            case .album: e.album = c.before
            case .albumArtist: e.albumArtist = c.before
            case .artwork: e.artworkKey = c.before
            }
        }
        return e
    }
}

/// Builds suggestions from rules alone (no network).
public enum RepairPlanner {
    public static func proposal(for track: Track) -> RepairProposal? {
        var changes: [FieldChange] = []
        var confidence = 1.0
        let current: [(RepairField, String)] = [(.title, track.title), (.artist, track.artist), (.album, track.album), (.albumArtist, track.albumArtist)]
        var working: [RepairField: String] = Dictionary(uniqueKeysWithValues: current)

        // 1) garbled text, then junk
        for (field, value) in current where !value.isEmpty {
            if let fixed = MojibakeRepair.repaired(value) {
                changes.append(FieldChange(field: field, before: value, after: fixed, reason: .garbledText))
                working[field] = fixed
            } else {
                let stripped = FilenameCleaner.stripJunk(value)
                if stripped != value, !stripped.isEmpty {
                    changes.append(FieldChange(field: field, before: value, after: stripped, reason: .junkRemoved))
                    working[field] = stripped
                } else if PersianNormalizer.normalize(value) != value {
                    let n = PersianNormalizer.normalize(value)
                    changes.append(FieldChange(field: field, before: value, after: n, reason: .persianLetters))
                    working[field] = n
                }
            }
        }

        // 2) a title that is really the file name, or a generic one: take artist and title from the name
        let title = working[.title] ?? ""
        let artistMissing = (working[.artist] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        if let filename = track.file?.originalFilename,
           FilenameCleaner.isGeneric(title) || title.isEmpty || (artistMissing && track.title == (filename as NSString).deletingPathExtension) {
            let cleaned = FilenameCleaner.clean(filename: filename)
            if !FilenameCleaner.isGeneric(cleaned.title), cleaned.title != title {
                changes.removeAll { $0.field == .title }
                changes.append(FieldChange(field: .title, before: track.title, after: cleaned.title, reason: .fromFilename))
                confidence = min(confidence, 0.7)
                if artistMissing, let artist = cleaned.artist {
                    changes.removeAll { $0.field == .artist }
                    changes.append(FieldChange(field: .artist, before: track.artist, after: artist, reason: .fromFilename))
                }
            }
        }
        changes = changes.filter { $0.before != $0.after }
        guard !changes.isEmpty else { return nil }
        return RepairProposal(trackID: track.id, changes: changes, confidence: confidence)
    }

    public static func proposals(for tracks: [Track]) -> [RepairProposal] {
        tracks.compactMap(proposal(for:))
    }
}

/// What was applied, kept so every repair can be taken back.
public struct RepairRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var trackID: TrackID
    public var changes: [FieldChange]
    public var appliedAt: Date
    public var undoneAt: Date?
}

/// Device-local list of applied repairs, saved as a small JSON file.
public actor RepairHistory {
    private var records: [RepairRecord]
    private let url: URL?

    public init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([RepairRecord].self, from: data) {
            records = saved
        } else {
            records = []
        }
    }

    public func all() -> [RepairRecord] { records.sorted { $0.appliedAt > $1.appliedAt } }

    @discardableResult
    public func record(_ proposal: RepairProposal, at date: Date = .now) -> RepairRecord {
        let r = RepairRecord(id: UUID(), trackID: proposal.trackID, changes: proposal.changes, appliedAt: date, undoneAt: nil)
        records.append(r)
        save()
        return r
    }

    public func markUndone(_ id: UUID, at date: Date = .now) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].undoneAt = date
        save()
    }

    public func record(id: UUID) -> RepairRecord? { records.first { $0.id == id } }

    /// Forgets records once their undo time is over.
    public func remove(ids: Set<UUID>) {
        records.removeAll { ids.contains($0.id) }
        save()
    }

    public func purge(appliedBefore date: Date) {
        records.removeAll { $0.appliedAt < date }
        save()
    }

    private func save() {
        guard let url, let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

public extension RepairRecord {
    var undoEdit: TrackEdit {
        var e = TrackEdit()
        for c in changes {
            switch c.field {
            case .title: e.title = c.before
            case .artist: e.artist = c.before
            case .album: e.album = c.before
            case .albumArtist: e.albumArtist = c.before
            case .artwork: e.artworkKey = c.before
            }
        }
        return e
    }
}
