import Foundation
import Acquisition
import MerajCore

/// Python 3.14 and yt-dlp, running inside this app (see Vendor/Python). The interpreter is owned by ONE thread, because Python
/// wants all its calls from the thread that started it; callers just `await` the answer.
final class PythonWorker: @unchecked Sendable {
    static let shared = PythonWorker()

    private final class Job: @unchecked Sendable {
        let run: () -> Void
        let cancelled = NSLock()
        var isCancelled = false
        init(_ run: @escaping () -> Void) { self.run = run }
        func cancel() { cancelled.lock(); isCancelled = true; cancelled.unlock() }
        var wasCancelled: Bool { cancelled.lock(); defer { cancelled.unlock() }; return isCancelled }
    }

    private let condition = NSCondition()
    private var queue: [Job] = []
    private var started = false

    private init() {
        let thread = Thread { [self] in
            while true {
                condition.lock()
                while queue.isEmpty { condition.wait() }
                let job = queue.removeFirst()
                condition.unlock()
                job.run()
            }
        }
        thread.name = "Python"
        thread.stackSize = 8 << 20          // Python recurses deeply in yt-dlp's extractors
        thread.start()
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Calls `merajfy_ios.<function>(*arguments)` and returns its JSON text.
    func call(_ function: String, _ arguments: [String]) async throws -> String {
        let job = Box<Job?>(nil)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let item = Job { [self] in
                    do { continuation.resume(returning: try callOnThread(function, arguments)) }
                    catch { continuation.resume(throwing: error) }
                }
                job.value = item
                condition.lock(); queue.append(item); condition.signal(); condition.unlock()
            }
        } onCancel: {
            job.value?.cancel()
        }
    }

    // MARK: on the Python thread

    private func callOnThread(_ function: String, _ arguments: [String]) throws -> String {
        try startIfNeeded()
        guard let module = PyImport_ImportModule("merajfy_ios") else { PyErr_Print(); throw Failure(message: "Could not load the downloader code.") }
        defer { Py_DecRef(module) }
        guard let callable = PyObject_GetAttrString(module, function) else { throw Failure(message: "The downloader has no \(function).") }
        defer { Py_DecRef(callable) }
        guard let tuple = PyTuple_New(arguments.count) else { throw Failure(message: "Out of memory.") }
        defer { Py_DecRef(tuple) }
        for (i, a) in arguments.enumerated() {
            guard let item = PyUnicode_FromString(a) else { throw Failure(message: "Bad argument.") }
            PyTuple_SetItem(tuple, i, item)          // steals the reference
        }
        guard let result = PyObject_CallObject(callable, tuple) else { PyErr_Print(); throw Failure(message: "The downloader stopped unexpectedly.") }
        defer { Py_DecRef(result) }
        guard let text = PyUnicode_AsUTF8(result) else { throw Failure(message: "The downloader sent an unreadable answer.") }
        return String(cString: text)
    }

    private func startIfNeeded() throws {
        if started { return }
        guard let resources = Bundle.main.resourcePath else { throw Failure(message: "No resources.") }
        setenv("NO_COLOR", "1", 1)
        setenv("PYTHON_COLORS", "0", 1)
        var preconfig = PyPreConfig()
        var config = PyConfig()
        PyPreConfig_InitIsolatedConfig(&preconfig)
        PyConfig_InitIsolatedConfig(&config)
        preconfig.utf8_mode = 1
        config.use_system_logger = 1
        config.buffered_stdio = 0
        config.write_bytecode = 0
        config.install_signal_handlers = 0

        var status = Py_PreInitialize(&preconfig)
        if PyStatus_Exception(status) != 0 { throw Failure(message: "Python could not start: \(String(cString: status.err_msg))") }
        let home = Py_DecodeLocale("\(resources)/python", nil)
        status = withUnsafeMutablePointer(to: &config) { PyConfig_SetString($0, &$0.pointee.home, home) }
        PyMem_RawFree(home)
        if PyStatus_Exception(status) != 0 { throw Failure(message: "Python could not start: \(String(cString: status.err_msg))") }
        status = PyConfig_Read(&config)
        if PyStatus_Exception(status) != 0 { throw Failure(message: "Python could not start: \(String(cString: status.err_msg))") }
        status = Py_InitializeFromConfig(&config)
        PyConfig_Clear(&config)
        if PyStatus_Exception(status) != 0 { throw Failure(message: "Python could not start: \(String(cString: status.err_msg))") }
        let setup = "import sys\nsys.path.insert(0, r\"\(resources)/app_packages\")\nsys.path.insert(0, r\"\(resources)/app\")\n"
        if PyRun_SimpleString(setup) != 0 { throw Failure(message: "Python could not find its files.") }
        started = true
    }
}

/// A tiny reference holder, so the cancellation handler can reach the job that was queued later.
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// What Musicam's on-device provider uses: search and download through Python/yt-dlp.
struct OnDeviceYouTubeEngine: YouTubeAudioEngine {
    func search(_ query: String) async throws -> [YTCandidate] {
        let text = try await PythonWorker.shared.call("search", [query])
        let json = try JSONSerialization.jsonObject(with: Data(text.utf8))
        if let object = json as? [String: Any], let message = object["error"] as? String { throw PythonWorker.Failure(message: message) }
        guard let list = json as? [[String: Any]] else { return [] }
        return list.compactMap { e in
            guard let id = e["id"] as? String else { return nil }
            return YTCandidate(id: id, title: e["title"] as? String, duration: (e["duration"] as? NSNumber)?.doubleValue)
        }
    }

    func downloadAudio(videoID: String, into directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let cancelFile = directory.appendingPathComponent(".cancel").path
        let progressFile = directory.appendingPathComponent(".progress").path
        try? FileManager.default.removeItem(atPath: cancelFile)
        // Python writes how far it is into a small file; read it twice a second
        let reader = Task.detached {
            while !Task.isCancelled {
                if let data = FileManager.default.contents(atPath: progressFile),
                   let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let done = (o["done"] as? NSNumber)?.doubleValue, let total = (o["total"] as? NSNumber)?.doubleValue, total > 0 {
                    progress(min(done / total, 1))
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        defer { reader.cancel(); try? FileManager.default.removeItem(atPath: progressFile); try? FileManager.default.removeItem(atPath: cancelFile) }

        let text = try await withTaskCancellationHandler {
            try await PythonWorker.shared.call("download", [videoID, directory.path, cancelFile, progressFile])
        } onCancel: {
            // Python checks this file between chunks and stops
            FileManager.default.createFile(atPath: cancelFile, contents: Data())
        }
        try Task.checkCancellation()
        guard let o = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw PythonWorker.Failure(message: "The downloader sent an unreadable answer.")
        }
        if o["cancelled"] as? Bool == true { throw CancellationError() }
        if let message = o["error"] as? String { throw PythonWorker.Failure(message: message) }
        guard let path = o["file"] as? String else { throw PythonWorker.Failure(message: "The downloader returned no file.") }
        return URL(fileURLWithPath: path)
    }
}
