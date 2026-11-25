import Foundation

/// Toolbar modifier keys (⌘ ⌥ ⌃ ⇧) that latch.
///
/// Each modifier is `.off`, `.oneShot` (applies to the next keypress, then turns off) or `.locked`
/// (applies to every keypress until tapped again). Tapping cycles off → oneShot → locked → off.
/// Modifiers are never left pressed on the server: `wrap(_:)` presses the active modifiers just
/// around one keypress and releases them right after.
public struct ModifierLatch: Equatable, Sendable {
    public enum State: Equatable, Sendable { case off, oneShot, locked }

    /// Order in which modifiers are pressed (and released in reverse).
    public static let order: [ModifierKey] = [.control, .option, .shift, .command]

    private var states: [ModifierKey: State] = [:]

    public init() {}

    public func state(of key: ModifierKey) -> State { states[key] ?? .off }

    /// Toolbar tap: off → oneShot → locked → off.
    public mutating func tap(_ key: ModifierKey) {
        switch state(of: key) {
        case .off: states[key] = .oneShot
        case .oneShot: states[key] = .locked
        case .locked: states[key] = .off
        }
    }

    /// Sets a state directly (e.g. long-press to lock).
    public mutating func set(_ key: ModifierKey, _ state: State) {
        states[key] = state
    }

    /// Turns everything off.
    public mutating func reset() { states = [:] }

    /// Modifiers that will apply to the next keypress, in press order.
    public var active: [ModifierKey] { Self.order.filter { state(of: $0) != .off } }

    /// Wraps one keypress (the events of one character or special key) with the active modifiers,
    /// then clears one-shot modifiers. A modifier the keypress already presses itself (e.g. Shift from
    /// `.explicitShift`) is not pressed twice. An empty keypress is returned unchanged and consumes nothing.
    public mutating func wrap(_ keypress: [KeyEvent]) -> [KeyEvent] {
        guard !keypress.isEmpty else { return keypress }
        let mods = active.filter { m in !keypress.contains(KeyEvent(keysym: m.keysym, down: true)) }
        var out: [KeyEvent] = mods.map { KeyEvent(keysym: $0.keysym, down: true) }
        out += keypress
        out += mods.reversed().map { KeyEvent(keysym: $0.keysym, down: false) }
        for (k, s) in states where s == .oneShot { states[k] = .off }
        return out
    }
}
