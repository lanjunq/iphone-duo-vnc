import Foundation
import CoreGraphics

/// The decoded remote screen. Thread-safe (internally locked).
///
/// Pixel layout: 4 bytes per pixel, row-major, no row padding (stride = width * 4),
/// memory order B, G, R, A. Alpha is always 255. This matches `PixelFormat.bgrx8888` on the wire
/// (with the X byte replaced by 255) and Metal's `.bgra8Unorm`.
public final class Framebuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var _width: Int
    private var _height: Int
    private var storage: [UInt8]
    /// Incremented on every mutation; cheap change detection for renderers.
    private var _generation: UInt64 = 0

    public init(width: Int, height: Int) {
        _width = max(0, width)
        _height = max(0, height)
        storage = [UInt8](repeating: 0, count: _width * _height * 4)
        Self.setOpaque(&storage)
    }

    private static func setOpaque(_ s: inout [UInt8]) {
        var i = 3
        while i < s.count { s[i] = 255; i += 4 }
    }

    public var width: Int { lock.withLock { _width } }
    public var height: Int { lock.withLock { _height } }
    public var size: (width: Int, height: Int) { lock.withLock { (_width, _height) } }
    public var generation: UInt64 { lock.withLock { _generation } }

    /// Reallocates to the new size; contents become opaque black.
    public func resize(width: Int, height: Int) {
        lock.withLock {
            _width = max(0, width)
            _height = max(0, height)
            storage = [UInt8](repeating: 0, count: _width * _height * 4)
            Self.setOpaque(&storage)
            _generation &+= 1
        }
    }

    private func check(_ r: RFBRect) throws {
        guard r.x >= 0, r.y >= 0, r.width >= 0, r.height >= 0, r.maxX <= _width, r.maxY <= _height else {
            throw RFBError.protocolViolation("rect \(r) outside framebuffer \(_width)x\(_height)")
        }
    }

    /// Read access to the whole buffer. Do not escape the pointer.
    public func withPixels<T>(_ body: (UnsafeRawBufferPointer, _ width: Int, _ height: Int) throws -> T) rethrows -> T {
        try lock.withLock {
            try storage.withUnsafeBytes { try body($0, _width, _height) }
        }
    }

    /// Write access to the whole buffer for decoders that want to write in place. The caller must keep
    /// alpha at 255 and stay in bounds. Do not escape the pointer.
    public func withMutablePixels<T>(_ body: (UnsafeMutableRawBufferPointer, _ width: Int, _ height: Int) throws -> T) rethrows -> T {
        try lock.withLock {
            _generation &+= 1
            let w = _width, h = _height
            return try storage.withUnsafeMutableBytes { try body($0, w, h) }
        }
    }

    /// Solid fill.
    public func fill(_ rect: RFBRect, blue: UInt8, green: UInt8, red: UInt8) throws {
        try lock.withLock {
            try check(rect)
            if rect.isEmpty { return }
            _generation &+= 1
            let w = _width
            storage.withUnsafeMutableBytes { buf in
                let p = buf.bindMemory(to: UInt8.self).baseAddress!
                // Fill the first row, then memcpy it to the others.
                var q = p + (rect.y * w + rect.x) * 4
                for _ in 0..<rect.width {
                    q[0] = blue; q[1] = green; q[2] = red; q[3] = 255
                    q += 4
                }
                let first = p + (rect.y * w + rect.x) * 4
                if rect.height > 1 {
                    for row in 1..<rect.height {
                        memcpy(p + ((rect.y + row) * w + rect.x) * 4, first, rect.width * 4)
                    }
                }
            }
        }
    }

    /// Writes `rect.width * rect.height` pixels of wire-format B,G,R,X (X ignored; alpha forced to 255).
    public func writeBGRX(_ rect: RFBRect, _ pixels: UnsafeRawBufferPointer) throws {
        try lock.withLock {
            try check(rect)
            if rect.isEmpty { return }
            guard pixels.count >= rect.width * rect.height * 4 else {
                throw RFBError.decodeFailed("writeBGRX: need \(rect.width * rect.height * 4) bytes, got \(pixels.count)")
            }
            _generation &+= 1
            let w = _width
            storage.withUnsafeMutableBytes { buf in
                let dst = buf.bindMemory(to: UInt8.self).baseAddress!
                let src = pixels.bindMemory(to: UInt8.self).baseAddress!
                for row in 0..<rect.height {
                    let d = dst + ((rect.y + row) * w + rect.x) * 4
                    memcpy(d, src + row * rect.width * 4, rect.width * 4)
                    var i = 3
                    while i < rect.width * 4 { d[i] = 255; i += 4 }
                }
            }
        }
    }

    public func writeBGRX(_ rect: RFBRect, _ pixels: [UInt8]) throws {
        try pixels.withUnsafeBytes { try writeBGRX(rect, $0) }
    }

    /// Writes `rect.width * rect.height` pixels given as 3-byte triples.
    /// `rgbOrder == true`: source is R,G,B (Tight TPIXEL, JPEG). `false`: source is B,G,R (ZRLE CPIXEL).
    public func write24(_ rect: RFBRect, _ pixels: UnsafeRawBufferPointer, rgbOrder: Bool) throws {
        try lock.withLock {
            try check(rect)
            if rect.isEmpty { return }
            guard pixels.count >= rect.width * rect.height * 3 else {
                throw RFBError.decodeFailed("write24: need \(rect.width * rect.height * 3) bytes, got \(pixels.count)")
            }
            _generation &+= 1
            let w = _width
            storage.withUnsafeMutableBytes { buf in
                let dst = buf.bindMemory(to: UInt8.self).baseAddress!
                var s = pixels.bindMemory(to: UInt8.self).baseAddress!
                for row in 0..<rect.height {
                    var d = dst + ((rect.y + row) * w + rect.x) * 4
                    for _ in 0..<rect.width {
                        if rgbOrder {
                            d[0] = s[2]; d[1] = s[1]; d[2] = s[0]
                        } else {
                            d[0] = s[0]; d[1] = s[1]; d[2] = s[2]
                        }
                        d[3] = 255
                        d += 4
                        s += 3
                    }
                }
            }
        }
    }

    public func write24(_ rect: RFBRect, _ pixels: [UInt8], rgbOrder: Bool) throws {
        try pixels.withUnsafeBytes { try write24(rect, $0, rgbOrder: rgbOrder) }
    }

    /// CopyRect: copies the `dest`-sized area whose top-left is (srcX, srcY) to `dest`. Overlap-safe.
    public func copy(fromX srcX: Int, y srcY: Int, to dest: RFBRect) throws {
        try lock.withLock {
            try check(dest)
            try check(RFBRect(x: srcX, y: srcY, width: dest.width, height: dest.height))
            if dest.isEmpty { return }
            _generation &+= 1
            let w = _width
            storage.withUnsafeMutableBytes { buf in
                let p = buf.bindMemory(to: UInt8.self).baseAddress!
                let rows: [Int] = srcY < dest.y ? Array((0..<dest.height).reversed()) : Array(0..<dest.height)
                for row in rows {
                    memmove(p + ((dest.y + row) * w + dest.x) * 4,
                            p + ((srcY + row) * w + srcX) * 4,
                            dest.width * 4)
                }
            }
        }
    }

    /// (blue, green, red) of one pixel; for tests.
    public func pixel(x: Int, y: Int) -> (blue: UInt8, green: UInt8, red: UInt8) {
        lock.withLock {
            guard x >= 0, y >= 0, x < _width, y < _height else { return (0, 0, 0) }
            let i = (y * _width + x) * 4
            return (storage[i], storage[i + 1], storage[i + 2])
        }
    }

    /// Copy of a sub-rectangle as tightly packed B,G,R,A bytes.
    public func copyPixels(_ rect: RFBRect) throws -> [UInt8] {
        try lock.withLock {
            try check(rect)
            var out = [UInt8](repeating: 0, count: rect.width * rect.height * 4)
            if rect.isEmpty { return out }
            let w = _width
            storage.withUnsafeBytes { src in
                out.withUnsafeMutableBytes { dst in
                    for row in 0..<rect.height {
                        memcpy(dst.baseAddress! + row * rect.width * 4,
                               src.baseAddress! + ((rect.y + row) * w + rect.x) * 4,
                               rect.width * 4)
                    }
                }
            }
            return out
        }
    }

    /// Snapshot as a CGImage (copies the pixels). Returns nil for an empty framebuffer.
    public func makeCGImage() -> CGImage? {
        let (data, w, h): (Data, Int, Int) = lock.withLock { (Data(storage), _width, _height) }
        guard w > 0, h > 0, let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
