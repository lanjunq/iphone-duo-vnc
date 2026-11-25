import Foundation
import RFBBase

/// Minimal fixed-width unsigned big integers for Diffie-Hellman: little-endian `UInt64` limbs and
/// Montgomery modular exponentiation for an odd modulus. Not constant time beyond what the simple
/// square-and-multiply loop gives; adequate for the client side of ARD's DH (fresh key per connection).
struct MontgomeryModulus {
    let n: [UInt64]          // modulus limbs, little-endian, n.count = k, top limb non-zero
    let k: Int
    private let nPrime: UInt64     // -n^{-1} mod 2^64
    private let r2: [UInt64]       // R^2 mod n, R = 2^(64k)

    /// Fails (nil) for an even modulus or a modulus < 3.
    init?(bigEndian bytes: [UInt8]) {
        var limbs = BigLimbs.fromBigEndian(bytes)
        while limbs.count > 1 && limbs.last == 0 { limbs.removeLast() }
        guard let low = limbs.first, low & 1 == 1, !(limbs.count == 1 && low < 3) else { return nil }
        n = limbs
        k = limbs.count
        // Newton iteration for n0^{-1} mod 2^64.
        var inv: UInt64 = 1
        for _ in 0..<6 { inv = inv &* (2 &- low &* inv) }
        nPrime = 0 &- inv
        // R^2 mod n by doubling 1, 2*64*k times, reducing each step.
        var x = [UInt64](repeating: 0, count: k)
        x[0] = 1
        for _ in 0..<(128 * k) {
            let carry = BigLimbs.shiftLeft1(&x)
            if carry != 0 || BigLimbs.compare(x, limbs) >= 0 { _ = BigLimbs.subtract(&x, limbs) }
        }
        r2 = x
    }

    /// a * b * R^{-1} mod n for a, b < n (CIOS).
    func montMul(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        var t = [UInt64](repeating: 0, count: k + 2)
        for i in 0..<k {
            var c: UInt64 = 0
            let ai = a[i]
            for j in 0..<k {
                let (hi, lo) = ai.multipliedFullWidth(by: b[j])
                let (s1, o1) = t[j].addingReportingOverflow(lo)
                let (s2, o2) = s1.addingReportingOverflow(c)
                t[j] = s2
                c = hi &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
            }
            let (sk, ok) = t[k].addingReportingOverflow(c)
            t[k] = sk
            t[k + 1] = ok ? 1 : 0

            let m = t[0] &* nPrime
            let (hi0, lo0) = m.multipliedFullWidth(by: n[0])
            let (_, o0) = t[0].addingReportingOverflow(lo0)   // low limb becomes 0 by construction
            c = hi0 &+ (o0 ? 1 : 0)
            for j in 1..<k {
                let (hi, lo) = m.multipliedFullWidth(by: n[j])
                let (s1, o1) = t[j].addingReportingOverflow(lo)
                let (s2, o2) = s1.addingReportingOverflow(c)
                t[j - 1] = s2
                c = hi &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
            }
            let (s, o) = t[k].addingReportingOverflow(c)
            t[k - 1] = s
            t[k] = t[k + 1] &+ (o ? 1 : 0)
            t[k + 1] = 0
        }
        var result = Array(t[0..<k])
        if t[k] != 0 || BigLimbs.compare(result, n) >= 0 { _ = BigLimbs.subtract(&result, n) }
        return result
    }

    /// base^exponent mod n. `base` and `exponent` are big-endian byte strings; base must be < n.
    /// Returns the result as big-endian bytes left-padded to `width` bytes (width >= byte size of n).
    func power(base: [UInt8], exponent: [UInt8], width: Int) -> [UInt8]? {
        var b = BigLimbs.fromBigEndian(base)
        while b.count > k { guard b.last == 0 else { return nil }; b.removeLast() }
        b += [UInt64](repeating: 0, count: k - b.count)
        guard BigLimbs.compare(b, n) < 0 else { return nil }
        let bm = montMul(b, r2)
        var one = [UInt64](repeating: 0, count: k)
        one[0] = 1
        var acc = montMul(one, r2)  // R mod n
        for byte in exponent {
            var bit: UInt8 = 0x80
            while bit != 0 {
                acc = montMul(acc, acc)
                if byte & bit != 0 { acc = montMul(acc, bm) }
                bit >>= 1
            }
        }
        let plain = montMul(acc, one)
        return BigLimbs.toBigEndian(plain, width: width)
    }
}

enum BigLimbs {
    static func fromBigEndian(_ bytes: [UInt8]) -> [UInt64] {
        if bytes.isEmpty { return [0] }
        var limbs = [UInt64](repeating: 0, count: (bytes.count + 7) / 8)
        for (i, byte) in bytes.reversed().enumerated() {
            limbs[i / 8] |= UInt64(byte) << UInt64((i % 8) * 8)
        }
        return limbs
    }

    /// Big-endian, left-padded (or with leading zero bytes dropped) to exactly `width` bytes;
    /// nil if the value does not fit.
    static func toBigEndian(_ limbs: [UInt64], width: Int) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: limbs.count * 8)
        for (i, limb) in limbs.enumerated() {
            for j in 0..<8 { out[out.count - 1 - (i * 8 + j)] = UInt8(truncatingIfNeeded: limb >> UInt64(j * 8)) }
        }
        if out.count > width {
            guard out.prefix(out.count - width).allSatisfy({ $0 == 0 }) else { return nil }
            return Array(out.suffix(width))
        }
        return [UInt8](repeating: 0, count: width - out.count) + out
    }

    /// Compares equal-length limb arrays (or arrays whose extra high limbs are zero).
    static func compare(_ a: [UInt64], _ b: [UInt64]) -> Int {
        let n = max(a.count, b.count)
        var i = n - 1
        while i >= 0 {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x < y ? -1 : 1 }
            i -= 1
        }
        return 0
    }

    /// a -= b (mod 2^(64*a.count)); returns the borrow.
    @discardableResult
    static func subtract(_ a: inout [UInt64], _ b: [UInt64]) -> UInt64 {
        var borrow: UInt64 = 0
        for i in 0..<a.count {
            let bi = i < b.count ? b[i] : 0
            let (d1, o1) = a[i].subtractingReportingOverflow(bi)
            let (d2, o2) = d1.subtractingReportingOverflow(borrow)
            a[i] = d2
            borrow = (o1 || o2) ? 1 : 0
        }
        return borrow
    }

    /// a <<= 1; returns the bit shifted out.
    static func shiftLeft1(_ a: inout [UInt64]) -> UInt64 {
        var carry: UInt64 = 0
        for i in 0..<a.count {
            let next = a[i] >> 63
            a[i] = (a[i] << 1) | carry
            carry = next
        }
        return carry
    }

    static func isZero(_ bytes: [UInt8]) -> Bool { bytes.allSatisfy { $0 == 0 } }
}
