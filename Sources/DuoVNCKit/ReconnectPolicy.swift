import Foundation

/// Backoff schedule for automatic reconnects. Deterministic (no jitter) so it is testable.
///
/// Usage: on a failure call `nextDelay(after:)`; nil means "stop retrying, show the error".
/// Call `reset()` after a successful connection or when the user explicitly retries.
public struct ReconnectPolicy: Equatable, Sendable {
    /// Why the connection failed, as far as reconnecting is concerned (the app maps `RFBError` to this).
    public enum Failure: Equatable, Sendable {
        /// Network drop, timeout, connection refused, server closed: worth retrying.
        case transient
        /// Wrong credentials: never retry automatically (would risk lockout).
        case authentication
        /// Host key mismatch / rejected: never retry.
        case hostKey
        /// Protocol error / unsupported: retrying will not help.
        case permanent
    }

    /// Delays in seconds for attempts 1, 2, ...; the last one repeats until `maxAttempts`.
    public var schedule: [TimeInterval]
    /// Maximum automatic attempts before giving up (nil = unlimited).
    public var maxAttempts: Int?
    /// Attempts made since the last reset.
    public private(set) var attempts: Int = 0

    public init(schedule: [TimeInterval] = [0.5, 1, 2, 4, 8, 15, 30], maxAttempts: Int? = 20) {
        let cleaned = schedule.map { $0.isFinite ? max(0, $0) : 0 }
        self.schedule = cleaned.isEmpty ? [1] : cleaned
        self.maxAttempts = maxAttempts.map { max(0, $0) }
    }

    /// Delay before the next attempt for this failure, or nil to stop. Increments `attempts` when non-nil.
    public mutating func nextDelay(after failure: Failure) -> TimeInterval? {
        guard failure == .transient else { return nil }
        if let m = maxAttempts, attempts >= m { return nil }
        let d = schedule[min(attempts, schedule.count - 1)]
        attempts += 1
        return d
    }

    /// Delay for the n-th attempt (1-based) ignoring state; nil past `maxAttempts` or for n < 1.
    public func delay(forAttempt n: Int) -> TimeInterval? {
        guard n >= 1 else { return nil }
        if let m = maxAttempts, n > m { return nil }
        return schedule[min(n - 1, schedule.count - 1)]
    }

    public mutating func reset() { attempts = 0 }
}
