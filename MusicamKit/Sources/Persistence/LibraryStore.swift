import Foundation
import SwiftData
import Domain
import Sync

public struct AddResult: Sendable, Equatable {
    public var trackID: TrackID
    public var fileID: LibraryFileID
    public var wasDuplicate: Bool
}

/// The synced part of the library: tracks and their file descriptors (architecture, section 3).
///
/// Every change made here is also written to a permanent journal of field-level changes stamped with a hybrid
/// logical clock. Another device that sends us its journal entries gets them merged by "latest stamp wins per
/// field", so both devices end up identical no matter the order, repeats or interruptions (architecture, section 4).
@ModelActor
public actor LibraryStore {
    private var ready = false
    private var deviceID = DeviceID()
    private var clock = HybridLogicalClock(device: DeviceID())
    private var vector = VersionVector()
    private var trackCache: [UUID: TrackRecord] = [:]
    private var fileCache: [UUID: AudioFileRecord] = [:]
    private var playlistCache: [UUID: PlaylistRecord] = [:]

    /// `url == nil` keeps everything in memory (tests).
    public static func open(at url: URL?) throws -> LibraryStore {
        let schema = Schema([TrackRecord.self, AudioFileRecord.self, ChangeRecord.self, StoreMeta.self, PlaylistRecord.self])
        let configuration = url.map { ModelConfiguration(schema: schema, url: $0) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: configuration)
        return LibraryStore(modelContainer: container)
    }

    // MARK: Library API

    /// Adds files in one transaction. A file whose hash is already known is reported as a duplicate, not added.
    public func add(_ items: [ImportedItem]) throws -> [AddResult] {
        try ensureReady()
        var results: [AddResult] = []
        var addedInBatch: [String: AddResult] = [:]
        let now = nowMillis()
        for item in items {
            if let existing = addedInBatch[item.contentHash] {
                results.append(AddResult(trackID: existing.trackID, fileID: existing.fileID, wasDuplicate: true))
                continue
            }
            let hash = item.contentHash
            var descriptor = FetchDescriptor<AudioFileRecord>(predicate: #Predicate { $0.contentHash == hash })
            descriptor.fetchLimit = 1
            if let known = try modelContext.fetch(descriptor).first, let track = known.track {
                if track.deletedAt != nil {
                    // The song was removed earlier and is being added again: bring the same song back (its ID, ratings and
                    // playlist places) instead of calling it a duplicate of something that is gone.
                    track.deletedAt = nil
                    track.addedAt = .now
                    track.updatedAt = .now
                    if !item.source.isEmpty { known.source = item.source }
                    emit("Track", track.id, "deletedAt", .null, now: now)
                    emit("Track", track.id, "addedAt", .double(track.addedAt.timeIntervalSinceReferenceDate), now: now)
                    if !item.source.isEmpty { emit("AudioFile", known.id, "source", .string(known.source), now: now) }
                    let restored = AddResult(trackID: track.id, fileID: known.id, wasDuplicate: false)
                    addedInBatch[hash] = restored
                    results.append(restored)
                    continue
                }
                results.append(AddResult(trackID: track.id, fileID: known.id, wasDuplicate: true))
                continue
            }
            let track = TrackRecord(metadata: item.metadata)
            let file = AudioFileRecord(item: item)
            modelContext.insert(track)
            modelContext.insert(file)
            file.track = track
            let result = AddResult(trackID: track.id, fileID: file.id, wasDuplicate: false)
            addedInBatch[hash] = result
            results.append(result)
            emitCreation(track: track, file: file, now: now)
        }
        try modelContext.save()
        return results
    }

    public func allTracks() throws -> [Track] {
        try ensureReady()      // also gives libraries made before sync existed their journal, on the first load
        let descriptor = FetchDescriptor<TrackRecord>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.addedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map(\.snapshot)
    }

    public func track(id: TrackID) throws -> Track? {
        try record(id).map(\.snapshot)
    }

    public func trackCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<TrackRecord>(predicate: #Predicate { $0.deletedAt == nil }))
    }

    @discardableResult
    public func edit(trackID: TrackID, _ edit: TrackEdit) throws -> Track? {
        try ensureReady()
        guard let record = try record(trackID) else { return nil }
        let now = nowMillis()
        func change<T: Equatable>(_ old: T, _ new: T?, _ field: String, _ value: (T) -> ChangeValue, set: (T) -> Void) {
            guard let new, new != old else { return }
            set(new)
            emit("Track", trackID, field, value(new), now: now)
        }
        change(record.title, edit.title, "title", { .string($0) }) { record.title = $0 }
        change(record.artist, edit.artist, "artist", { .string($0) }) { record.artist = $0 }
        change(record.album, edit.album, "album", { .string($0) }) { record.album = $0 }
        change(record.albumArtist, edit.albumArtist, "albumArtist", { .string($0) }) { record.albumArtist = $0 }
        change(record.genre, edit.genre, "genre", { .string($0) }) { record.genre = $0 }
        change(record.rating, edit.rating.map { min(max($0, 0), 5) }, "rating", { .int(Int64($0)) }) { record.rating = $0 }
        change(record.isFavorite, edit.isFavorite, "isFavorite", { .bool($0) }) { record.isFavorite = $0 }
        if let key = edit.artworkKey {
            let new: String? = key.isEmpty ? nil : key
            if new != record.artworkKey {
                record.artworkKey = new
                emit("Track", trackID, "artworkKey", new.map { .string($0) } ?? .null, now: now)
            }
        }
        record.updatedAt = .now
        try modelContext.save()
        return record.snapshot
    }

    // MARK: Duplicate merge

    public struct FileMerge: Sendable, Equatable {
        public var loser: LibraryFileID
        public var winner: LibraryFileID
    }

    /// Two devices that imported the same file each create their own song for it. Once they sync, this keeps the
    /// oldest one (ties broken by ID, so every device picks the same) and hides the others, carrying over the best
    /// rating and favorite flag. Returns which file ID now stands for which, so a device that holds the audio under
    /// the old ID can still find it.
    @discardableResult
    public func mergeDuplicateTracks() throws -> [FileMerge] {
        try ensureReady()
        let live = try modelContext.fetch(FetchDescriptor<TrackRecord>(predicate: #Predicate { $0.deletedAt == nil }))
        var groups: [String: [TrackRecord]] = [:]
        for t in live {
            guard let hash = t.files?.first?.contentHash, !hash.isEmpty else { continue }
            groups[hash, default: []].append(t)
        }
        var merges: [FileMerge] = []
        let now = nowMillis()
        for (_, members) in groups where members.count > 1 {
            let ordered = members.sorted { ($0.addedAt, $0.id.uuidString) < ($1.addedAt, $1.id.uuidString) }
            let winner = ordered[0]
            for loser in ordered.dropFirst() {
                if loser.rating > winner.rating {
                    winner.rating = loser.rating
                    emit("Track", winner.id, "rating", .int(Int64(loser.rating)), now: now)
                }
                if loser.isFavorite && !winner.isFavorite {
                    winner.isFavorite = true
                    emit("Track", winner.id, "isFavorite", .bool(true), now: now)
                }
                loser.deletedAt = Date(timeIntervalSince1970: Double(now) / 1000)
                loser.updatedAt = .now
                emit("Track", loser.id, "deletedAt", .double(Double(now) / 1000), now: now)
                if let lf = loser.files?.first, let wf = winner.files?.first { merges.append(FileMerge(loser: lf.id, winner: wf.id)) }
            }
        }
        if !merges.isEmpty { try modelContext.save() }
        return merges
    }

    // MARK: Playlists

    public func allPlaylists() throws -> [Playlist] {
        try ensureReady()
        let all = try modelContext.fetch(FetchDescriptor<PlaylistRecord>(predicate: #Predicate { $0.deletedAt == nil }))
        // lists that used to be smart playlists are hidden (their rules stay stored, nothing is deleted)
        return all.filter { $0.rules.isEmpty }.map(\.snapshot).sorted { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    public func createPlaylist(name: String, trackIDs: [TrackID] = []) throws -> Playlist {
        try ensureReady()
        let now = nowMillis()
        let record = PlaylistRecord(id: UUID())
        record.name = name
        record.trackIDs = PlaylistRecord.join(trackIDs)
        modelContext.insert(record)
        emit("Playlist", record.id, "name", .string(record.name), now: now)
        emit("Playlist", record.id, "trackIDs", .string(record.trackIDs), now: now)
        emit("Playlist", record.id, "createdAt", .double(record.createdAt.timeIntervalSinceReferenceDate), now: now)
        try modelContext.save()
        return record.snapshot
    }

    /// Changes only what is given.
    @discardableResult
    public func updatePlaylist(_ id: PlaylistID, name: String? = nil, trackIDs: [TrackID]? = nil) throws -> Playlist? {
        try ensureReady()
        guard let record = try playlistRecord(existing: id), record.deletedAt == nil else { return nil }
        let now = nowMillis()
        if let name, name != record.name {
            record.name = name
            emit("Playlist", id, "name", .string(name), now: now)
        }
        if let trackIDs {
            let joined = PlaylistRecord.join(trackIDs)
            if joined != record.trackIDs {
                record.trackIDs = joined
                emit("Playlist", id, "trackIDs", .string(joined), now: now)
            }
        }
        try modelContext.save()
        return record.snapshot
    }

    /// Undo for `deletePlaylist`.
    public func restorePlaylist(_ id: PlaylistID) throws {
        try ensureReady()
        guard let record = try playlistRecord(existing: id), record.deletedAt != nil else { return }
        record.deletedAt = nil
        emit("Playlist", id, "deletedAt", .null, now: nowMillis())
        try modelContext.save()
    }

    public func deletePlaylist(_ id: PlaylistID) throws {
        try ensureReady()
        guard let record = try playlistRecord(existing: id), record.deletedAt == nil else { return }
        let now = nowMillis()
        record.deletedAt = Date(timeIntervalSince1970: Double(now) / 1000)
        emit("Playlist", id, "deletedAt", .double(Double(now) / 1000), now: now)
        try modelContext.save()
    }

    /// Brings removed songs back (the opposite of `softDelete`). Used by Undo and when a removed file is added again.
    public func restore(trackIDs: [TrackID]) throws {
        try ensureReady()
        let now = nowMillis()
        for id in trackIDs {
            guard let record = try record(id), record.deletedAt != nil else { continue }
            record.deletedAt = nil
            record.updatedAt = .now
            emit("Track", id, "deletedAt", .null, now: now)
        }
        try modelContext.save()
    }

    /// File IDs of songs that were removed, so an import never mistakes them for songs that are still in the library.
    public func deletedFileIDs() throws -> Set<LibraryFileID> {
        let gone = try modelContext.fetch(FetchDescriptor<TrackRecord>(predicate: #Predicate { $0.deletedAt != nil }))
        return Set(gone.flatMap { $0.files ?? [] }.map(\.id))
    }

    /// Soft delete: the record stays so other devices can learn about it (architecture, section 4).
    public func softDelete(trackIDs: [TrackID]) throws {
        try ensureReady()
        let now = nowMillis()
        for id in trackIDs {
            guard let record = try record(id), record.deletedAt == nil else { continue }
            record.deletedAt = Date(timeIntervalSince1970: Double(now) / 1000)
            record.updatedAt = .now
            emit("Track", id, "deletedAt", .double(Double(now) / 1000), now: now)
        }
        try modelContext.save()
    }

    public func fileInfo(_ fileID: LibraryFileID) throws -> AudioFileInfo? {
        var descriptor = FetchDescriptor<AudioFileRecord>(predicate: #Predicate { $0.id == fileID })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.info
    }

    // MARK: Sync API

    /// This device's permanent identity.
    public func deviceIdentity() throws -> DeviceID {
        try ensureReady()
        return deviceID
    }

    /// For each device, the newest change this library holds. Sent to a peer so it can reply with what is missing.
    public func versionVector() throws -> VersionVector {
        try ensureReady()
        return vector
    }

    public func changeCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<ChangeRecord>())
    }

    /// Every change a peer holding `remote` has not seen, oldest first.
    public func changes(missingFrom remote: VersionVector) throws -> [ChangeEntry] {
        try ensureReady()
        var out: [ChangeEntry] = []
        for record in try modelContext.fetch(FetchDescriptor<ChangeRecord>()) {
            let stamp = record.stamp
            if let seen = remote.newest[stamp.device], stamp <= seen { continue }
            out.append(record.entry)
        }
        return out.sorted { $0.stamp < $1.stamp }
    }

    /// Merges changes received from a peer. Safe with repeats, any order and partial batches.
    /// Returns how many were new to this library.
    @discardableResult
    public func ingest(_ entries: [ChangeEntry]) throws -> Int {
        try ensureReady()
        defer { trackCache = [:]; fileCache = [:]; playlistCache = [:] }
        var added = 0
        let grouped = Dictionary(grouping: entries, by: \.key)
        for (key, group) in grouped {
            // what we already hold for this record: its stamps, and the newest stamp per field
            let entityID = key.id
            let existing = try modelContext.fetch(FetchDescriptor<ChangeRecord>(predicate: #Predicate { $0.entityID == entityID }))
            var known = Set(existing.map(\.stamp))
            var newestByField: [String: HLCTimestamp] = [:]
            for record in existing where newestByField[record.field].map({ $0 < record.stamp }) ?? true {
                newestByField[record.field] = record.stamp
            }
            for entry in group.sorted(by: { $0.stamp < $1.stamp }) where !known.contains(entry.stamp) {
                known.insert(entry.stamp)
                modelContext.insert(ChangeRecord(entry: entry))
                clock.receive(entry.stamp, now: nowMillis())
                noteInVector(entry.stamp)
                added += 1
                if let current = newestByField[entry.field], current >= entry.stamp { continue }   // older than what we hold
                newestByField[entry.field] = entry.stamp
                try apply(entry)
            }
        }
        try linkFilesToTracks()
        try modelContext.save()
        return added
    }

    // MARK: Journal

    private func ensureReady() throws {
        guard !ready else { return }
        var descriptor = FetchDescriptor<StoreMeta>()
        descriptor.fetchLimit = 1
        let meta: StoreMeta
        if let existing = try modelContext.fetch(descriptor).first {
            meta = existing
        } else {
            meta = StoreMeta()
            modelContext.insert(meta)
            try modelContext.save()
        }
        deviceID = meta.deviceID
        var newest: [DeviceID: HLCTimestamp] = [:]
        for record in try modelContext.fetch(FetchDescriptor<ChangeRecord>()) {
            let stamp = record.stamp
            if newest[stamp.device].map({ $0 < stamp }) ?? true { newest[stamp.device] = stamp }
        }
        vector.newest = newest
        var restored = HybridLogicalClock(device: deviceID, now: nowMillis())
        for stamp in newest.values { restored.receive(stamp, now: nowMillis()) }   // never reuse or go below any stamp seen
        clock = restored

        // A library made before sync existed has songs but no journal; give each existing song its journal entries once.
        if newest.isEmpty {
            let existing = try modelContext.fetch(FetchDescriptor<TrackRecord>())
            let now = nowMillis()
            for track in existing {
                emitCreation(track: track, file: track.files?.first, now: now)
                if let deleted = track.deletedAt { emit("Track", track.id, "deletedAt", .double(deleted.timeIntervalSince1970), now: now) }
            }
            if !existing.isEmpty { try modelContext.save() }
        }
        ready = true
    }

    /// Test seam: adds a song the way versions before sync did, without journal entries.
    func insertLegacySongForTesting(_ item: ImportedItem) throws {
        let track = TrackRecord(metadata: item.metadata)
        let file = AudioFileRecord(item: item)
        modelContext.insert(track)
        modelContext.insert(file)
        file.track = track
        try modelContext.save()
    }

    private func nowMillis() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }

    private func noteInVector(_ stamp: HLCTimestamp) {
        if vector.newest[stamp.device].map({ $0 < stamp }) ?? true { vector.newest[stamp.device] = stamp }
    }

    private func emit(_ entity: String, _ id: UUID, _ field: String, _ value: ChangeValue, now: UInt64) {
        let entry = ChangeEntry(key: EntityKey(entity: entity, id: id), field: field, value: value, stamp: clock.tick(now: now))
        modelContext.insert(ChangeRecord(entry: entry))
        noteInVector(entry.stamp)
    }

    private func emitCreation(track t: TrackRecord, file f: AudioFileRecord?, now: UInt64) {
        let id = t.id
        emit("Track", id, "title", .string(t.title), now: now)
        emit("Track", id, "artist", .string(t.artist), now: now)
        emit("Track", id, "album", .string(t.album), now: now)
        emit("Track", id, "albumArtist", .string(t.albumArtist), now: now)
        emit("Track", id, "trackNumber", t.trackNumber.map { .int(Int64($0)) } ?? .null, now: now)
        emit("Track", id, "discNumber", t.discNumber.map { .int(Int64($0)) } ?? .null, now: now)
        emit("Track", id, "year", t.year.map { .int(Int64($0)) } ?? .null, now: now)
        emit("Track", id, "genre", .string(t.genre), now: now)
        emit("Track", id, "rating", .int(Int64(t.rating)), now: now)
        emit("Track", id, "isFavorite", .bool(t.isFavorite), now: now)
        emit("Track", id, "addedAt", .double(t.addedAt.timeIntervalSinceReferenceDate), now: now)
        emit("Track", id, "duration", .double(t.duration), now: now)
        emit("Track", id, "artworkKey", t.artworkKey.map { .string($0) } ?? .null, now: now)
        guard let f else { return }
        let fid = f.id
        emit("AudioFile", fid, "contentHash", .string(f.contentHash), now: now)
        emit("AudioFile", fid, "byteSize", .int(f.byteSize), now: now)
        emit("AudioFile", fid, "originalFilename", .string(f.originalFilename), now: now)
        emit("AudioFile", fid, "codec", .string(f.codec), now: now)
        emit("AudioFile", fid, "sampleRate", .double(f.sampleRate), now: now)
        emit("AudioFile", fid, "bitDepth", f.bitDepth.map { .int(Int64($0)) } ?? .null, now: now)
        emit("AudioFile", fid, "channels", .int(Int64(f.channels)), now: now)
        emit("AudioFile", fid, "bitrate", f.bitrate.map { .int(Int64($0)) } ?? .null, now: now)
        emit("AudioFile", fid, "isLossless", .bool(f.isLossless), now: now)
        emit("AudioFile", fid, "duration", .double(f.duration), now: now)
        emit("AudioFile", fid, "source", .string(f.source), now: now)
        emit("AudioFile", fid, "trackID", .string(id.uuidString), now: now)
    }

    // MARK: Applying remote changes to records

    private func apply(_ entry: ChangeEntry) throws {
        switch entry.key.entity {
        case "Track":
            let t = try trackRecord(entry.key.id)
            switch (entry.field, entry.value) {
            case ("title", .string(let v)): t.title = v
            case ("artist", .string(let v)): t.artist = v
            case ("album", .string(let v)): t.album = v
            case ("albumArtist", .string(let v)): t.albumArtist = v
            case ("genre", .string(let v)): t.genre = v
            case ("trackNumber", let v): t.trackNumber = Self.int(v)
            case ("discNumber", let v): t.discNumber = Self.int(v)
            case ("year", let v): t.year = Self.int(v)
            case ("rating", let v): t.rating = Self.int(v) ?? 0
            case ("isFavorite", .bool(let v)): t.isFavorite = v
            case ("addedAt", .double(let v)): t.addedAt = Date(timeIntervalSinceReferenceDate: v)
            case ("duration", .double(let v)): t.duration = v
            case ("artworkKey", let v): if case .string(let s) = v { t.artworkKey = s } else { t.artworkKey = nil }
            case ("deletedAt", let v): if case .double(let d) = v { t.deletedAt = Date(timeIntervalSince1970: d) } else { t.deletedAt = nil }
            default: break
            }
            t.updatedAt = .now
        case "AudioFile":
            let f = try fileRecord(entry.key.id)
            switch (entry.field, entry.value) {
            case ("contentHash", .string(let v)): f.contentHash = v
            case ("byteSize", let v): f.byteSize = Int64(Self.int(v) ?? 0)
            case ("originalFilename", .string(let v)): f.originalFilename = v
            case ("codec", .string(let v)): f.codec = v
            case ("sampleRate", .double(let v)): f.sampleRate = v
            case ("bitDepth", let v): f.bitDepth = Self.int(v)
            case ("channels", let v): f.channels = Self.int(v) ?? 0
            case ("bitrate", let v): f.bitrate = Self.int(v)
            case ("isLossless", .bool(let v)): f.isLossless = v
            case ("duration", .double(let v)): f.duration = v
            case ("source", .string(let v)): f.source = v
            case ("trackID", .string(let v)):
                if let tid = UUID(uuidString: v) { f.track = try trackRecord(tid) }
            default: break
            }
        case "Playlist":
            let p = try playlistRecord(entry.key.id)
            switch (entry.field, entry.value) {
            case ("name", .string(let v)): p.name = v
            case ("trackIDs", .string(let v)): p.trackIDs = v
            case ("rules", .string(let v)): p.rules = v
            case ("createdAt", .double(let v)): p.createdAt = Date(timeIntervalSinceReferenceDate: v)
            case ("deletedAt", let v): if case .double(let d) = v { p.deletedAt = Date(timeIntervalSince1970: d) } else { p.deletedAt = nil }
            default: break
            }
        default: break
        }
    }

    private static func int(_ v: ChangeValue) -> Int? {
        if case .int(let i) = v { return Int(i) }
        return nil
    }

    /// A change can arrive before the record it belongs to; the record is created on first touch.
    private func trackRecord(_ id: UUID) throws -> TrackRecord {
        if let cached = trackCache[id] { return cached }
        let found = try record(id) ?? {
            let shell = TrackRecord(id: id, metadata: ExtractedMetadata(title: "", format: AudioFormat(codec: "")))
            modelContext.insert(shell)
            return shell
        }()
        trackCache[id] = found
        return found
    }

    private func playlistRecord(_ id: UUID) throws -> PlaylistRecord {
        if let cached = playlistCache[id] { return cached }
        let found = try playlistRecord(existing: id) ?? {
            let shell = PlaylistRecord(id: id)
            modelContext.insert(shell)
            return shell
        }()
        playlistCache[id] = found
        return found
    }

    private func playlistRecord(existing id: UUID) throws -> PlaylistRecord? {
        var descriptor = FetchDescriptor<PlaylistRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func fileRecord(_ id: UUID) throws -> AudioFileRecord {
        if let cached = fileCache[id] { return cached }
        var descriptor = FetchDescriptor<AudioFileRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        let found: AudioFileRecord
        if let existing = try modelContext.fetch(descriptor).first {
            found = existing
        } else {
            found = AudioFileRecord(id: id, item: ImportedItem(metadata: ExtractedMetadata(title: "", format: AudioFormat(codec: "")),
                                                              contentHash: "", byteSize: 0, originalFilename: ""))
            modelContext.insert(found)
        }
        fileCache[id] = found
        return found
    }

    /// Re-links any file whose track record arrived after it (relationships are rebuilt from the `trackID` field).
    private func linkFilesToTracks() throws {
        for file in fileCache.values where file.track == nil {
            let fid = file.id
            let entries = try modelContext.fetch(FetchDescriptor<ChangeRecord>(predicate: #Predicate { $0.entityID == fid && $0.field == "trackID" }))
            if let newest = entries.max(by: { $0.stamp < $1.stamp }),
               case .string(let s) = newest.entry.value, let tid = UUID(uuidString: s) {
                file.track = try trackRecord(tid)
            }
        }
    }

    private func record(_ id: TrackID) throws -> TrackRecord? {
        var descriptor = FetchDescriptor<TrackRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
