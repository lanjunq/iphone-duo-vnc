import Foundation
import RFBBase

/// Builders for client-to-server messages (RFC 6143 §7.5). All multi-byte fields big-endian.
enum ClientMessages {
    static func clampU16(_ v: Int) -> UInt16 { UInt16(clamping: v) }

    /// SetPixelFormat (type 0): 1 type + 3 padding + 16 PIXEL_FORMAT = 20 bytes.
    static func setPixelFormat(_ pf: PixelFormat) -> Data {
        var b = ByteBuilder(capacity: 20)
        b.u8(0); b.zeros(3)
        b.bytes(pf.encoded())
        return b.data
    }

    /// SetEncodings (type 2): 1 type + 1 padding + u16 count + count * s32.
    static func setEncodings(_ encodings: [Int32]) -> Data {
        let list = Array(encodings.prefix(Int(UInt16.max)))
        var b = ByteBuilder(capacity: 4 + list.count * 4)
        b.u8(2); b.u8(0)
        b.u16(UInt16(list.count))
        for e in list { b.i32(e) }
        return b.data
    }

    /// FramebufferUpdateRequest (type 3): 10 bytes.
    static func updateRequest(incremental: Bool, x: Int, y: Int, width: Int, height: Int) -> Data {
        var b = ByteBuilder(capacity: 10)
        b.u8(3); b.u8(incremental ? 1 : 0)
        b.u16(clampU16(x)); b.u16(clampU16(y)); b.u16(clampU16(width)); b.u16(clampU16(height))
        return b.data
    }

    /// KeyEvent (type 4): 1 type + u8 down + 2 padding + u32 keysym = 8 bytes.
    static func keyEvent(keysym: UInt32, down: Bool) -> Data {
        var b = ByteBuilder(capacity: 8)
        b.u8(4); b.u8(down ? 1 : 0); b.zeros(2)
        b.u32(keysym)
        return b.data
    }

    /// PointerEvent (type 5): 1 type + u8 button mask + u16 x + u16 y = 6 bytes.
    static func pointerEvent(x: Int, y: Int, buttons: RFBButtonMask) -> Data {
        var b = ByteBuilder(capacity: 6)
        b.u8(5); b.u8(buttons.rawValue)
        b.u16(clampU16(x)); b.u16(clampU16(y))
        return b.data
    }

    /// ClientCutText (type 6): 1 type + 3 padding + u32 length + Latin-1 text.
    /// Characters outside Latin-1 are replaced by "?" (RFC 6143 §7.5.6 mandates ISO 8859-1).
    static func clientCutText(_ text: String) -> Data {
        var latin1 = [UInt8]()
        latin1.reserveCapacity(text.unicodeScalars.count)
        for s in text.unicodeScalars {
            latin1.append(s.value <= 0xff ? UInt8(s.value) : 0x3f)
        }
        var b = ByteBuilder(capacity: 8 + latin1.count)
        b.u8(6); b.zeros(3)
        b.u32(UInt32(latin1.count))
        b.bytes(latin1)
        return b.data
    }
}
