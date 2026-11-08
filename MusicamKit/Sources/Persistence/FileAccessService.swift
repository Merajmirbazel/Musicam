import Foundation
import Domain

/// Opens library files through their saved security-scoped bookmarks, so access survives relaunch in the sandbox.
public struct FileAccessService: FileAccessing {
    private let device: DeviceStore

    public init(device: DeviceStore) {
        self.device = device
    }

    public func open(_ fileID: LibraryFileID) async throws -> AccessedFile {
        guard let entry = try await device.entry(for: fileID) else { throw FileAccessError.notRegistered(fileID) }

        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: entry.bookmark, options: FileBookmarks.resolution, relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            try? await device.setState(.missing, for: fileID)
            throw FileAccessError.missing(fileID)
        }

        let scoped = url.startAccessingSecurityScopedResource()
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            try? await device.setState(.missing, for: fileID)
            throw FileAccessError.missing(fileID)
        }
        if stale, let fresh = try? url.bookmarkData(options: FileBookmarks.creation) {
            try? await device.updateBookmark(fresh, for: fileID)
        }
        if entry.state == .missing { try? await device.setState(.present, for: fileID) }
        guard scoped else { return AccessedFile(url: url) }
        let scopedURL = url
        return AccessedFile(url: scopedURL, onRelease: { @Sendable in scopedURL.stopAccessingSecurityScopedResource() })
    }
}
