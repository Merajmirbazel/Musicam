import Foundation
import Synchronization

/// A file the app may read right now. For sandboxed access it holds the security scope open
/// until released (explicitly, or when the last reference goes away).
public final class AccessedFile: Sendable {
    public let url: URL
    private let onRelease: Mutex<(@Sendable () -> Void)?>

    public init(url: URL, onRelease: (@Sendable () -> Void)? = nil) {
        self.url = url
        self.onRelease = Mutex(onRelease)
    }

    public func release() {
        let action = onRelease.withLock { current -> (@Sendable () -> Void)? in
            let a = current
            current = nil
            return a
        }
        action?()
    }

    deinit { release() }
}

public enum FileAccessError: Error, Sendable, Equatable {
    case notRegistered(LibraryFileID)
    case missing(LibraryFileID)
    case accessDenied(LibraryFileID)
}

/// Turns a library file into a readable URL on this device. Implemented by the persistence layer.
public protocol FileAccessing: Sendable {
    func open(_ fileID: LibraryFileID) async throws -> AccessedFile
}
