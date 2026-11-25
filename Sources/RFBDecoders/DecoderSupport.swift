import Foundation
import RFBBase

/// Rejects rectangles that are negative or outside the framebuffer BEFORE any payload is read, so a
/// malicious header cannot make us allocate or read gigabytes.
@inline(__always)
func validate(_ rect: RFBRect, in framebuffer: Framebuffer) throws {
    let (fw, fh) = framebuffer.size
    guard rect.x >= 0, rect.y >= 0, rect.width >= 0, rect.height >= 0,
          rect.width <= fw, rect.height <= fh, rect.x <= fw - rect.width, rect.y <= fh - rect.height else {
        throw RFBError.protocolViolation("rect \(rect) outside framebuffer \(fw)x\(fh)")
    }
}

/// Bounds-checked forward reader over an in-memory buffer (decompressed payloads).
struct ByteCursor {
    let base: UnsafePointer<UInt8>
    let count: Int
    private(set) var position = 0

    init(_ buffer: UnsafeBufferPointer<UInt8>) {
        // A zero-length buffer may have a nil base address; any read then fails the bounds check.
        base = buffer.baseAddress ?? UnsafePointer(bitPattern: 1)!
        count = buffer.count
    }

    var remaining: Int { count - position }

    @inline(__always)
    mutating func u8() throws -> UInt8 {
        guard position < count else { throw RFBError.decodeFailed("unexpected end of decompressed data") }
        let v = base[position]
        position += 1
        return v
    }

    /// Returns a pointer to the next `n` bytes and advances past them.
    @inline(__always)
    mutating func take(_ n: Int) throws -> UnsafePointer<UInt8> {
        guard n >= 0, n <= count - position else {
            throw RFBError.decodeFailed("unexpected end of decompressed data")
        }
        let p = base + position
        position += n
        return p
    }
}

/// Upper bound for a compressed payload whose uncompressed size is at most `n` bytes (deflate's
/// worst-case expansion is tiny; this is deliberately generous).
@inline(__always)
func compressedLengthLimit(forUncompressed n: Int) -> Int {
    n + n / 8 + 64 * 1024
}
