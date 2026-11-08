import Foundation
import Observation
import Synchronization
import Acquisition
#if os(macOS)
import AppKit

/// The helper's last words, kept so a failed start can say why.
final class ErrorBuffer: Sendable { let text = Mutex<String>("") }

/// Runs the Merajfy helper that ships inside Musicam.app (`Contents/Resources/Helpers`: merajfy-cli, yt-dlp_macos with its _internal folder, ffmpeg), so the Mac app
/// can fetch Spotify songs without a separate Merajfy program. The helpers are signed to inherit Musicam's sandbox:
/// they get no more rights than Musicam has. The helper serves the same local API the external Merajfy does,
/// so `MerajfyProvider` talks to it exactly as before.
@MainActor
@Observable
public final class EmbeddedMerajfy {
    public enum State: Equatable {
        case unavailable(String)    // this build has no helpers
        case stopped
        case starting
        case running
        case failed(String)
    }

    /// Not 8787, so it never collides with a Merajfy app the person also runs.
    public static let port: UInt16 = 18787

    public private(set) var state: State

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var generation = 0
    /// The start that is in progress, so two callers never start two helpers.
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private let errors = ErrorBuffer()
    @ObservationIgnored private var observer: NSObjectProtocol?

    public init() {
        state = Self.helpersDirectory == nil
            ? .unavailable(String(localized: "This build of Musicam has no built-in downloader."))
            : .stopped
        observer = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    /// `Musicam.app/Contents/Resources/Helpers`, when the three programs are really there.
    public static var helpersDirectory: URL? {
        let dir = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Helpers", isDirectory: true)
        func has(_ name: String) -> Bool { FileManager.default.isExecutableFile(atPath: dir.appendingPathComponent(name).path) }
        // yt-dlp ships as the folder build (yt-dlp_macos + _internal); the one-file build cannot run in a sandbox
        return has("merajfy-cli") && has("ffmpeg") && (has("yt-dlp_macos") || has("yt-dlp")) ? dir : nil
    }

    public var isAvailable: Bool { Self.helpersDirectory != nil }

    public static func localURL() -> URL { URL(string: "http://127.0.0.1:\(port)")! }

    /// Starts the helper (or reuses one that is already answering) and waits until it responds.
    public func start(allowLAN: Bool, token: String) async {
        startTask?.cancel()
        let task = Task { await performStart(allowLAN: allowLAN, token: token) }
        startTask = task
        await task.value
    }

    private func performStart(allowLAN: Bool, token: String) async {
        guard let helpers = Self.helpersDirectory else {
            state = .unavailable(String(localized: "This build of Musicam has no built-in downloader."))
            return
        }
        teardown()
        generation += 1
        let mine = generation
        state = .starting
        let client = MerajfyClient(config: MerajfyConfig(baseURL: Self.localURL(), token: allowLAN ? token : nil))

        // A helper left over from an earlier run that still answers with this very token is simply reused.
        if (try? await client.health()) != nil, process == nil {
            if (try? await client.jobsAreReadable()) == true { state = .running; return }
        }

        let outputFolder = FileManager.default.temporaryDirectory.appendingPathComponent("merajfy-out", isDirectory: true)
        try? FileManager.default.removeItem(at: outputFolder)
        try? FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = helpers.appendingPathComponent("merajfy-cli")
        var args = ["serve", "--out", outputFolder.path, "--port", String(Self.port)]
        if allowLAN { args += ["--lan", "--token", token] }
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["MERAJFY_BIN"] = helpers.path
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        p.standardError = errPipe
        errors.text.withLock { $0 = "" }
        errPipe.fileHandleForReading.readabilityHandler = { [errors] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            errors.text.withLock { $0 = String(($0 + String(decoding: data, as: UTF8.self)).suffix(2000)) }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor in self?.helperEnded(generation: mine, status: status) }
        }
        do { try p.run() } catch {
            state = .failed(String(localized: "The built-in downloader could not start: \(error.localizedDescription)"))
            return
        }
        process = p

        for _ in 0..<60 {                                       // up to about 12 seconds
            guard generation == mine, case .starting = state else { return }
            if (try? await client.health()) != nil { state = .running; return }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard generation == mine else { return }
        state = .failed(lastError() ?? String(localized: "The built-in downloader did not answer."))
    }

    /// Makes sure the helper is running (starts it when it is not). Used right before a download.
    public func ensureRunning(allowLAN: Bool, token: String) async {
        if case .running = state, process?.isRunning ?? true { return }
        if case .starting = state, let task = startTask { await task.value; return }
        await start(allowLAN: allowLAN, token: token)
    }

    public func stop() {
        startTask?.cancel()
        startTask = nil
        teardown()
    }

    private func teardown() {
        generation += 1
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        if case .unavailable = state {} else { state = .stopped }
    }

    private func helperEnded(generation ended: Int, status: Int32) {
        guard ended == generation else { return }               // we stopped it on purpose
        process = nil
        state = .failed(lastError() ?? String(localized: "The built-in downloader stopped (code \(Int(status)))."))
    }

    private func lastError() -> String? {
        let text = errors.text.withLock { $0 }.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.split(separator: "\n").last ?? "")
    }
}
#endif
