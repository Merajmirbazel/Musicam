#if os(macOS)
import Foundation
import CoreServices

/// Tells you when something inside a folder (at any depth) was added, changed or removed.
/// Events are grouped: a burst of changes produces one callback shortly after the burst ends.
public final class FolderWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "musicam.folderwatcher")
    private let debounce: TimeInterval
    private let handler: @Sendable () -> Void
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private let folder: URL

    public init(folder: URL, debounce: TimeInterval = 1.5, onChange: @escaping @Sendable () -> Void) {
        self.folder = folder
        self.debounce = debounce
        self.handler = onChange
    }

    /// Starts watching. Returns false if the folder cannot be watched.
    @discardableResult
    public func start() -> Bool {
        guard stream == nil else { return true }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().eventsArrived()
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(nil, callback, &context, [folder.path] as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return false }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created); FSEventStreamRelease(created)
            return false
        }
        stream = created
        return true
    }

    public func stop() {
        pending?.cancel()
        pending = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }

    private func eventsArrived() {
        pending?.cancel()
        let work = DispatchWorkItem { [handler] in handler() }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
#endif
