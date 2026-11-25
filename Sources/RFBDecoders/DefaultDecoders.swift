import Foundation
import RFBBase

/// The standard decoder set.
public enum DefaultDecoders {
    /// Encodings in preference order: CopyRect, Tight, ZRLE, Zlib, Hextile, RRE, Raw.
    public static let preferenceOrder: [Int32] = [
        RFBEncoding.copyRect, RFBEncoding.tight, RFBEncoding.zrle, RFBEncoding.zlib,
        RFBEncoding.hextile, RFBEncoding.rre, RFBEncoding.raw,
    ]

    /// A fresh decoder for one encoding number, or nil if unsupported.
    public static func makeDecoder(for encoding: Int32) -> (any RectDecoder)? {
        switch encoding {
        case RFBEncoding.raw: return RawDecoder()
        case RFBEncoding.copyRect: return CopyRectDecoder()
        case RFBEncoding.rre: return RREDecoder()
        case RFBEncoding.hextile: return HextileDecoder()
        case RFBEncoding.zlib: return ZlibDecoder()
        case RFBEncoding.tight: return TightDecoder()
        case RFBEncoding.zrle: return ZRLEDecoder()
        default: return nil
        }
    }

    /// Fresh instances of every decoder, in `preferenceOrder`. Call once per connection.
    public static let factory: RectDecoderFactory = {
        preferenceOrder.compactMap { makeDecoder(for: $0) }
    }

    /// Only the listed encodings, in the order given (that order is the advertised preference).
    /// Unsupported numbers and duplicates are ignored. Raw is always appended if missing.
    public static func factory(only encodings: [Int32]) -> RectDecoderFactory {
        var seen = Set<Int32>()
        var list = encodings.filter { makeDecoder(for: $0) != nil && seen.insert($0).inserted }
        // Raw is mandatory (RFC 6143 §7.7.1): a server falls back to it when it supports none of the
        // advertised encodings. macOS Screen Sharing does exactly that for Tight-only or Hextile-only
        // lists (verified 2026-11-24 on macOS 27.0.1), so Raw is always available as the last resort.
        if !list.contains(RFBEncoding.raw) { list.append(RFBEncoding.raw) }
        let final = list
        return { final.compactMap { makeDecoder(for: $0) } }
    }
}
