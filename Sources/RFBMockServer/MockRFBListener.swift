import Foundation
import Network
import RFBBase

/// Accepts TCP connections on 127.0.0.1 and serves each with a `MockRFBServer` (Network.framework).
public final class MockRFBListener: @unchecked Sendable {
    public let server: MockRFBServer
    private let queue = DispatchQueue(label: "duovnc.mock.listener")
    private let lock = NSLock()
    private var listener: NWListener?
    private var _port: UInt16?
    private var streams: [ObjectIdentifier: NWConnectionStream] = [:]

    public init(server: MockRFBServer) {
        self.server = server
    }

    /// The bound port once `start` returned, else nil.
    public var port: UInt16? { lock.withLock { _port } }

    /// Starts listening on 127.0.0.1:`port` (0 = ephemeral) and returns the bound port.
    public func start(port: UInt16 = 0) async throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        let l: NWListener
        do {
            l = try NWListener(using: params)
        } catch {
            throw RFBError.connectionFailed("listener: \(error)")
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        lock.withLock { listener = l }

        final class Once: @unchecked Sendable {
            let lock = NSLock()
            var done = false
            func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
        }
        let once = Once()
        let bound: UInt16 = try await withCheckedThrowingContinuation { (c: CheckedContinuation<UInt16, Error>) in
            l.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { c.resume(returning: l.port?.rawValue ?? 0) }
                case .failed(let e):
                    if once.claim() { c.resume(throwing: RFBError.connectionFailed("listener: \(e)")) }
                case .cancelled:
                    if once.claim() { c.resume(throwing: RFBError.connectionClosed) }
                default:
                    break
                }
            }
            l.start(queue: queue)
        }
        lock.withLock { _port = bound }
        return bound
    }

    /// Stops listening and closes every connection.
    public func stop() {
        let (l, s): (NWListener?, [NWConnectionStream]) = lock.withLock {
            let r = (listener, Array(streams.values))
            listener = nil
            streams.removeAll()
            return r
        }
        l?.cancel()
        for st in s { st.close() }
    }

    private func accept(_ conn: NWConnection) {
        let stream = NWConnectionStream(connection: conn, queue: queue)
        let id = ObjectIdentifier(stream)
        lock.withLock { streams[id] = stream }
        conn.start(queue: queue)
        let server = self.server
        Task { [weak self] in
            await server.serve(stream: stream)
            self?.lock.withLock { _ = self?.streams.removeValue(forKey: id) }
        }
    }
}

/// `ByteStream` over an accepted `NWConnection`.
final class NWConnectionStream: ByteStream, @unchecked Sendable {
    private let connection: NWConnection
    private let lock = NSLock()
    private var closed = false

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
    }

    func read(maxLength: Int) async throws -> Data {
        if lock.withLock({ closed }) { throw RFBError.connectionClosed }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: max(1, maxLength)) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    c.resume(returning: data)
                } else if let error {
                    c.resume(throwing: self.isClosed ? RFBError.connectionClosed : RFBError.connectionFailed("\(error)"))
                } else if isComplete {
                    c.resume(throwing: RFBError.connectionClosed)
                } else {
                    c.resume(throwing: RFBError.connectionClosed)
                }
            }
        }
    }

    private var isClosed: Bool { lock.withLock { closed } }

    func write(_ data: Data) async throws {
        if data.isEmpty { return }
        if isClosed { throw RFBError.connectionClosed }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    c.resume(throwing: self.isClosed ? RFBError.connectionClosed : RFBError.connectionFailed("\(error)"))
                } else {
                    c.resume()
                }
            })
        }
    }

    func close() {
        let first: Bool = lock.withLock { if closed { return false }; closed = true; return true }
        if first { connection.cancel() }
    }
}
