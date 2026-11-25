import Foundation
import Network
import RFBBase

/// `ByteStream` over a Network.framework TCP connection (TCP_NODELAY, keepalive).
///
/// Thread-safety: all mutable state is guarded by a lock; NW callbacks run on a private serial queue.
/// `close()` cancels the connection and immediately fails every pending `read`/`write` with
/// `RFBError.connectionClosed`, so a receive loop blocked in `read` wakes up at once.
public final class NWByteStream: ByteStream, @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue

    private let lock = NSLock()
    private var closed = false
    /// Set when the connection failed on its own (not via `close()`); reported to later operations.
    private var failure: RFBError?
    private var nextID: UInt64 = 0
    private var pendingReads: [UInt64: CheckedContinuation<Data, Error>] = [:]
    private var pendingWrites: [UInt64: CheckedContinuation<Void, Error>] = [:]

    private init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Opens a TCP connection to `host:port`.
    ///
    /// - `host`: IPv4/IPv6 literal (brackets allowed) or a DNS / MagicDNS name.
    /// - Throws `RFBError.timeout` if not connected within `timeout` seconds,
    ///   `RFBError.connectionFailed` for refused / unreachable / invalid input, and
    ///   `RFBError.connectionClosed` if the calling task is cancelled.
    public static func connect(host: String, port: UInt16, timeout: TimeInterval = 10) async throws -> NWByteStream {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("[") && h.hasSuffix("]") && h.count > 2 { h = String(h.dropFirst().dropLast()) }
        guard !h.isEmpty else { throw RFBError.connectionFailed("empty host") }
        guard port != 0, let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw RFBError.connectionFailed("invalid port \(port)")
        }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        let safeTimeout = timeout.isFinite && timeout > 0 ? min(timeout, 600) : 10
        tcp.connectionTimeout = max(1, Int(safeTimeout.rounded(.up)))
        let params = NWParameters(tls: nil, tcp: tcp)
        let connection = NWConnection(host: NWEndpoint.Host(h), port: nwPort, using: params)
        let stream = NWByteStream(connection: connection,
                                  queue: DispatchQueue(label: "duovnc.nwbytestream", qos: .userInitiated))
        try await stream.start(timeout: safeTimeout)
        return stream
    }

    private func start(timeout: TimeInterval) async throws {
        let gate = OnceFlag()
        let lastWaitingError = LockedBox<NWError?>(nil)
        let connection = self.connection
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        if gate.claim() { cont.resume() }
                    case .waiting(let error):
                        // Refused is final for us; other waiting reasons (no route yet, local-network
                        // permission prompt on iOS) may resolve, so keep waiting until the timeout.
                        if case .posix(let code) = error, code == .ECONNREFUSED {
                            if gate.claim() {
                                connection.cancel()
                                cont.resume(throwing: RFBError.connectionFailed("connection refused"))
                            }
                        } else {
                            lastWaitingError.value = error
                        }
                    case .failed(let error):
                        if gate.claim() {
                            connection.cancel()
                            cont.resume(throwing: RFBError.connectionFailed(Self.describe(error)))
                        } else {
                            self?.shutdown(reason: .connectionFailed(Self.describe(error)))
                        }
                    case .cancelled:
                        if gate.claim() {
                            cont.resume(throwing: RFBError.connectionClosed)
                        } else {
                            self?.shutdown(reason: .connectionClosed)
                        }
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) {
                    if gate.claim() {
                        connection.cancel()
                        if let e = lastWaitingError.value {
                            cont.resume(throwing: RFBError.connectionFailed("timed out: \(Self.describe(e))"))
                        } else {
                            cont.resume(throwing: RFBError.timeout)
                        }
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code): return "\(String(cString: strerror(code.rawValue))) (POSIX \(code.rawValue))"
        case .dns(let code): return "DNS lookup failed (\(code))"
        default: return error.localizedDescription
        }
    }

    /// Fails all pending operations and marks the stream closed. `reason` is what later operations report.
    private func shutdown(reason: RFBError) {
        let (reads, writes): ([CheckedContinuation<Data, Error>], [CheckedContinuation<Void, Error>]) = lock.withLock {
            if !closed {
                closed = true
                if reason != .connectionClosed { failure = reason }
            }
            let r = Array(pendingReads.values), w = Array(pendingWrites.values)
            pendingReads.removeAll()
            pendingWrites.removeAll()
            return (r, w)
        }
        let err = failure(or: reason)
        for c in reads { c.resume(throwing: err) }
        for c in writes { c.resume(throwing: err) }
    }

    private func failure(or fallback: RFBError) -> RFBError {
        lock.withLock { failure ?? fallback }
    }

    private func mapReceiveError(_ error: NWError) -> RFBError {
        lock.withLock {
            if closed { return failure ?? .connectionClosed }
            // The peer ended the connection: report it as a normal close, like EOF.
            if case .posix(let code) = error,
               [.ENODATA, .ECONNRESET, .EPIPE, .ECANCELED, .ENOTCONN].contains(code) {
                return .connectionClosed
            }
            return .connectionFailed(Self.describe(error))
        }
    }

    public func read(maxLength: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let id: UInt64? = lock.withLock {
                if closed { return nil }
                nextID &+= 1
                pendingReads[nextID] = cont
                return nextID
            }
            guard let id else {
                cont.resume(throwing: failure(or: .connectionClosed))
                return
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: max(1, maxLength)) { data, _, isComplete, error in
                guard let c = self.lock.withLock({ self.pendingReads.removeValue(forKey: id) }) else { return }
                if let data, !data.isEmpty {
                    c.resume(returning: data)
                } else if let error {
                    c.resume(throwing: self.mapReceiveError(error))
                } else {
                    // isComplete (peer sent FIN) or an empty non-final delivery: treat as EOF.
                    _ = isComplete
                    c.resume(throwing: RFBError.connectionClosed)
                }
            }
        }
    }

    public func write(_ data: Data) async throws {
        if data.isEmpty { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let id: UInt64? = lock.withLock {
                if closed { return nil }
                nextID &+= 1
                pendingWrites[nextID] = cont
                return nextID
            }
            guard let id else {
                cont.resume(throwing: failure(or: .connectionClosed))
                return
            }
            connection.send(content: data, completion: .contentProcessed { error in
                guard let c = self.lock.withLock({ self.pendingWrites.removeValue(forKey: id) }) else { return }
                if let error {
                    c.resume(throwing: self.mapReceiveError(error))
                } else {
                    c.resume()
                }
            })
        }
    }

    public func close() {
        shutdown(reason: .connectionClosed)
        connection.cancel()
    }

    deinit {
        connection.cancel()
    }
}

/// One-shot flag: the first `claim()` returns true, all later ones false.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}

/// Minimal lock-protected box.
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
