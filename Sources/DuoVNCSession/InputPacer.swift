import Foundation

/// One input message bound for the server.
public enum PacedInput: Equatable, Sendable {
    case key(keysym: UInt32, down: Bool)
    case pointer(x: Int, y: Int, buttons: UInt8)
    case scroll(x: Int, y: Int, deltaX: Int, deltaY: Int, buttons: UInt8)
}

/// Orders, gates and spaces out input so the macOS Screen Sharing server does not lose it.
///
/// Measured against macOS 27.0.1 (see docs/macos-screen-sharing-notes.md):
/// - input sent during roughly the first 2 seconds after connect is silently dropped, so nothing is
///   delivered until the gate is opened (`isOpen`); what arrives earlier waits in order;
/// - key events 12 ms apart were typed correctly 8 times out of 8, while unspaced bursts made the
///   server fall behind, so key events are spaced by `keyInterval`;
/// - a button press needs the pointer to have been at the position for a moment, and a release needs
///   the press to have lasted a moment (80 ms and 60 ms worked), so a change of the button state is
///   sent no sooner than `buttonChangeInterval` after the previous pointer message.
///
/// Pure pointer moves are not delayed, and queued moves that were not sent yet collapse into the
/// latest one. `reset()` drops everything that is still queued (used when a connection ends, so input
/// meant for one connection, a password for example, is never replayed into the next).
@MainActor
public final class InputPacer {
    public struct Timing: Equatable, Sendable {
        public var keyInterval: TimeInterval
        public var buttonChangeInterval: TimeInterval
        public init(keyInterval: TimeInterval = 0.012, buttonChangeInterval: TimeInterval = 0.08) {
            self.keyInterval = keyInterval
            self.buttonChangeInterval = buttonChangeInterval
        }
    }

    private struct Entry {
        var input: PacedInput
        /// A pointer message that changes the button state relative to the pointer message before it.
        var isButtonChange: Bool
    }

    public var timing: Timing
    /// Queue limit; when it is full new input is dropped (the server is not reading, or the gate
    /// never opened).
    public var capacity: Int = 4096

    private let sink: (PacedInput) -> Void
    private let now: () -> TimeInterval
    private let sleep: (TimeInterval) async -> Void
    private var queue: [Entry] = []
    private var queuedButtons: UInt8 = 0
    private var lastKeyAt: TimeInterval?
    private var lastPointerAt: TimeInterval?
    private var epoch: Int = 0
    private var draining: Bool = false

    /// False = hold everything. Opening the gate starts delivery.
    public var isOpen: Bool = false {
        didSet {
            if isOpen && !oldValue { pump() }
        }
    }

    public var pendingCount: Int { queue.count }

    /// - Parameters:
    ///   - sink: delivers one message (called on the main actor, in order).
    ///   - now: monotonic clock in seconds (injected in tests).
    ///   - sleep: suspends for the given seconds (injected in tests).
    public init(timing: Timing = Timing(),
                now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                sleep: @escaping (TimeInterval) async -> Void = { seconds in
                    try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                },
                sink: @escaping (PacedInput) -> Void) {
        self.timing = timing
        self.now = now
        self.sleep = sleep
        self.sink = sink
    }

    public func enqueue(_ input: PacedInput) {
        var entry = Entry(input: input, isButtonChange: false)
        if case .pointer(_, _, let buttons) = input {
            entry.isButtonChange = buttons != queuedButtons
            queuedButtons = buttons
            // Collapse a run of not-yet-sent moves into the newest one.
            if !entry.isButtonChange, let last = queue.last, case .pointer = last.input, !last.isButtonChange {
                queue[queue.count - 1] = entry
                pump()
                return
            }
        }
        guard queue.count < capacity else { return }
        queue.append(entry)
        pump()
    }

    public func enqueue(_ inputs: [PacedInput]) {
        for input in inputs { enqueue(input) }
    }

    /// Drops everything queued, closes the gate and forgets the button state.
    public func reset() {
        epoch &+= 1
        queue.removeAll()
        queuedButtons = 0
        lastKeyAt = nil
        lastPointerAt = nil
        draining = false
        isOpen = false
    }

    private func delayNeeded(for entry: Entry) -> TimeInterval {
        let t = now()
        let wait: TimeInterval
        switch entry.input {
        case .key:
            guard let last = lastKeyAt else { return 0 }
            wait = timing.keyInterval - (t - last)
        case .pointer:
            guard entry.isButtonChange, let last = lastPointerAt else { return 0 }
            wait = timing.buttonChangeInterval - (t - last)
        case .scroll:
            return 0
        }
        // Anything under half a millisecond counts as "now": it also keeps floating-point residue
        // from turning into an endless series of zero-length sleeps.
        return wait < 0.0005 ? 0 : wait
    }

    private func pump() {
        guard isOpen, !draining, !queue.isEmpty else { return }
        draining = true
        let myEpoch = epoch
        Task { @MainActor [weak self] in
            while true {
                guard let me = self, me.epoch == myEpoch else { return }
                guard me.isOpen, let head = me.queue.first else {
                    me.draining = false
                    return
                }
                let wait = me.delayNeeded(for: head)
                if wait > 0 {
                    await me.sleep(wait)
                    // The queue may have been reset, or its head replaced by a newer move, meanwhile.
                    continue
                }
                me.queue.removeFirst()
                switch head.input {
                case .key: me.lastKeyAt = me.now()
                case .pointer, .scroll: me.lastPointerAt = me.now()
                }
                me.sink(head.input)
            }
        }
    }
}
