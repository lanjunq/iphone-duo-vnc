import Foundation
import RFBBase
import zlib

/// A persistent zlib deflate stream. Each `compress` call ends with Z_SYNC_FLUSH so the receiver can
/// inflate everything sent so far, while the dictionary persists across calls (as Zlib/ZRLE/Tight need).
/// Not thread-safe; owned by one encoder.
final class DeflateStream {
    private let strm: UnsafeMutablePointer<z_stream>
    private var initialized = false
    let level: Int32

    init(level: Int) {
        self.level = Int32(max(0, min(9, level)))
        strm = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
        strm.initialize(to: z_stream())
    }

    deinit {
        if initialized { deflateEnd(strm) }
        strm.deinitialize(count: 1)
        strm.deallocate()
    }

    func compress(_ input: [UInt8]) throws -> [UInt8] {
        if !initialized {
            let rc = deflateInit_(strm, level, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
            guard rc == Z_OK else { throw RFBError.protocolViolation("deflateInit failed (\(rc))") }
            initialized = true
        }
        var out = [UInt8]()
        out.reserveCapacity(input.count / 2 + 64)
        let chunk = max(16 * 1024, Int(deflateBound(strm, uLong(input.count))) + 64)
        var buf = [UInt8](repeating: 0, count: chunk)
        try input.withUnsafeBufferPointer { inp in
            strm.pointee.next_in = UnsafeMutablePointer(mutating: inp.baseAddress)
            strm.pointee.avail_in = uInt(inp.count)
            defer { strm.pointee.next_in = nil; strm.pointee.avail_in = 0 }
            while true {
                let produced: Int = try buf.withUnsafeMutableBufferPointer { ob in
                    strm.pointee.next_out = ob.baseAddress
                    strm.pointee.avail_out = uInt(ob.count)
                    let rc = deflate(strm, Z_SYNC_FLUSH)
                    // Z_BUF_ERROR only means "no progress possible", which is fine once input is consumed.
                    guard rc == Z_OK || rc == Z_BUF_ERROR else {
                        throw RFBError.protocolViolation("deflate failed (\(rc))")
                    }
                    let n = ob.count - Int(strm.pointee.avail_out)
                    strm.pointee.next_out = nil
                    return n
                }
                out.append(contentsOf: buf[0..<produced])
                // With Z_SYNC_FLUSH, deflate is done when it left output space unused.
                if strm.pointee.avail_in == 0 && produced < buf.count { break }
            }
        }
        return out
    }
}
