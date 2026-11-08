import Foundation
import Domain
import Persistence

public struct ImportSummary: Sendable, Equatable {
    public var imported = 0
    public var duplicates = 0
    public var unchanged = 0
    public var unsupported = 0
    public var failed = 0
    public var elapsed: TimeInterval = 0
    public var total: Int { imported + duplicates + unchanged + unsupported + failed }

    public init() {}
}

public enum ImportEvent: Sendable {
    case discovered(total: Int)
    case progress(done: Int, total: Int, name: String)
    case finished(ImportSummary)
}

/// Imports files and folders. Each file goes through: skip if unchanged, hash, read tags, save artwork,
/// remember a bookmark, then commit in batches. Re-running on the same files is always safe.
public final class ImportService: Sendable {
    private struct Prepared: Sendable {
        var item: ImportedItem
        var path: String
        var bookmark: Data
        var modificationDate: Date?
    }

    private enum Outcome: Sendable {
        case ready(Prepared)
        case unchanged
        case unsupported
        case failed(String)
    }

    private let library: LibraryStore
    private let device: DeviceStore
    private let tags: any TagReading
    private let artwork: ArtworkStore
    private let concurrency: Int
    private let batchSize: Int

    public init(library: LibraryStore, device: DeviceStore, tags: any TagReading = AVFoundationTagReader(),
                artwork: ArtworkStore, concurrency: Int = 4, batchSize: Int = 50) {
        self.library = library
        self.device = device
        self.tags = tags
        self.artwork = artwork
        self.concurrency = max(1, concurrency)
        self.batchSize = max(1, batchSize)
    }

    /// Starts an import and reports progress. Cancelling the consumer's task stops the work.
    /// `source` is what to record as the origin of the files (see `TrackSource`); nil means picked by hand, which is
    /// recorded as "file", or "folder" for songs found inside a picked folder.
    public func run(_ urls: [URL], source: String? = nil) -> AsyncStream<ImportEvent> {
        AsyncStream { continuation in
            let task = Task {
                let summary = await self.execute(urls, source: source) { continuation.yield($0) }
                continuation.yield(.finished(summary))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func execute(_ urls: [URL], source: String?, emit: @Sendable (ImportEvent) -> Void) async -> ImportSummary {
        let started = Date()
        var summary = ImportSummary()

        // Picked files and folders are only readable while their security scope is open.
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }

        let files = AudioFileScanner.audioFiles(in: urls)
        emit(.discovered(total: files.count))
        guard !files.isEmpty else { summary.elapsed = Date().timeIntervalSince(started); return summary }

        // A song that was removed from the library must not count as "unchanged": adding its file again brings it back.
        let removed = (try? await library.deletedFileIDs()) ?? []
        let known = ((try? await device.knownFilesByPath()) ?? [:]).filter { !removed.contains($0.value.audioFileID) }
        let folderRoots = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.map { $0.standardizedFileURL.path + "/" }
        func origin(of file: URL) -> String {
            if let source { return source }
            return folderRoots.contains { file.standardizedFileURL.path.hasPrefix($0) } ? TrackSource.folder.raw : TrackSource.file.raw
        }
        var pending: [Prepared] = []
        var done = 0

        func flush() async {
            guard !pending.isEmpty else { return }
            let batch = pending
            pending = []
            do {
                let results = try await library.add(batch.map(\.item))
                var registrations: [LocalFileInfo] = []
                for (prepared, result) in zip(batch, results) {
                    let info = LocalFileInfo(audioFileID: result.fileID, bookmark: prepared.bookmark, path: prepared.path,
                                             byteSize: prepared.item.byteSize, modificationDate: prepared.modificationDate)
                    if result.wasDuplicate {
                        summary.duplicates += 1
                        let existing = try await device.entry(for: result.fileID)
                        if existing == nil || existing?.state == .missing { registrations.append(info) }
                    } else {
                        summary.imported += 1
                        registrations.append(info)
                    }
                }
                try await device.register(registrations)
            } catch {
                summary.failed += batch.count
            }
        }

        await withTaskGroup(of: (URL, Outcome).self) { group in
            var iterator = files.makeIterator()
            func addNext() {
                guard !Task.isCancelled, let file = iterator.next() else { return }
                let origin = origin(of: file)
                group.addTask { (file, await self.prepare(file, known: known, source: origin)) }
            }
            for _ in 0..<concurrency { addNext() }

            while let (file, outcome) = await group.next() {
                addNext()
                switch outcome {
                case .ready(let prepared): pending.append(prepared)
                case .unchanged: summary.unchanged += 1
                case .unsupported: summary.unsupported += 1
                case .failed: summary.failed += 1
                }
                done += 1
                emit(.progress(done: done, total: files.count, name: file.lastPathComponent))
                if pending.count >= batchSize { await flush() }
            }
        }
        await flush()
        summary.elapsed = Date().timeIntervalSince(started)
        return summary
    }

    @concurrent
    private func prepare(_ file: URL, known: [String: LocalFileInfo], source: String) async -> Outcome {
        if AudioFileScanner.isUnsupported(file) { return .unsupported }
        do {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(values.fileSize ?? 0)
            let modified = values.contentModificationDate
            if let entry = known[file.path], entry.state == .present, entry.byteSize == size,
               let a = entry.modificationDate, let b = modified, abs(a.timeIntervalSince(b)) < 1 {
                return .unchanged
            }
            let hash = try ContentHasher.sha256(of: file)
            let raw = try await tags.read(file)
            var metadata = raw.metadata
            if let art = raw.artworkData { metadata.artworkKey = artwork.save(art) }
            let bookmark = try file.bookmarkData(options: FileBookmarks.creation)
            let item = ImportedItem(metadata: metadata, contentHash: hash, byteSize: size, originalFilename: file.lastPathComponent, source: source)
            return .ready(Prepared(item: item, path: file.path, bookmark: bookmark, modificationDate: modified))
        } catch {
            return .failed(String(describing: error))
        }
    }
}
