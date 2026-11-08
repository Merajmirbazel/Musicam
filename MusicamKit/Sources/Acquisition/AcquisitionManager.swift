import Foundation
import Observation
import Importing

/// Takes finished, checked files and gives them to the importer. In the app this calls the same import path as the file
/// picker; `ImportHandoff.importService(_:)` below is the plain version that talks to `ImportService.run(_:source:)` directly.
public typealias AcquisitionHandoff = @Sendable ([AcquiredFile]) async throws -> Void

public enum ImportHandoff {
    /// Sends the files through `ImportService.run(_:source:)`, one source at a time, and waits until the import is done.
    /// Throws when none of the files could be added to the library.
    public static func importService(_ service: ImportService) -> AcquisitionHandoff {
        { files in
            for (source, urls) in AcquiredFile.grouped(files) {
                var summary: ImportSummary?
                for await event in service.run(urls, source: source) {
                    if case .finished(let done) = event { summary = done }
                }
                try Task.checkCancellation()
                if let summary, summary.total > 0, summary.imported + summary.duplicates + summary.unchanged == 0 {
                    throw AcquisitionError.noUsableFiles(String(localized: "The song could not be added to the library."))
                }
            }
        }
    }
}

/// The one place requests are accepted, queued, run, reported on, cancelled and handed to the importer.
///
/// A request goes: queued → acquiring (the provider works) → importing (files are checked, then handed to the importer)
/// → finished. It can end as failed or cancelled instead. Only `maxConcurrent` requests run at the same time.
@MainActor
@Observable
public final class AcquisitionManager {
    public enum State: Equatable, Sendable {
        case queued, acquiring, importing
        case finished(files: Int)
        case failed(AcquisitionError)
        case cancelled

        public var isFinal: Bool {
            switch self {
            case .finished, .failed, .cancelled: true
            default: false
            }
        }
    }

    public struct Job: Identifiable, Equatable, Sendable {
        public var id: UUID { request.id }
        public let request: AcquisitionRequest
        public internal(set) var state: State
        public internal(set) var progress: AcquisitionProgress
        public internal(set) var providerName: String?
    }

    /// Every request since the last `clearFinished()`, oldest first.
    public private(set) var jobs: [Job] = []

    @ObservationIgnored private let registry: ProviderRegistry
    @ObservationIgnored private let handoff: AcquisitionHandoff
    @ObservationIgnored private let maxConcurrent: Int
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Which run of a request is the current one. A cancelled run that finishes late finds a newer number and is ignored.
    @ObservationIgnored private var generations: [UUID: Int] = [:]
    @ObservationIgnored private var waiters: [UUID: [CheckedContinuation<Job, Never>]] = [:]

    public init(registry: ProviderRegistry, handoff: @escaping AcquisitionHandoff, maxConcurrent: Int = 2) {
        self.registry = registry
        self.handoff = handoff
        self.maxConcurrent = max(1, maxConcurrent)
    }

    public func job(_ id: UUID) -> Job? { jobs.first { $0.id == id } }

    /// Whether some provider can serve this request right now.
    public func canHandle(_ request: AcquisitionRequest) -> Bool { registry.resolve(request) != nil }

    /// The id of the provider that would serve this request, or nil.
    public func providerID(for request: AcquisitionRequest) -> String? { registry.resolve(request)?.id }

    /// How many requests are queued or running.
    public var activeCount: Int { jobs.filter { !$0.state.isFinal }.count }

    // MARK: Accepting requests

    /// Accepts a request. A request nobody can serve fails at once instead of waiting in the queue.
    @discardableResult
    public func submit(_ request: AcquisitionRequest) -> UUID {
        if let existing = job(request.id), !existing.state.isFinal { return request.id }
        jobs.removeAll { $0.id == request.id }
        var job = Job(request: request, state: .queued, progress: .waiting, providerName: nil)
        if request.isEmpty {
            job.state = .failed(.invalidRequest(String(localized: "There is nothing to get.")))
        } else if let provider = registry.resolve(request) {
            job.providerName = provider.displayName
        } else {
            job.state = .failed(.noProvider)
        }
        jobs.append(job)
        startNext()
        return request.id
    }

    /// Accepts a request and waits until it is finished, failed or cancelled.
    public func perform(_ request: AcquisitionRequest) async -> Job {
        let id = submit(request)
        return await result(of: id) ?? Job(request: request, state: .cancelled, progress: .waiting, providerName: nil)
    }

    /// Waits until the request is over. Nil when there is no such request.
    public func result(of id: UUID) async -> Job? {
        guard let current = job(id) else { return nil }
        if current.state.isFinal { return current }
        return await withCheckedContinuation { waiters[id, default: []].append($0) }
    }

    // MARK: Control

    /// Stops a queued or running request. Files already downloaded for it are removed.
    public func cancel(_ id: UUID) {
        guard let current = job(id), !current.state.isFinal else { return }
        tasks[id]?.cancel()
        tasks[id] = nil
        generations[id, default: 0] += 1          // the cancelled run's late answer no longer counts
        setFinal(id, .cancelled)
        startNext()
    }

    public func cancelAll() { for job in jobs where !job.state.isFinal { cancel(job.id) } }

    /// Runs a failed (where trying again can help) or cancelled request again.
    public func retry(_ id: UUID) {
        guard let current = job(id), tasks[id] == nil else { return }
        switch current.state {
        case .cancelled: break
        case .failed(let error) where error.isRetryable: break
        default: return
        }
        update(id) { $0.state = .queued; $0.progress = .waiting }
        startNext()
    }

    /// Removes finished, failed and cancelled requests from the list.
    public func clearFinished() { jobs.removeAll { $0.state.isFinal && tasks[$0.id] == nil } }

    // MARK: Running

    private func startNext() {
        while tasks.count < maxConcurrent, let next = jobs.first(where: { $0.state == .queued && tasks[$0.id] == nil }) {
            guard let provider = registry.resolve(next.request) else { setFinal(next.id, .failed(.noProvider)); continue }
            let id = next.id, request = next.request
            update(id) { $0.state = .acquiring; $0.providerName = provider.displayName }
            let generation = generations[id, default: 0] + 1
            generations[id] = generation
            tasks[id] = Task { [weak self] in await self?.run(id, request, provider, generation) }
        }
    }

    private func run(_ id: UUID, _ request: AcquisitionRequest, _ provider: any MediaProvider, _ generation: Int) async {
        var held: [AcquiredFile] = []
        var handedOff = false
        let outcome: State
        do {
            held = try await provider.acquire(request) { [weak self] progress in
                Task { @MainActor in self?.setProgress(id, progress) }
            }
            try Task.checkCancellation()
            // Nothing reaches the importer before it has been checked.
            var usable: [AcquiredFile] = []
            var firstProblem: String?
            for file in held {
                if let problem = file.problem { firstProblem = firstProblem ?? problem; file.discard() } else { usable.append(file) }
            }
            held = usable
            guard !usable.isEmpty else { throw AcquisitionError.noUsableFiles(firstProblem ?? String(localized: "Nothing was downloaded.")) }
            update(id) { $0.state = .importing; $0.progress = AcquisitionProgress(fraction: 1) }
            handedOff = true
            try await handoff(usable)
            outcome = .finished(files: usable.count)
        } catch is CancellationError {
            if !handedOff { held.forEach { $0.discard() } }
            outcome = .cancelled
        } catch let error as AcquisitionError {
            // After the hand-off some files may already be in the library, so they stay; the launch sweep removes unused leftovers.
            if !handedOff { held.forEach { $0.discard() } }
            outcome = error == .cancelled ? .cancelled : .failed(error)
        } catch {
            if !handedOff { held.forEach { $0.discard() } }
            outcome = Task.isCancelled ? .cancelled
                : .failed(.failed(provider: provider.id, reason: error.localizedDescription, retryable: true))
        }
        guard generations[id] == generation else { return }        // cancelled (and maybe restarted) meanwhile
        tasks[id] = nil
        setFinal(id, outcome)
        startNext()
    }

    // MARK: Bookkeeping

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    private func setProgress(_ id: UUID, _ progress: AcquisitionProgress) {
        guard let current = job(id), !current.state.isFinal else { return }
        update(id) { $0.progress = progress }
    }

    /// Ends a request once; a later attempt to end it again (for example a provider that ignores cancellation) is ignored.
    private func setFinal(_ id: UUID, _ state: State) {
        guard let current = job(id), !current.state.isFinal else { return }
        update(id) { $0.state = state; if case .finished = state { $0.progress = AcquisitionProgress(fraction: 1) } }
        guard let done = job(id) else { return }
        for waiter in waiters.removeValue(forKey: id) ?? [] { waiter.resume(returning: done) }
    }
}
