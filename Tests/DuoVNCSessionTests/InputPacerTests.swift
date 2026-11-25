import Testing
import Foundation
@testable import DuoVNCSession

/// A clock the tests control: `sleep` advances it instead of waiting.
@MainActor
final class FakeClock {
    var t: TimeInterval = 100
    var sleeps: [TimeInterval] = []
}

@MainActor
@Suite struct InputPacerTests {
    struct Sent: Equatable {
        var input: PacedInput
        var at: TimeInterval
    }

    final class Log {
        var sent: [Sent] = []
    }

    func make(_ clock: FakeClock, _ log: Log, timing: InputPacer.Timing = InputPacer.Timing()) -> InputPacer {
        InputPacer(timing: timing,
                   now: { clock.t },
                   sleep: { seconds in
                       clock.sleeps.append(seconds)
                       clock.t += seconds
                       await Task.yield()
                   },
                   sink: { input in log.sent.append(Sent(input: input, at: clock.t)) })
    }

    func settle() async {
        for _ in 0..<200 { await Task.yield() }
    }

    @Test func holdsEverythingUntilTheGateOpensThenKeepsOrder() async {
        let clock = FakeClock(), log = Log()
        let p = make(clock, log)
        p.enqueue(.pointer(x: 10, y: 20, buttons: 0))
        p.enqueue(.key(keysym: 0x61, down: true))
        p.enqueue(.key(keysym: 0x61, down: false))
        await settle()
        #expect(log.sent.isEmpty)
        #expect(p.pendingCount == 3)
        p.isOpen = true
        await settle()
        #expect(log.sent.map(\.input) == [.pointer(x: 10, y: 20, buttons: 0),
                                         .key(keysym: 0x61, down: true), .key(keysym: 0x61, down: false)])
        #expect(p.pendingCount == 0)
    }

    @Test func keyEventsAreAtLeastTwelveMillisecondsApart() async {
        let clock = FakeClock(), log = Log()
        let p = make(clock, log)
        p.isOpen = true
        for k in [UInt32(0x41), 0x62, 0x21] {
            p.enqueue(.key(keysym: k, down: true))
            p.enqueue(.key(keysym: k, down: false))
        }
        await settle()
        #expect(log.sent.count == 6)
        let gaps = zip(log.sent.dropFirst(), log.sent).map { $0.at - $1.at }
        #expect(gaps.allSatisfy { $0 >= 0.0115 })
        #expect(log.sent.map(\.input).first == .key(keysym: 0x41, down: true))
        #expect(log.sent.map(\.input).last == .key(keysym: 0x21, down: false))
    }

    @Test func clickWaitsAfterTheMoveAndHoldsTheButton() async {
        let clock = FakeClock(), log = Log()
        let p = make(clock, log)
        p.isOpen = true
        // A direct tap: move, press, release, all issued at the same instant.
        p.enqueue([.pointer(x: 300, y: 400, buttons: 0), .pointer(x: 300, y: 400, buttons: 1),
                   .pointer(x: 300, y: 400, buttons: 0)])
        await settle()
        #expect(log.sent.count == 3)
        guard log.sent.count == 3 else { return }
        #expect(log.sent[1].at - log.sent[0].at >= 0.0795)   // pointer rests before the press
        #expect(log.sent[2].at - log.sent[1].at >= 0.0795)   // press lasts before the release
    }

    @Test func pressAfterALongRestIsNotDelayed() async {
        let clock = FakeClock(), log = Log()
        let p = make(clock, log)
        p.isOpen = true
        p.enqueue(.pointer(x: 5, y: 5, buttons: 0))
        await settle()
        clock.t += 3
        p.enqueue(.pointer(x: 5, y: 5, buttons: 1))
        await settle()
        #expect(log.sent.count == 2)
        #expect(clock.sleeps.isEmpty)
    }

    @Test func queuedMovesCollapseButButtonChangesNeverDo() async {
        let clock = FakeClock(), log = Log()
        let p = make(clock, log)
        // Gate closed: a drag-aim produces many moves, then a click.
        for i in 0..<50 { p.enqueue(.pointer(x: i, y: i, buttons: 0)) }
        p.enqueue(.pointer(x: 49, y: 49, buttons: 1))
        p.enqueue(.pointer(x: 60, y: 60, buttons: 1))
        p.enqueue(.pointer(x: 70, y: 70, buttons: 1))
        p.enqueue(.pointer(x: 70, y: 70, buttons: 0))
        #expect(p.pendingCount == 4)
        p.isOpen = true
        await settle()
        #expect(log.sent.map(\.input) == [.pointer(x: 49, y: 49, buttons: 0), .pointer(x: 49, y: 49, buttons: 1),
                                         .pointer(x: 70, y: 70, buttons: 1), .pointer(x: 70, y: 70, buttons: 0)])
    }

    @Test func resetDropsQueuedInputAndClosesTheGate() async {
        let clock = FakeClock(), log = Log()
        let p = make(clock, log)
        p.enqueue(.key(keysym: 0x70, down: true))     // e.g. a password typed just before a drop
        p.enqueue(.key(keysym: 0x70, down: false))
        p.reset()
        #expect(p.pendingCount == 0)
        #expect(!p.isOpen)
        p.isOpen = true
        await settle()
        #expect(log.sent.isEmpty)
        // And it keeps working afterwards.
        p.enqueue(.key(keysym: 0x71, down: true))
        await settle()
        #expect(log.sent.map(\.input) == [.key(keysym: 0x71, down: true)])
    }

    @Test func resetWhileWaitingStopsTheOldDrain() async {
        let clock = FakeClock(), log = Log()
        let p = make(clock, log)
        p.isOpen = true
        p.enqueue(.key(keysym: 0x61, down: true))
        p.enqueue(.key(keysym: 0x61, down: false))    // will wait 12 ms
        p.reset()
        await settle()
        #expect(log.sent.count <= 1)
        let before = log.sent.count
        p.isOpen = true
        await settle()
        #expect(log.sent.count == before)
    }

    @Test func fullQueueDropsNewInput() async {
        let clock = FakeClock(), log = Log()
        let p = make(clock, log)
        p.capacity = 4
        for i in 0..<10 { p.enqueue(.key(keysym: UInt32(0x30 + i), down: true)) }
        #expect(p.pendingCount == 4)
    }
}
