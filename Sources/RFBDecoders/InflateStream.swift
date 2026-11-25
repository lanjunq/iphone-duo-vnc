import Foundation
import zlib
import RFBBase

/// A persistent zlib inflate stream (RFC 1950 framing) that lives as long as the RFB connection.
///
/// RFB's Zlib, ZRLE and Tight encodings each compress all rectangles of a connection through the same
/// deflate stream(s), flushing with Z_SYNC_FLUSH at the end of every rectangle. The decoder therefore
/// must feed each rectangle's compressed bytes into the SAME inflate state, in order.
///
/// Not thread-safe: use from one task at a time (decoders are per connection and run on the receive loop).
public final class InflateStream {
    /// zlib keeps a back pointer to the z_stream it was initialised with, so the struct must live at a
    /// stable heap address for its whole life.
    private let strm: UnsafeMutablePointer<z_stream>
    private var initialized = false

    public init() {
        strm = .allocate(capacity: 1)
        strm.initialize(to: z_stream())
    }

    deinit {
        if initialized { inflateEnd(strm) }
        strm.deinitialize(count: 1)
        strm.deallocate()
    }

    /// Total bytes produced since creation / the last reset (for statistics and tests).
    public var totalOut: Int { initialized ? Int(strm.pointee.total_out) : 0 }

    /// Discards all stream state (Tight's per-stream reset bits). The next input must start a new zlib stream.
    public func reset() throws {
        guard initialized else { return }
        if inflateReset(strm) != Z_OK {
            inflateEnd(strm)
            initialized = false
            throw RFBError.decodeFailed("inflateReset failed")
        }
    }

    private func ensureInitialized() throws {
        if initialized { return }
        strm.pointee = z_stream()
        let r = inflateInit_(strm, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        guard r == Z_OK else { throw RFBError.decodeFailed("inflateInit failed (\(r))") }
        initialized = true
    }

    /// Inflates all of `input` and requires the result to be exactly `size` bytes.
    public func inflate(_ input: [UInt8], exactOutputSize size: Int) throws -> [UInt8] {
        guard size >= 0 else { throw RFBError.decodeFailed("negative inflate size") }
        let out = try run(input, maxOutput: size, initialCapacity: size + 1)
        guard out.count == size else {
            throw RFBError.decodeFailed("zlib data inflated to \(out.count) bytes, expected \(size)")
        }
        return out
    }

    /// Inflates all of `input`; throws if the output would exceed `maxOutputSize` bytes.
    public func inflate(_ input: [UInt8], maxOutputSize: Int) throws -> [UInt8] {
        guard maxOutputSize >= 0 else { throw RFBError.decodeFailed("negative inflate limit") }
        let initial = min(maxOutputSize + 1, max(64 * 1024, input.count * 4))
        return try run(input, maxOutput: maxOutputSize, initialCapacity: initial)
    }

    /// Feeds every input byte through inflate (so the stream stays in sync even when the tail of the
    /// input is only a sync-flush marker) and collects the output, bounded by `maxOutput`.
    private func run(_ input: [UInt8], maxOutput: Int, initialCapacity: Int) throws -> [UInt8] {
        try ensureInitialized()
        if input.isEmpty { return [] }
        let hardCap = maxOutput + 1   // one byte of slack to detect over-long output
        var out = [UInt8](repeating: 0, count: max(1, min(initialCapacity, hardCap)))
        var produced = 0
        defer {
            strm.pointee.next_in = nil
            strm.pointee.avail_in = 0
            strm.pointee.next_out = nil
            strm.pointee.avail_out = 0
        }
        try input.withUnsafeBufferPointer { inBuf in
            strm.pointee.next_in = UnsafeMutablePointer(mutating: inBuf.baseAddress!)
            strm.pointee.avail_in = uInt(inBuf.count)
            while true {
                if produced == out.count {
                    if out.count >= hardCap {
                        throw RFBError.decodeFailed("zlib data inflates beyond \(maxOutput) bytes")
                    }
                    let grown = min(hardCap, max(out.count * 2, out.count + 64 * 1024))
                    out.append(contentsOf: repeatElement(0, count: grown - out.count))
                }
                let ret: Int32 = out.withUnsafeMutableBufferPointer { ob in
                    strm.pointee.next_out = ob.baseAddress! + produced
                    strm.pointee.avail_out = uInt(ob.count - produced)
                    let r = zlib.inflate(strm, Z_SYNC_FLUSH)
                    produced = ob.count - Int(strm.pointee.avail_out)
                    return r
                }
                if produced > maxOutput {
                    throw RFBError.decodeFailed("zlib data inflates beyond \(maxOutput) bytes")
                }
                let availIn = strm.pointee.avail_in
                let availOut = strm.pointee.avail_out
                switch ret {
                case Z_OK:
                    // Done only when every input byte is consumed AND inflate had spare output room
                    // (otherwise it may still hold pending output).
                    if availIn == 0 && availOut > 0 { return }
                case Z_BUF_ERROR:
                    if availIn == 0 && availOut > 0 { return }
                    if availOut > 0 { throw RFBError.decodeFailed("inflate made no progress") }
                case Z_STREAM_END:
                    // A server is not expected to finish its stream, but tolerate it: the next data
                    // must then start a fresh zlib stream.
                    guard availIn == 0 else { throw RFBError.decodeFailed("data after end of zlib stream") }
                    if inflateReset(strm) != Z_OK { throw RFBError.decodeFailed("inflateReset failed") }
                    return
                default:
                    let msg = strm.pointee.msg.map { String(cString: $0) } ?? "code \(ret)"
                    throw RFBError.decodeFailed("inflate failed: \(msg)")
                }
            }
        }
        out.removeLast(out.count - produced)
        return out
    }
}
