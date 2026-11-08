import Foundation
import SwiftData
import Domain

public enum LocalFileState: String, Sendable {
    case present, missing
}

/// Where one library file lives on this device.
public struct LocalFileInfo: Sendable, Hashable {
    public var audioFileID: LibraryFileID
    public var bookmark: Data
    public var path: String
    public var byteSize: Int64
    public var modificationDate: Date?
    public var state: LocalFileState
    public var acquiredAt: Date?

    public init(audioFileID: LibraryFileID, bookmark: Data, path: String, byteSize: Int64, modificationDate: Date?, state: LocalFileState = .present, acquiredAt: Date? = .now) {
        self.acquiredAt = acquiredAt
        self.audioFileID = audioFileID
        self.bookmark = bookmark
        self.path = path
        self.byteSize = byteSize
        self.modificationDate = modificationDate
        self.state = state
    }
}

public struct WatchedFolder: Sendable, Hashable, Identifiable {
    public var path: String
    public var bookmark: Data
    public var id: String { path }

    public init(path: String, bookmark: Data) {
        self.path = path
        self.bookmark = bookmark
    }
}

/// Per-device facts that must never be synced (architecture, section 1).
@ModelActor
public actor DeviceStore {
    public static func open(at url: URL?) throws -> DeviceStore {
        let schema = Schema([LocalFileRecord.self, WatchedFolderRecord.self, PlayStatRecord.self])
        let configuration = url.map { ModelConfiguration(schema: schema, url: $0) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: configuration)
        return DeviceStore(modelContainer: container)
    }

    /// Insert or replace the entry for each file ID.
    public func register(_ entries: [LocalFileInfo]) throws {
        for entry in entries {
            let id = entry.audioFileID
            var descriptor = FetchDescriptor<LocalFileRecord>(predicate: #Predicate { $0.audioFileID == id })
            descriptor.fetchLimit = 1
            if let existing = try modelContext.fetch(descriptor).first {
                existing.bookmark = entry.bookmark
                existing.path = entry.path
                existing.byteSize = entry.byteSize
                existing.modificationDate = entry.modificationDate
                existing.state = entry.state.rawValue
                existing.verifiedAt = .now
                if existing.acquiredAt == nil { existing.acquiredAt = entry.acquiredAt }
            } else {
                modelContext.insert(LocalFileRecord(info: entry))
            }
        }
        try modelContext.save()
    }

    public func entry(for fileID: LibraryFileID) throws -> LocalFileInfo? {
        var descriptor = FetchDescriptor<LocalFileRecord>(predicate: #Predicate { $0.audioFileID == fileID })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first.map(Self.info)
    }

    /// Every file this device knows, keyed by path. Used to skip unchanged files on re-import.
    public func knownFilesByPath() throws -> [String: LocalFileInfo] {
        var map: [String: LocalFileInfo] = [:]
        for record in try modelContext.fetch(FetchDescriptor<LocalFileRecord>()) {
            map[record.path] = Self.info(record)
        }
        return map
    }

    public func watchedFolders() throws -> [WatchedFolder] {
        try modelContext.fetch(FetchDescriptor<WatchedFolderRecord>(sortBy: [SortDescriptor(\.addedAt)]))
            .map { WatchedFolder(path: $0.path, bookmark: $0.bookmark) }
    }

    /// Adds the folder, or refreshes its bookmark if it is already watched.
    public func addWatchedFolder(_ folder: WatchedFolder) throws {
        let path = folder.path
        var descriptor = FetchDescriptor<WatchedFolderRecord>(predicate: #Predicate { $0.path == path })
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            existing.bookmark = folder.bookmark
        } else {
            modelContext.insert(WatchedFolderRecord(path: folder.path, bookmark: folder.bookmark))
        }
        try modelContext.save()
    }

    public func removeWatchedFolder(path: String) throws {
        for record in try modelContext.fetch(FetchDescriptor<WatchedFolderRecord>(predicate: #Predicate { $0.path == path })) {
            modelContext.delete(record)
        }
        try modelContext.save()
    }

    /// Forgets where files are kept on this device (after their songs were removed), so adding the same file again starts clean.
    public func forget(_ fileIDs: [LibraryFileID]) throws {
        for id in fileIDs {
            for record in try modelContext.fetch(FetchDescriptor<LocalFileRecord>(predicate: #Predicate { $0.audioFileID == id })) {
                modelContext.delete(record)
            }
        }
        try modelContext.save()
    }

    // MARK: Play history (this device only)

    public func recordPlay(trackID: TrackID, at date: Date = .now) throws {
        var descriptor = FetchDescriptor<PlayStatRecord>(predicate: #Predicate { $0.trackID == trackID })
        descriptor.fetchLimit = 1
        let record = try modelContext.fetch(descriptor).first ?? {
            let fresh = PlayStatRecord(trackID: trackID)
            modelContext.insert(fresh)
            return fresh
        }()
        record.count += 1
        record.lastPlayedAt = date
        try modelContext.save()
    }

    public func playStats() throws -> [TrackID: PlayStat] {
        var map: [TrackID: PlayStat] = [:]
        for r in try modelContext.fetch(FetchDescriptor<PlayStatRecord>()) { map[r.trackID] = PlayStat(count: r.count, lastPlayedAt: r.lastPlayedAt) }
        return map
    }

    /// IDs of the library files this device actually holds right now.
    public func presentFileIDs() throws -> Set<LibraryFileID> {
        let present = LocalFileState.present.rawValue
        let records = try modelContext.fetch(FetchDescriptor<LocalFileRecord>(predicate: #Predicate { $0.state == present }))
        return Set(records.map(\.audioFileID))
    }

    /// Every file entry this device holds, for deciding what can be cleaned up.
    public func presentEntries() throws -> [LocalFileInfo] {
        let present = LocalFileState.present.rawValue
        return try modelContext.fetch(FetchDescriptor<LocalFileRecord>(predicate: #Predicate { $0.state == present })).map(Self.info)
    }

    /// When two songs turned out to be the same file, makes the audio held under the old file ID answer to the new one too.
    public func alias(winner: LibraryFileID, loser: LibraryFileID) throws {
        guard let held = try entry(for: loser), held.state == .present else { return }
        if let existing = try entry(for: winner), existing.state == .present { return }
        try register([LocalFileInfo(audioFileID: winner, bookmark: held.bookmark, path: held.path, byteSize: held.byteSize,
                                    modificationDate: held.modificationDate)])
    }

    public func setState(_ state: LocalFileState, for fileID: LibraryFileID) throws {
        var descriptor = FetchDescriptor<LocalFileRecord>(predicate: #Predicate { $0.audioFileID == fileID })
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else { return }
        record.state = state.rawValue
        record.verifiedAt = .now
        try modelContext.save()
    }

    public func updateBookmark(_ bookmark: Data, for fileID: LibraryFileID) throws {
        var descriptor = FetchDescriptor<LocalFileRecord>(predicate: #Predicate { $0.audioFileID == fileID })
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else { return }
        record.bookmark = bookmark
        try modelContext.save()
    }

    private static func info(_ r: LocalFileRecord) -> LocalFileInfo {
        LocalFileInfo(audioFileID: r.audioFileID, bookmark: r.bookmark, path: r.path, byteSize: r.byteSize,
                      modificationDate: r.modificationDate, state: LocalFileState(rawValue: r.state) ?? .present,
                      acquiredAt: r.acquiredAt ?? r.verifiedAt)
    }
}
