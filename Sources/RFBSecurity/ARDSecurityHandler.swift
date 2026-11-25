// Apple Remote Desktop Diffie-Hellman authentication (RFB security type 30).
//
// Scheme as implemented in RoyalVNCKit (Sources/RoyalVNCKit/Protocol/SecurityTypes/AppleRemoteDesktop/).
// Copyright (c) 2025 Royal Apps. MIT License. Reimplemented here without dependencies (own big-integer
// modexp); see THIRD_PARTY_NOTICES.md. Wire format per rfbproto.rst "Diffie-Hellman Authentication".
import Foundation
import RFBBase

/// Security type 30: Diffie-Hellman key agreement, MD5(shared secret) as an AES-128 key, and the
/// macOS username/password sent AES-128-ECB encrypted.
///
/// Wire exchange after the client's selection byte (30):
/// 1. Server → `u16 generator`, `u16 keyLength`, `prime[keyLength]`, `serverPublic[keyLength]`.
/// 2. Client → AES-128-ECB(MD5(shared), user[64] ‖ pass[64]) (128 bytes; each field UTF-8, NUL,
///    random filler), then `clientPublic[keyLength]` (big-endian, left-padded).
/// 3. Server → standard SecurityResult, so this returns `.readSecurityResult`.
///
/// The shared secret is hashed as exactly `keyLength` big-endian bytes (left zero-padded).
public struct ARDSecurityHandler: SecurityHandler {
    public init() {}
    public var securityType: UInt8 { 30 }

    /// Upper bound on the DH key size we accept (4096-bit); macOS uses 128 bytes.
    static let maxKeyLength = 512
    static let fieldSize = 64

    public func canHandle(_ credential: RFBCredential) -> Bool {
        if case .macAccount = credential { return true }
        return false
    }

    public func authenticate(reader: RFBReader, stream: ByteStream, credential: RFBCredential,
                             context: SecurityContext) async throws -> SecurityOutcome {
        guard case .macAccount(let username, let password) = credential else {
            throw RFBError.noUsableSecurityType(offered: [securityType])
        }
        try AppleRSASecurityHandler.validate(username: username, password: password)

        let generator = try await reader.u16()
        let keyLength = Int(try await reader.u16())
        guard keyLength >= 1, keyLength <= Self.maxKeyLength else {
            throw RFBError.protocolViolation("ARD: unsupported DH key length \(keyLength)")
        }
        let prime = try await reader.bytes(keyLength)
        let serverPublic = try await reader.bytes(keyLength)

        let response = try Self.makeResponse(generator: generator, prime: prime, serverPublic: serverPublic,
                                             username: username, password: password)
        try await stream.write(Data(response))
        return .readSecurityResult
    }

    /// Computes the 128 + keyLength byte client response. `privateKey` / `padding` are injectable for tests.
    static func makeResponse(generator: UInt16, prime: [UInt8], serverPublic: [UInt8],
                             username: String, password: String,
                             privateKey suppliedPrivate: [UInt8]? = nil,
                             padding suppliedPadding: [UInt8]? = nil) throws -> [UInt8] {
        let keyLength = prime.count
        guard keyLength >= 1, serverPublic.count == keyLength else {
            throw RFBError.protocolViolation("ARD: key length mismatch")
        }
        guard let modulus = MontgomeryModulus(bigEndian: prime) else {
            throw RFBError.protocolViolation("ARD: invalid DH prime (even or too small)")
        }
        // Require 1 < g < p-1 and 1 < serverPublic < p-1 (rejects degenerate keys like 0, 1, p-1).
        let pMinus1 = try subtractSmall(prime, 1)
        let g: [UInt8] = [UInt8(generator >> 8), UInt8(generator & 0xff)]
        guard greater(g, [1]), less(g, pMinus1) else {
            throw RFBError.protocolViolation("ARD: invalid DH generator \(generator)")
        }
        guard greater(serverPublic, [1]), less(serverPublic, pMinus1) else {
            throw RFBError.protocolViolation("ARD: invalid server public value")
        }

        var priv = try suppliedPrivate ?? randomPrivateKey(below: prime)
        defer { CryptoSupport.wipe(&priv) }
        guard let clientPublic = modulus.power(base: g, exponent: priv, width: keyLength),
              var shared = modulus.power(base: serverPublic, exponent: priv, width: keyLength) else {
            throw RFBError.cryptoFailed("ARD: modular exponentiation failed")
        }
        defer { CryptoSupport.wipe(&shared) }
        var aesKey = CryptoSupport.md5(shared)
        defer { CryptoSupport.wipe(&aesKey) }

        let padding = try suppliedPadding ?? CryptoSupport.randomBytes(2 * fieldSize)
        guard padding.count == 2 * fieldSize else { throw RFBError.cryptoFailed("padding must be 128 bytes") }
        var plain = try packCString(username, fieldSize: fieldSize, filler: padding[0..<fieldSize], what: "username")
        plain += try packCString(password, fieldSize: fieldSize, filler: padding[fieldSize..<(2 * fieldSize)],
                                 what: "password")
        defer { CryptoSupport.wipe(&plain) }
        let cipher = try CryptoSupport.aes128ECB(plain, key: aesKey, encrypt: true)
        return cipher + clientPublic
    }

    /// Uniform-ish random exponent in [2, p): random bytes masked to bitlen(p)-1 bits, retried if < 2.
    static func randomPrivateKey(below prime: [UInt8]) throws -> [UInt8] {
        guard let top = prime.firstIndex(where: { $0 != 0 }) else { throw RFBError.cryptoFailed("zero prime") }
        let bits = (prime.count - top) * 8 - prime[top].leadingZeroBitCount
        let usable = bits - 1
        guard usable >= 2 else { throw RFBError.protocolViolation("ARD: DH prime too small") }
        let byteCount = (usable + 7) / 8
        for _ in 0..<64 {
            var r = try CryptoSupport.randomBytes(byteCount)
            let extra = byteCount * 8 - usable
            if extra > 0 { r[0] &= UInt8(0xff >> extra) }
            if greater(r, [1]) { return r }
        }
        throw RFBError.cryptoFailed("ARD: could not generate a private key")
    }

    // Big-endian byte-string comparisons (leading zeros ignored).
    static func compareBE(_ a: [UInt8], _ b: [UInt8]) -> Int {
        let a2 = a.drop(while: { $0 == 0 }), b2 = b.drop(while: { $0 == 0 })
        if a2.count != b2.count { return a2.count < b2.count ? -1 : 1 }
        for (x, y) in zip(a2, b2) where x != y { return x < y ? -1 : 1 }
        return 0
    }
    static func less(_ a: [UInt8], _ b: [UInt8]) -> Bool { compareBE(a, b) < 0 }
    static func greater(_ a: [UInt8], _ b: [UInt8]) -> Bool { compareBE(a, b) > 0 }

    static func subtractSmall(_ a: [UInt8], _ v: UInt8) throws -> [UInt8] {
        var out = a
        var borrow = Int(v)
        var i = out.count - 1
        while borrow > 0 && i >= 0 {
            let d = Int(out[i]) - borrow
            if d < 0 { out[i] = UInt8(d + 256); borrow = 1 } else { out[i] = UInt8(d); borrow = 0 }
            i -= 1
        }
        guard borrow == 0 else { throw RFBError.protocolViolation("ARD: prime underflow") }
        return out
    }
}
