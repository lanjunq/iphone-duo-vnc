import Foundation
import RFBBase
import CommonCrypto
import Security
import CryptoKit

/// Small crypto helpers shared by the security handlers. All failures map to `RFBError.cryptoFailed`.
enum CryptoSupport {
    /// Cryptographically secure random bytes.
    static func randomBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0 else { throw RFBError.cryptoFailed("negative random length") }
        if count == 0 { return [] }
        var out = [UInt8](repeating: 0, count: count)
        let status = out.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw RFBError.cryptoFailed("SecRandomCopyBytes failed (\(status))") }
        return out
    }

    /// Single-pass ECB with no padding. `input.count` must be a multiple of the block size.
    static func ecb(_ input: [UInt8], key: [UInt8], algorithm: CCAlgorithm, blockSize: Int,
                    encrypt: Bool) throws -> [UInt8] {
        guard input.count % blockSize == 0 else { throw RFBError.cryptoFailed("ECB input not block aligned") }
        if input.isEmpty { return [] }
        var output = [UInt8](repeating: 0, count: input.count)
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inp in
                key.withUnsafeBytes { k in
                    CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), algorithm, CCOptions(kCCOptionECBMode),
                            k.baseAddress, key.count, nil,
                            inp.baseAddress, input.count, out.baseAddress, out.count, &moved)
                }
            }
        }
        guard status == kCCSuccess, moved == input.count else {
            throw RFBError.cryptoFailed("CCCrypt failed (\(status))")
        }
        return output
    }

    static func aes128ECB(_ input: [UInt8], key: [UInt8], encrypt: Bool = true) throws -> [UInt8] {
        guard key.count == kCCKeySizeAES128 else { throw RFBError.cryptoFailed("AES-128 key must be 16 bytes") }
        return try ecb(input, key: key, algorithm: CCAlgorithm(kCCAlgorithmAES), blockSize: kCCBlockSizeAES128,
                       encrypt: encrypt)
    }

    static func desECB(_ input: [UInt8], key: [UInt8], encrypt: Bool = true) throws -> [UInt8] {
        guard key.count == kCCKeySizeDES else { throw RFBError.cryptoFailed("DES key must be 8 bytes") }
        return try ecb(input, key: key, algorithm: CCAlgorithm(kCCAlgorithmDES), blockSize: kCCBlockSizeDES,
                       encrypt: encrypt)
    }

    static func md5(_ input: [UInt8]) -> [UInt8] {
        Array(Insecure.MD5.hash(data: input))
    }

    /// Overwrites a buffer with zeros (best effort; Swift may have made copies elsewhere).
    static func wipe(_ bytes: inout [UInt8]) {
        for i in bytes.indices { bytes[i] = 0 }
    }
}

/// Packs a credential string into a fixed-size field: UTF-8 bytes, a NUL terminator, then `filler`.
/// Throws if the UTF-8 form (plus NUL) does not fit.
func packCString(_ s: String, fieldSize: Int, filler: ArraySlice<UInt8>, what: String) throws -> [UInt8] {
    var field = Array(s.utf8)
    guard field.count < fieldSize else {
        throw RFBError.authenticationFailed("\(what) is too long (max \(fieldSize - 1) UTF-8 bytes)")
    }
    field.append(0)
    let need = fieldSize - field.count
    guard filler.count >= need else { throw RFBError.cryptoFailed("not enough padding bytes") }
    field.append(contentsOf: filler.prefix(need))
    return field
}
