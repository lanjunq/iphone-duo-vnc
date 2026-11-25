import Foundation

/// A reliable, ordered, bidirectional byte stream (TCP, or an in-memory pipe in tests).
/// One concurrent reader and any number of sequential writers are supported.
public protocol ByteStream: AnyObject, Sendable {
    /// Returns between 1 and `maxLength` bytes. Throws `RFBError.connectionClosed` at EOF / after `close()`.
    func read(maxLength: Int) async throws -> Data
    /// Writes all of `data` (order preserved across sequential calls).
    func write(_ data: Data) async throws
    /// Idempotent. Pending and future reads throw `RFBError.connectionClosed`.
    func close()
}

/// Big-endian message builder for outgoing RFB messages.
public struct ByteBuilder: Sendable {
    public private(set) var data = Data()
    public init() {}
    public init(capacity: Int) { data.reserveCapacity(capacity) }

    public mutating func u8(_ v: UInt8) { data.append(v) }
    public mutating func u16(_ v: UInt16) { data.append(UInt8(v >> 8)); data.append(UInt8(v & 0xff)) }
    public mutating func u32(_ v: UInt32) {
        data.append(UInt8(v >> 24)); data.append(UInt8((v >> 16) & 0xff))
        data.append(UInt8((v >> 8) & 0xff)); data.append(UInt8(v & 0xff))
    }
    public mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    public mutating func bytes(_ b: [UInt8]) { data.append(contentsOf: b) }
    public mutating func bytes(_ d: Data) { data.append(d) }
    public mutating func zeros(_ n: Int) { if n > 0 { data.append(Data(count: n)) } }
    public mutating func ascii(_ s: String) { data.append(Data(s.utf8)) }
}

/// Buffered big-endian reader over a `ByteStream`. NOT thread-safe: use from one task at a time.
/// Small reads are served from an internal buffer, so decoders may call `u8()` in loops, but for bulk
/// pixel data always prefer `bytes(_:)` / `data(_:)` with the full length.
public final class RFBReader {
    private let stream: ByteStream
    private var buffer = [UInt8]()
    private var offset = 0
    private let chunkSize: Int

    public init(stream: ByteStream, chunkSize: Int = 256 * 1024) {
        self.stream = stream
        self.chunkSize = chunkSize
    }

    /// Bytes currently buffered and not yet consumed.
    public var bufferedCount: Int { buffer.count - offset }

    private func fill(atLeast n: Int) async throws {
        if bufferedCount >= n { return }
        if offset > 0 {
            buffer.removeFirst(offset)
            offset = 0
        }
        while buffer.count < n {
            let chunk = try await stream.read(maxLength: max(chunkSize, n - buffer.count))
            if chunk.isEmpty { throw RFBError.connectionClosed }
            buffer.append(contentsOf: chunk)
        }
    }

    public func u8() async throws -> UInt8 {
        if bufferedCount < 1 { try await fill(atLeast: 1) }
        let v = buffer[offset]
        offset += 1
        return v
    }

    public func u16() async throws -> UInt16 {
        if bufferedCount < 2 { try await fill(atLeast: 2) }
        let v = UInt16(buffer[offset]) << 8 | UInt16(buffer[offset + 1])
        offset += 2
        return v
    }

    public func u32() async throws -> UInt32 {
        if bufferedCount < 4 { try await fill(atLeast: 4) }
        let v = UInt32(buffer[offset]) << 24 | UInt32(buffer[offset + 1]) << 16
            | UInt32(buffer[offset + 2]) << 8 | UInt32(buffer[offset + 3])
        offset += 4
        return v
    }

    public func i32() async throws -> Int32 { Int32(bitPattern: try await u32()) }

    /// Largest single read `bytes(_:)` accepts (128 MiB, above a raw 4K frame of 33 MB). A backstop
    /// against hostile length fields; callers should still cap lengths to what the message allows.
    public static let maxReadLength = 128 << 20

    /// Reads exactly `n` bytes (n may be 0). Throws `protocolViolation` for n < 0 or n > `maxReadLength`.
    public func bytes(_ n: Int) async throws -> [UInt8] {
        guard n >= 0 else { throw RFBError.protocolViolation("negative read length") }
        guard n <= Self.maxReadLength else { throw RFBError.protocolViolation("read length \(n) too large") }
        if n == 0 { return [] }
        try await fill(atLeast: n)
        let out = Array(buffer[offset..<(offset + n)])
        offset += n
        return out
    }

    public func data(_ n: Int) async throws -> Data { Data(try await bytes(n)) }

    public func skip(_ n: Int) async throws { _ = try await bytes(n) }

    /// Reads `n` bytes and decodes them as UTF-8 (lossy), e.g. a reason string or desktop name.
    public func string(_ n: Int) async throws -> String {
        String(decoding: try await bytes(n), as: UTF8.self)
    }
}

/// In-memory connected stream pair for tests and for the in-app demo server.
public final class PipeByteStream: ByteStream, @unchecked Sendable {
    private final class Channel: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private var closed = false
        private var waiter: CheckedContinuation<Void, Never>?

        func push(_ d: Data) throws {
            let w: CheckedContinuation<Void, Never>? = try lock.withLock {
                if closed { throw RFBError.connectionClosed }
                buffer.append(d)
                let w = waiter
                waiter = nil
                return w
            }
            w?.resume()
        }

        func close() {
            let w: CheckedContinuation<Void, Never>? = lock.withLock {
                closed = true
                let w = waiter
                waiter = nil
                return w
            }
            w?.resume()
        }

        func pop(max: Int) async throws -> Data {
            while true {
                let chunk: Data? = try lock.withLock {
                    if !buffer.isEmpty {
                        let n = Swift.min(max, buffer.count)
                        let out = Data(buffer.prefix(n))
                        buffer.removeFirst(n)
                        return out
                    }
                    if closed { throw RFBError.connectionClosed }
                    return nil
                }
                if let chunk { return chunk }
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    let resumeNow: Bool = lock.withLock {
                        if !buffer.isEmpty || closed { return true }
                        waiter = c
                        return false
                    }
                    if resumeNow { c.resume() }
                }
            }
        }
    }

    private let incoming: Channel
    private let outgoing: Channel

    private init(incoming: Channel, outgoing: Channel) {
        self.incoming = incoming
        self.outgoing = outgoing
    }

    /// Two connected ends: what one writes, the other reads.
    public static func makePair() -> (PipeByteStream, PipeByteStream) {
        let a = Channel(), b = Channel()
        return (PipeByteStream(incoming: a, outgoing: b), PipeByteStream(incoming: b, outgoing: a))
    }

    public func read(maxLength: Int) async throws -> Data {
        try await incoming.pop(max: Swift.max(1, maxLength))
    }

    public func write(_ data: Data) async throws {
        if data.isEmpty { return }
        try outgoing.push(data)
    }

    public func close() {
        incoming.close()
        outgoing.close()
    }
}
