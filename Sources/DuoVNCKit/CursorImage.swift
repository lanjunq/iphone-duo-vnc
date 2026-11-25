import Foundation

/// Converts cursor pixels from the Cursor pseudo-encoding (B,G,R,A, straight alpha 0/255) into
/// premultiplied B,G,R,A, which is what `CGImage` with `premultipliedFirst | byteOrder32Little` expects.
public enum CursorImage {
    /// Returns nil if `bgra.count != width * height * 4` or the size is empty/absurd.
    public static func premultipliedBGRA(_ bgra: Data, width: Int, height: Int) -> Data? {
        guard width > 0, height > 0, width <= 1024, height <= 1024, bgra.count == width * height * 4 else { return nil }
        var out = Data(bgra)
        out.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) in
            let p = buf.bindMemory(to: UInt8.self)
            var i = 0
            while i + 3 < p.count {
                let a = UInt16(p[i + 3])
                if a == 0 {
                    p[i] = 0; p[i + 1] = 0; p[i + 2] = 0
                } else if a < 255 {
                    p[i] = UInt8((UInt16(p[i]) * a + 127) / 255)
                    p[i + 1] = UInt8((UInt16(p[i + 1]) * a + 127) / 255)
                    p[i + 2] = UInt8((UInt16(p[i + 2]) * a + 127) / 255)
                }
                i += 4
            }
        }
        return out
    }

    /// True when the cursor is invisible (empty or fully transparent).
    public static func isInvisible(_ bgra: Data, width: Int, height: Int) -> Bool {
        guard width > 0, height > 0, bgra.count >= width * height * 4 else { return true }
        var i = 3
        while i < bgra.count {
            if bgra[bgra.startIndex + i] != 0 { return false }
            i += 4
        }
        return true
    }
}
