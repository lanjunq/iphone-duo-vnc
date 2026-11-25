import Foundation
import RFBBase
import Network
import Testing
@testable import RFBSecurity

/// Minimal Network.framework stream for the opt-in real-server probe (test-only).
final class ProbeTCPStream: ByteStream, @unchecked Sendable {
    let conn: NWConnection
    init(host: String, port: UInt16) async throws {
        conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let done = Box(false)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: if !done.value { done.value = true; c.resume() }
                case .failed(let e): if !done.value { done.value = true; c.resume(throwing: RFBError.connectionFailed("\(e)")) }
                default: break
                }
            }
            conn.start(queue: .global())
        }
    }
    func read(maxLength: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { c in
            conn.receive(minimumIncompleteLength: 1, maximumLength: maxLength) { data, _, isComplete, error in
                if let data, !data.isEmpty { c.resume(returning: data) }
                else if error != nil || isComplete { c.resume(throwing: RFBError.connectionClosed) }
                else { c.resume(throwing: RFBError.connectionClosed) }
            }
        }
    }
    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { e in
                if let e { c.resume(throwing: RFBError.connectionFailed("\(e)")) } else { c.resume() }
            })
        }
    }
    func close() { conn.cancel() }
}

/// Runs body; if it has not finished after `seconds`, closes `stream` (which fails pending reads).
func withDeadline<T: Sendable>(_ seconds: Double, closing stream: ByteStream,
                               _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    let watchdog = Task {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
        stream.close()
    }
    defer { watchdog.cancel() }
    return try await body()
}

/// Opt-in: DUOVNC_REAL_PROBE=1. ONE type 33 authentication attempt against 127.0.0.1:5900 with the
/// non-existent test account `vnctest` and a made-up password; prints everything the server answers.
@Test(.enabled(if: ProcessInfo.processInfo.environment["DUOVNC_REAL_PROBE"] == "1"))
func realServerAppleRSAProbe() async throws {
    let s = try await ProbeTCPStream(host: "127.0.0.1", port: 5900)
    defer { s.close() }
    let r = RFBReader(stream: s, chunkSize: 1)
    let version = try await withDeadline(5, closing: s) { try await r.string(12) }
    print("PROBE version:", version.debugDescription)
    try await s.write(Data("RFB 003.889\n".utf8))
    let n = Int(try await r.u8())
    let types = try await r.bytes(n)
    print("PROBE types:", types)
    let seen = Box<Data?>(nil)
    let ctx = SecurityContext(serverVersion: version.trimmingCharacters(in: .newlines)) { key in
        seen.value = key
        return true
    }
    do {
        let outcome = try await withDeadline(15, closing: s) {
            try await AppleRSASecurityHandler().selectAndAuthenticate(
                reader: r, stream: s, credential: .macAccount(username: "vnctest", password: "not-a-real-pw-4711"),
                context: ctx)
        }
        print("PROBE handler outcome:", outcome)
    } catch {
        print("PROBE handler threw:", error)
    }
    if let k = seen.value {
        print("PROBE key bytes:", k.count, "sha256:", AppleRSASecurityHandler.sha256Fingerprint(of: k))
    }
    // Dump whatever follows until EOF or 5 s of silence.
    let start = Date()
    let tail = Box<[UInt8]>([])
    do {
        try await withDeadline(5, closing: s) {
            while true { let b = try await r.u8(); tail.value.append(b) }
        }
    } catch {
        print("PROBE tail ended after", String(format: "%.1f", Date().timeIntervalSince(start)), "s:", error)
    }
    print("PROBE tail hex:", hexString(tail.value))
    print("PROBE tail text:", String(decoding: tail.value.filter { $0 >= 0x20 && $0 < 0x7f }, as: UTF8.self))
}
