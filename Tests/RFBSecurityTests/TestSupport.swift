import Foundation
import RFBBase
import Security
@testable import RFBSecurity

func hex(_ s: String) -> [UInt8] {
    var out = [UInt8]()
    var it = s.makeIterator()
    while let a = it.next(), let b = it.next() { out.append(UInt8(String([a, b]), radix: 16)!) }
    return out
}

func hexString(_ b: some Sequence<UInt8>) -> String { b.map { String(format: "%02x", $0) }.joined() }

/// Reads exactly n bytes from a raw stream (test-side "server").
func readExactly(_ s: ByteStream, _ n: Int) async throws -> [UInt8] {
    var out = [UInt8]()
    while out.count < n { out += Array(try await s.read(maxLength: n - out.count)) }
    return out
}

func u32be(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }

func derTLV(_ tag: UInt8, _ value: [UInt8]) -> [UInt8] {
    var out = [tag]
    if value.count < 0x80 {
        out.append(UInt8(value.count))
    } else if value.count < 0x100 {
        out += [0x81, UInt8(value.count)]
    } else {
        out += [0x82, UInt8(value.count >> 8), UInt8(value.count & 0xff)]
    }
    return out + value
}

/// Wraps a PKCS#1 RSAPublicKey in a SubjectPublicKeyInfo (rsaEncryption, NULL params).
func spki(wrapping pkcs1: [UInt8]) -> [UInt8] {
    let alg = derTLV(0x30, derTLV(0x06, [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01]) + [0x05, 0x00])
    return derTLV(0x30, alg + derTLV(0x03, [0] + pkcs1))
}

struct TestRSAKey {
    let privateKey: SecKey
    let spkiDER: [UInt8]

    init(bits: Int = 2048) throws {
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                    kSecAttrKeySizeInBits as String: bits]
        var error: Unmanaged<CFError>?
        guard let priv = SecKeyCreateRandomKey(attrs as CFDictionary, &error),
              let pub = SecKeyCopyPublicKey(priv),
              let pkcs1 = SecKeyCopyExternalRepresentation(pub, &error) as Data? else {
            throw RFBError.cryptoFailed("test key generation failed")
        }
        privateKey = priv
        spkiDER = spki(wrapping: Array(pkcs1))
    }

    func decrypt(_ data: [UInt8]) throws -> [UInt8] {
        var error: Unmanaged<CFError>?
        guard let out = SecKeyCreateDecryptedData(privateKey, .rsaEncryptionPKCS1, Data(data) as CFData, &error) as Data? else {
            throw RFBError.cryptoFailed("test RSA decrypt failed")
        }
        return Array(out)
    }
}

func cString(_ field: ArraySlice<UInt8>) -> String {
    String(decoding: field.prefix { $0 != 0 }, as: UTF8.self)
}

/// Collects values from @Sendable closures.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// RFC 2409 Oakley group 2 (1024-bit MODP) prime.
let oakley2Hex = "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE65381FFFFFFFFFFFFFFFF"

/// The SPKI the real macOS 27.0.1 server at 127.0.0.1:5900 sent in its type 33 key packet (public key).
let realServerSPKIHex = "30820122300d06092a864886f70d01010105000382010f003082010a0282010100d2fef346018111d7b0bd461e8c815a5c2e904c76daea750d1932b77fa859bfc563763e8d6a7d7f278807e757f13fbc36c6a0c178d6ea8d744fe37c06d49018823f31a0f7aa4b544ae3403610ad212e0500a8f171ad429a013335ec1ec3728eb7835aae8aa6ee1b357c4c16bed37dfa525b9f48933fb30c801bfcc7b89cc952f0ee0b57f5b51f3feb9a81f1b275f83b7b56d9c73bd3ddbe25b126a1e3c3be96cebfd871b89df0eab3a94ab2a7b35e002914849ff800235b3912bc7cc205d1e0e491cf029278798f891b5318fe2a1e43defc6c9f311b3de0e4210335e7b7ddc3a1ff6bd3b6203601403a9c3289b942df8440f0d5b22e086fb9a1d8d4174bba27f50203010001"
