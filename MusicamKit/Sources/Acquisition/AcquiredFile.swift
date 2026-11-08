import Foundation
import Importing

/// A finished download: a file on this device, ready to go to the importer.
public struct AcquiredFile: Sendable, Hashable {
    public let url: URL
    /// Where the file came from, in `TrackSource` form ("link:archive.org", ...). The importer stores it with the song.
    public let source: String
    /// The provider that made the file.
    public let providerID: String
    /// True when the file's folder was made for this file alone, so the folder can be removed together with it.
    public let ownsFolder: Bool

    public init(url: URL, source: String, providerID: String, ownsFolder: Bool = false) {
        self.url = url
        self.source = source
        self.providerID = providerID
        self.ownsFolder = ownsFolder
    }

    /// Why the file cannot be imported, or nil when it looks fine. Checked before anything reaches the importer.
    public var problem: String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return String(localized: "The downloaded file is missing.")
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { return String(localized: "The downloaded file is empty.") }
        guard AudioFileScanner.isAudio(url) else { return String(localized: "The downloaded file is not an audio file.") }
        return nil
    }

    /// Deletes the file (and its own folder) when the download is not going to be used.
    public func discard() {
        try? FileManager.default.removeItem(at: url)
        guard ownsFolder else { return }
        let folder = url.deletingLastPathComponent()
        if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// The files split by source, in the order the sources first appear. The importer records one source per run.
    public static func grouped(_ files: [AcquiredFile]) -> [(source: String, urls: [URL])] {
        var order: [String] = []
        var groups: [String: [URL]] = [:]
        for file in files {
            if groups[file.source] == nil { order.append(file.source) }
            groups[file.source, default: []].append(file.url)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }
}
