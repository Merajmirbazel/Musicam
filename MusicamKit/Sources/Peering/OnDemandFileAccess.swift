import Foundation
import Domain
import Persistence

/// Opens a library file from this device, and if this device does not have it yet, fetches it from a paired
/// device first. This is what makes "play a song that lives on my other device" just work.
public struct OnDemandFileAccess: FileAccessing {
    private let local: FileAccessService
    private let fetch: @Sendable (LibraryFileID) async throws -> Void

    public init(local: FileAccessService, fetch: @escaping @Sendable (LibraryFileID) async throws -> Void) {
        self.local = local
        self.fetch = fetch
    }

    public func open(_ fileID: LibraryFileID) async throws -> AccessedFile {
        do {
            return try await local.open(fileID)
        } catch let error as FileAccessError where error == .notRegistered(fileID) || error == .missing(fileID) {
            try await fetch(fileID)
            return try await local.open(fileID)
        }
    }
}
