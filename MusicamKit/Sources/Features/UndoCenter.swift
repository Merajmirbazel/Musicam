import Foundation
import Observation

/// One place for "Undo". An action that can be reversed registers itself here; the person then has `window` seconds
/// (ten by default) to take it back. When the time is up the action becomes final: its `expire` step runs
/// (for example freeing the disk space of removed songs). Only one undo is offered at a time: a newer action makes the
/// older one final straight away. Same behaviour on macOS and iOS.
@MainActor
@Observable
public final class UndoCenter {
    public static let window: TimeInterval = 10

    public struct Item: Identifiable, Equatable, Sendable {
        public let id = UUID()
        public let message: String
        public let deadline: Date
        public let duration: TimeInterval
    }

    public private(set) var current: Item?

    @ObservationIgnored private var undoAction: (@MainActor () async -> Void)?
    @ObservationIgnored private var expireAction: (@MainActor () async -> Void)?
    @ObservationIgnored private var timer: Task<Void, Never>?

    public init() {}

    /// Offers an undo for an action that has just been done.
    public func register(_ message: String, window: TimeInterval = UndoCenter.window,
                         undo: @escaping @MainActor () async -> Void, expire: (@MainActor () async -> Void)? = nil) {
        finishCurrent()
        let item = Item(message: message, deadline: Date().addingTimeInterval(window), duration: window)
        current = item
        undoAction = undo
        expireAction = expire
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(window))
            guard !Task.isCancelled else { return }
            self?.expire(item.id)
        }
    }

    /// Takes the action back. Does nothing if the time is up.
    public func perform() async {
        guard let item = current, Date() <= item.deadline.addingTimeInterval(0.25) else { return }
        let action = undoAction
        clear()
        await action?()
    }

    /// Makes the action final now (for example when the banner is dismissed).
    public func dismiss() { finishCurrent() }

    private func expire(_ id: UUID) {
        guard current?.id == id else { return }
        finishCurrent()
    }

    private func finishCurrent() {
        let action = expireAction
        clear()
        if let action { Task { await action() } }
    }

    private func clear() {
        timer?.cancel()
        timer = nil
        current = nil
        undoAction = nil
        expireAction = nil
    }
}
