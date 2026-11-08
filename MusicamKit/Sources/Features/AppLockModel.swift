import Foundation
import Observation
import LocalAuthentication

/// Asks the system to confirm it is the owner: Face ID or Touch ID, with the device passcode (or Mac password) as the fallback.
public protocol Authenticating: Sendable {
    /// nil when authentication is possible, otherwise a short reason (for example "no passcode is set").
    func unavailableReason() -> String?
    func authenticate(reason: String) async -> Bool
}

public struct SystemAuthenticator: Authenticating {
    public init() {}

    public func unavailableReason() -> String? {
        var error: NSError?
        let context = LAContext()
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) { return nil }
        return error?.localizedDescription ?? String(localized: "This device cannot verify who you are.")
    }

    public func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

/// The app lock: when switched on, Musicam asks for Face ID / Touch ID / the device passcode when it is opened, and again
/// when it comes back after being away longer than the chosen delay. Music keeps playing while the screen is locked.
@MainActor
@Observable
public final class AppLockModel {
    public enum Delay: Int, CaseIterable, Sendable {
        case immediately = 0, oneMinute = 60, fiveMinutes = 300
    }

    public private(set) var isEnabled: Bool
    public private(set) var isLocked: Bool
    public private(set) var message: String?
    public var delay: Delay {
        didSet { defaults.set(delay.rawValue, forKey: Keys.delay) }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let authenticator: any Authenticating
    @ObservationIgnored private var leftAt: Date?
    @ObservationIgnored private var authenticating = false

    private enum Keys {
        static let enabled = "musicam.lock.enabled"
        static let delay = "musicam.lock.delay"
    }

    public init(authenticator: any Authenticating = SystemAuthenticator(), defaults: UserDefaults = .standard) {
        self.authenticator = authenticator
        self.defaults = defaults
        let on = defaults.bool(forKey: Keys.enabled)
        isEnabled = on
        isLocked = on                                         // a locked app stays locked after a restart
        delay = Delay(rawValue: defaults.integer(forKey: Keys.delay)) ?? .immediately
    }

    /// Turns the lock on or off. Either way the person has to prove it is them, so a stranger cannot switch it off.
    @discardableResult
    public func setEnabled(_ on: Bool) async -> Bool {
        message = nil
        if authenticator.unavailableReason() != nil {
            message = on ? String(localized: "To use the app lock, set a passcode on this device first.") : nil
            if on { return false }
        }
        guard await authenticator.authenticate(reason: on ? String(localized: "Turn on the Musicam lock") : String(localized: "Turn off the Musicam lock")) else {
            message = String(localized: "Could not confirm it is you, so nothing was changed.")
            return false
        }
        isEnabled = on
        defaults.set(on, forKey: Keys.enabled)
        isLocked = false
        return true
    }

    /// The app moved to the background or the window lost focus.
    public func appDidLeave(now: Date = .now) {
        guard isEnabled else { return }
        if leftAt == nil { leftAt = now }
        if delay == .immediately { isLocked = true }
    }

    /// The app is in front again.
    public func appDidReturn(now: Date = .now) {
        guard isEnabled else { leftAt = nil; return }
        if let leftAt, now.timeIntervalSince(leftAt) >= TimeInterval(delay.rawValue) { isLocked = true }
        leftAt = nil
    }

    /// Locks at once (for example when the Mac's screen locks).
    public func lockNow() {
        guard isEnabled else { return }
        isLocked = true
    }

    /// Shows the system prompt. Safe to call repeatedly.
    public func unlock() async {
        guard isLocked, !authenticating else { return }
        authenticating = true
        defer { authenticating = false }
        if await authenticator.authenticate(reason: String(localized: "Unlock Musicam")) {
            isLocked = false
            message = nil
        } else {
            message = String(localized: "Could not unlock. Try again.")
        }
    }
}
