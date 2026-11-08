import Testing
import Foundation
import Synchronization
@testable import Acquisition

@MainActor
@Suite struct ManagerTests {
    private func manager(_ providers: [FakeProvider], recorder: HandoffRecorder = HandoffRecorder(), max: Int = 2) throws -> AcquisitionManager {
        AcquisitionManager(registry: try ProviderRegistry(providers), handoff: recorder.handoff, maxConcurrent: max)
    }

    private let link = AcquisitionRequest.link(URL(string: "https://example.org/a.mp3")!)

    @Test func goodFilesAreHandedOverAndBadOnesAreDroppedAndDeleted() async throws {
        let root = makeScratchFolder(); defer { try? FileManager.default.removeItem(at: root) }
        let good = makeAcquiredFile(in: root)
        let empty = makeAcquiredFile(in: root, name: "empty.mp3", bytes: Data())
        let notAudio = makeAcquiredFile(in: root, name: "page.html")
        let recorder = HandoffRecorder()
        let seen = Mutex<[Double]>([])
        let provider = FakeProvider(id: "p") { _, progress in
            progress(AcquisitionProgress(fraction: 0.5, message: "half"))
            return [good, empty, notAudio]
        }
        let m = try manager([provider], recorder: recorder)
        let job = await m.perform(link)
        _ = seen
        #expect(job.state == .finished(files: 1))
        #expect(recorder.files == [good])
        #expect(!FileManager.default.fileExists(atPath: empty.url.path))
        #expect(!FileManager.default.fileExists(atPath: notAudio.url.path))
        #expect(FileManager.default.fileExists(atPath: good.url.path))
        #expect(job.progress.fraction == 1)
        #expect(job.providerName == "p")
    }

    @Test func nothingUsableIsAFailureAndNothingIsHandedOver() async throws {
        let root = makeScratchFolder(); defer { try? FileManager.default.removeItem(at: root) }
        let recorder = HandoffRecorder()
        let m = try manager([FakeProvider(id: "p") { _, _ in [makeAcquiredFile(in: root, name: "x.txt")] }], recorder: recorder)
        let job = await m.perform(link)
        guard case .failed(.noUsableFiles) = job.state else { Issue.record("expected noUsableFiles, got \(job.state)"); return }
        #expect(recorder.all.isEmpty)
    }

    @Test func requestsNobodyCanServeFailAtOnce() throws {
        let m = try manager([FakeProvider(id: "p", accepts: { _ in false })])
        let id = m.submit(link)
        #expect(m.job(id)?.state == .failed(.noProvider))
        let empty = m.submit(AcquisitionRequest())
        guard case .failed(.invalidRequest) = m.job(empty)?.state else { Issue.record("expected invalidRequest"); return }
        #expect(m.activeCount == 0)
    }

    @Test func aProviderErrorBecomesAFailureAndRetryCanSucceed() async throws {
        let root = makeScratchFolder(); defer { try? FileManager.default.removeItem(at: root) }
        let attempts = Mutex(0)
        let provider = FakeProvider(id: "p") { _, _ in
            let n = attempts.withLock { $0 += 1; return $0 }
            if n == 1 { throw AcquisitionError.failed(provider: "p", reason: "offline", retryable: true) }
            return [makeAcquiredFile(in: root)]
        }
        let m = try manager([provider])
        let first = await m.perform(link)
        #expect(first.state == .failed(.failed(provider: "p", reason: "offline", retryable: true)))
        m.retry(first.id)
        let second = await m.result(of: first.id)
        #expect(second?.state == .finished(files: 1))
        #expect(attempts.withLock { $0 } == 2)
    }

    @Test func aFailureThatCannotHelpIsNotRetried() async throws {
        let provider = FakeProvider(id: "p") { _, _ in throw AcquisitionError.failed(provider: "p", reason: "not audio", retryable: false) }
        let m = try manager([provider])
        let job = await m.perform(link)
        m.retry(job.id)
        #expect(m.job(job.id)?.state == job.state)
    }

    @Test func anUnexpectedErrorIsWrappedWithTheProviderName() async throws {
        struct Odd: Error, LocalizedError { var errorDescription: String? { "odd" } }
        let m = try manager([FakeProvider(id: "p") { _, _ in throw Odd() }])
        let job = await m.perform(link)
        #expect(job.state == .failed(.failed(provider: "p", reason: "odd", retryable: true)))
    }

    @Test func cancellingARunningRequestStopsItAndRemovesItsFiles() async throws {
        let root = makeScratchFolder(); defer { try? FileManager.default.removeItem(at: root) }
        let made = Mutex<AcquiredFile?>(nil)
        // this provider ignores cancellation and still returns a file: the manager must not use it
        let stubborn = FakeProvider(id: "p") { _, _ in
            try? await Task.sleep(for: .milliseconds(300))
            let file = makeAcquiredFile(in: root)
            made.withLock { $0 = file }
            return [file]
        }
        let recorder = HandoffRecorder()
        let m = try manager([stubborn], recorder: recorder)
        let id = m.submit(link)
        await waitUntil { m.job(id)?.state == .acquiring }
        m.cancel(id)
        #expect(m.job(id)?.state == .cancelled)
        await waitUntil(timeout: 3) { made.withLock { $0 } != nil }
        try await Task.sleep(for: .milliseconds(200))
        #expect(recorder.all.isEmpty)
        let file = try #require(made.withLock { $0 })
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
        #expect(m.job(id)?.state == .cancelled)                      // a late result cannot change it back
    }

    @Test func aCancellableProviderEndsPromptly() async throws {
        let m = try manager([FakeProvider(id: "p") { _, _ in try await Task.sleep(for: .seconds(30)); return [] }])
        let id = m.submit(link)
        await waitUntil { m.job(id)?.state == .acquiring }
        m.cancel(id)
        let job = await m.result(of: id)
        #expect(job?.state == .cancelled)
        m.retry(id)                                                   // cancelled requests can be started again
        #expect(m.job(id)?.state == .acquiring || m.job(id)?.state == .queued)
        m.cancelAll()
    }

    @Test func onlyMaxConcurrentRequestsRunAtOnceAndQueuedOnesCanBeCancelled() async throws {
        let root = makeScratchFolder(); defer { try? FileManager.default.removeItem(at: root) }
        let running = Mutex(0), peak = Mutex(0)
        let provider = FakeProvider(id: "p") { _, _ in
            let now = running.withLock { $0 += 1; return $0 }
            peak.withLock { $0 = max($0, now) }
            try await Task.sleep(for: .milliseconds(150))
            running.withLock { $0 -= 1 }
            return [makeAcquiredFile(in: root)]
        }
        let m = try manager([provider], max: 1)
        let a = m.submit(AcquisitionRequest(query: "a"))
        let b = m.submit(AcquisitionRequest(query: "b"))
        let c = m.submit(AcquisitionRequest(query: "c"))
        #expect(m.job(b)?.state == .queued)
        m.cancel(b)
        #expect(m.job(b)?.state == .cancelled)
        #expect(await m.result(of: a)?.state == .finished(files: 1))
        #expect(await m.result(of: c)?.state == .finished(files: 1))
        #expect(peak.withLock { $0 } == 1)
        m.clearFinished()
        #expect(m.jobs.isEmpty)
    }

    @Test func aFailingHandoffFailsTheRequestButKeepsFilesThatMayAlreadyBeInTheLibrary() async throws {
        let root = makeScratchFolder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = makeAcquiredFile(in: root)
        let m = AcquisitionManager(registry: try ProviderRegistry([FakeProvider(id: "p") { _, _ in [file] }]),
                                   handoff: { _ in throw AcquisitionError.noUsableFiles("library said no") })
        let job = await m.perform(link)
        #expect(job.state == .failed(.noUsableFiles("library said no")))
        #expect(FileManager.default.fileExists(atPath: file.url.path))
    }

    @Test func progressIsReportedWhileTheProviderWorks() async throws {
        let root = makeScratchFolder(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = Mutex(false)
        let provider = FakeProvider(id: "p") { _, progress in
            progress(AcquisitionProgress(fraction: 0.4, message: "working"))
            while !gate.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
            return [makeAcquiredFile(in: root)]
        }
        let m = try manager([provider])
        let id = m.submit(link)
        await waitUntil { m.job(id)?.progress.fraction == 0.4 }
        #expect(m.job(id)?.progress.message == "working")
        gate.withLock { $0 = true }
        #expect(await m.result(of: id)?.state == .finished(files: 1))
    }
}
