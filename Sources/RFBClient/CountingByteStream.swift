import Foundation
import RFBBase

/// Wraps a `ByteStream` and counts bytes in both directions (for `RFBStatistics`).
final class CountingByteStream: ByteStream, @unchecked Sendable {
    let base: ByteStream
    private let lock = NSLock()
    private var _received = 0
    private var _sent = 0

    init(_ base: ByteStream) { self.base = base }

    var received: Int { lock.withLock { _received } }
    var sent: Int { lock.withLock { _sent } }

    func read(maxLength: Int) async throws -> Data {
        let d = try await base.read(maxLength: maxLength)
        lock.withLock { _received += d.count }
        return d
    }

    func write(_ data: Data) async throws {
        try await base.write(data)
        lock.withLock { _sent += data.count }
    }

    func close() { base.close() }
}
