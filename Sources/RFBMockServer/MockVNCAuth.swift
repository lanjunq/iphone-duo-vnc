import Foundation
import CommonCrypto
import RFBBase

/// Classic VNC authentication (security type 2) as the server checks it.
public enum MockVNCAuth {
    /// The DES key VNC derives from a password: first 8 UTF-8 bytes, zero padded, each byte bit-reversed.
    public static func desKey(password: String) -> [UInt8] {
        var key = Array(password.utf8.prefix(8))
        while key.count < 8 { key.append(0) }
        return key.map(reverseBits)
    }

    /// The 16-byte response a correct client sends for `challenge` (DES-ECB of each 8-byte half).
    public static func response(challenge: [UInt8], password: String) throws -> [UInt8] {
        guard challenge.count == 16 else { throw RFBError.cryptoFailed("VNC challenge must be 16 bytes") }
        return try desECBEncrypt(key: desKey(password: password), data: challenge)
    }

    /// Single-DES ECB encryption without padding (`data.count` must be a multiple of 8).
    public static func desECBEncrypt(key: [UInt8], data: [UInt8]) throws -> [UInt8] {
        guard key.count == kCCKeySizeDES, data.count % 8 == 0 else {
            throw RFBError.cryptoFailed("bad DES key/data size")
        }
        var out = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmDES), CCOptions(kCCOptionECBMode),
                             key, key.count, nil, data, data.count, &out, out.count, &moved)
        guard status == CCCryptorStatus(kCCSuccess), moved == data.count else {
            throw RFBError.cryptoFailed("CCCrypt DES failed (\(status))")
        }
        return out
    }

    static func reverseBits(_ b: UInt8) -> UInt8 {
        var v = b, r: UInt8 = 0
        for _ in 0..<8 { r = (r << 1) | (v & 1); v >>= 1 }
        return r
    }

    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}
