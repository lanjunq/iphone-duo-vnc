import Foundation
import RFBBase

/// ZRLE (16), RFC 6143 §7.7.6. u32 length + zlib data (one persistent stream per connection) of the
/// rectangle's 64x64 tiles. CPIXEL = 3 bytes B,G,R for `bgrx8888`. Per tile the smallest of raw (0),
/// solid (1), packed palette (2...16), plain RLE (128) and palette RLE (130...255) is chosen.
public final class MockZRLEEncoder: MockRectEncoder {
    public let encoding = RFBEncoding.zrle
    private let stream: DeflateStream

    /// Forces one tile subencoding family where it is valid for the tile (for decoder tests);
    /// tiles where it is not valid use the automatic choice.
    public enum ForcedMode: Sendable { case raw, solid, packedPalette, plainRLE, paletteRLE }
    public var forcedMode: ForcedMode?

    /// `level` is the zlib level 0...9, fixed for the life of the stream.
    public init(level: Int = 6, forcedMode: ForcedMode? = nil) {
        stream = DeflateStream(level: level)
        self.forcedMode = forcedMode
    }

    public func encode(_ rect: RFBRect, from framebuffer: Framebuffer) throws -> [MockEncodedRect] {
        let block = try PixelBlock(framebuffer: framebuffer, rect: rect)
        var raw = [UInt8]()
        raw.reserveCapacity(rect.width * rect.height)
        var ty = 0
        while ty < rect.height {
            let th = min(64, rect.height - ty)
            var tx = 0
            while tx < rect.width {
                let tw = min(64, rect.width - tx)
                encodeTile(block.sub(x: tx, y: ty, width: tw, height: th), into: &raw)
                tx += tw
            }
            ty += th
        }
        let z = try stream.compress(raw)
        var b = ByteBuilder(capacity: z.count + 4)
        b.u32(UInt32(z.count))
        b.bytes(z)
        return [MockEncodedRect(rect: rect, encoding: encoding, payload: b.data)]
    }

    /// Bytes needed for a run length (length-1 as 255,255,...,rest).
    @inline(__always) static func runLengthBytes(_ len: Int) -> Int { (len - 1) / 255 + 1 }

    static func appendRunLength(_ len: Int, to out: inout [UInt8]) {
        var rem = len - 1
        while rem >= 255 { out.append(255); rem -= 255 }
        out.append(UInt8(rem))
    }

    func encodeTile(_ t: PixelBlock, into out: inout [UInt8]) {
        let n = t.px.count
        let palette = t.palette(limit: 127)
        // Runs in row-major order (runs may cross rows within a tile).
        var runs = [(color: UInt32, len: Int)]()
        var i = 0
        while i < n {
            let c = t.px[i]
            var j = i + 1
            while j < n && t.px[j] == c { j += 1 }
            runs.append((c, j - i))
            i = j
        }

        let rawSize = 1 + 3 * n
        var best = (kind: ForcedMode.raw, size: rawSize)
        func consider(_ k: ForcedMode, _ s: Int) {
            if let f = forcedMode {
                if k == f { best = (k, s) } else if best.kind != f && s < best.size { best = (k, s) }
            } else if s < best.size { best = (k, s) }
        }
        if let p = palette, p.count == 1 { consider(.solid, 4) }
        if let p = palette, p.count >= 2 && p.count <= 16 {
            let bits = p.count == 2 ? 1 : (p.count <= 4 ? 2 : 4)
            consider(.packedPalette, 1 + 3 * p.count + (t.width * bits + 7) / 8 * t.height)
        }
        var plain = 1
        for r in runs { plain += 3 + Self.runLengthBytes(r.len) }
        consider(.plainRLE, plain)
        if let p = palette, p.count >= 2 {
            var s = 1 + 3 * p.count
            for r in runs { s += r.len == 1 ? 1 : 1 + Self.runLengthBytes(r.len) }
            consider(.paletteRLE, s)
        }
        if forcedMode == .raw { best = (.raw, rawSize) }

        switch best.kind {
        case .raw:
            out.append(0)
            for v in t.px { appendCPIXEL(v, to: &out) }
        case .solid:
            out.append(1)
            appendCPIXEL(t.px[0], to: &out)
        case .packedPalette:
            let p = palette!
            out.append(UInt8(p.count))
            for v in p { appendCPIXEL(v, to: &out) }
            var index = [UInt32: UInt8]()
            for (k, v) in p.enumerated() { index[v] = UInt8(k) }
            let bits = p.count == 2 ? 1 : (p.count <= 4 ? 2 : 4)
            for y in 0..<t.height {
                var byte: UInt8 = 0
                var used = 0
                for x in 0..<t.width {
                    byte |= index[t.px[y * t.width + x]]! << UInt8(8 - bits - used)
                    used += bits
                    if used == 8 { out.append(byte); byte = 0; used = 0 }
                }
                if used > 0 { out.append(byte) }
            }
        case .plainRLE:
            out.append(128)
            for r in runs {
                appendCPIXEL(r.color, to: &out)
                Self.appendRunLength(r.len, to: &out)
            }
        case .paletteRLE:
            let p = palette!
            out.append(UInt8(128 + p.count))
            for v in p { appendCPIXEL(v, to: &out) }
            var index = [UInt32: UInt8]()
            for (k, v) in p.enumerated() { index[v] = UInt8(k) }
            for r in runs {
                let idx = index[r.color]!
                if r.len == 1 {
                    out.append(idx)
                } else {
                    out.append(idx | 0x80)
                    Self.appendRunLength(r.len, to: &out)
                }
            }
        }
    }
}
