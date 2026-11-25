// Apple RSA/AES macOS-account authentication (RFB security type 33).
//
// Ported from TailVNC (TailVNC/Core/AppleRSAAuthentication.swift and the type 33 framing in
// TailVNC/Core/RFBClient.swift). Copyright (c) 2026 TailVNC contributors. MIT License.
// Adapted to the RFBBase SecurityHandler contract; see THIRD_PARTY_NOTICES.md.
import Foundation
import RFBBase
import Security
import CryptoKit

/// Security type 33: Apple's RSA + AES-128 macOS account login (what macOS Screen Sharing uses for
/// "user name and password" when the client speaks `RFB 003.889`).
///
/// Wire exchange after the client's selection byte (33), verified against macOS 27.0.1:
/// 1. Client → key request (14 bytes): `u32 10`, `01 00`, `"RSA1"`, `00 00 00 00`.
/// 2. Server → `u32 len`, then `len` bytes: `00 01`, `u32 keyLen`, `keyLen` bytes of DER
///    SubjectPublicKeyInfo (RSA-2048 on macOS), then trailing byte(s) (one `00` observed).
/// 3. `context.hostKeyVerifier(SPKI)` — false → `RFBError.hostKeyRejected`, nothing sent.
/// 4. Client → `u32 len`, `01 00`, `"RSA1"`, `00 01`, AES-128-ECB(random key, user[64] ‖ pass[64])
///    (each field: UTF-8, NUL, random filler), `00 01`, RSA-PKCS#1-v1.5(server key, AES key).
/// 5. Server → 4-byte acknowledgement `00 00 00 00`, then a u32 result: 0 = OK, non-zero = failed.
///    On failure macOS 27.0.1 sends NO reason string (observed: `00000000 00000001`, then silence),
///    so a client that reads an RFB 3.8 reason string after it would block.
///
/// The handler therefore consumes the acknowledgement AND the result itself: it returns `.completed`
/// on success and throws `RFBError.authenticationFailed(nil)` on failure.
///
/// IMPORTANT (verified on macOS 27.0.1): the server only accepts the key request when it arrives in the
/// SAME write as the selection byte 33. Writing `[33]` and then the key request separately makes the
/// server close the connection, even with a 1 ms gap. A client must therefore use the
/// `CoalescedSelectionSecurityHandler` path: write `[33] + selectionPayload(for:)` as one write, then
/// call `authenticateAfterSelectionPayload`. Plain `authenticate` (which sends the key request itself)
/// only works where the transport happens to coalesce the two writes (e.g. in-memory pipes).
public struct AppleRSASecurityHandler: CoalescedSelectionSecurityHandler {
    public init() {}
    public var securityType: UInt8 { 33 }

    /// Largest key packet we accept from the server (real server: 301 bytes).
    static let maxKeyPacketLength = 16 * 1024
    /// Username and password fields are 64 bytes each including the NUL terminator.
    static let fieldSize = 64

    public func canHandle(_ credential: RFBCredential) -> Bool {
        if case .macAccount = credential { return true }
        return false
    }

    /// The 14-byte key request, to be appended to the selection byte in the same write.
    /// Throws (before anything is sent) when the credential cannot be used with this scheme.
    public func selectionPayload(for credential: RFBCredential) throws -> Data {
        guard case .macAccount(let username, let password) = credential else {
            throw RFBError.noUsableSecurityType(offered: [securityType])
        }
        try Self.validate(username: username, password: password)
        return Data(Self.keyRequest)
    }

    /// Fallback path: sends the key request as its own write. See the type's doc comment: the real
    /// macOS server rejects this unless the transport coalesces it with the selection byte.
    public func authenticate(reader: RFBReader, stream: ByteStream, credential: RFBCredential,
                             context: SecurityContext) async throws -> SecurityOutcome {
        let payload = try selectionPayload(for: credential)
        try await stream.write(payload)
        return try await authenticateAfterSelectionPayload(reader: reader, stream: stream, credential: credential,
                                                           context: context)
    }

    /// Continues after the client wrote `[33] + selectionPayload(for:)` in one write.
    public func authenticateAfterSelectionPayload(reader: RFBReader, stream: ByteStream, credential: RFBCredential,
                                                  context: SecurityContext) async throws -> SecurityOutcome {
        guard case .macAccount(let username, let password) = credential else {
            throw RFBError.noUsableSecurityType(offered: [securityType])
        }
        try Self.validate(username: username, password: password)

        let packetLength = Int(try await reader.u32())
        guard packetLength >= 6, packetLength <= Self.maxKeyPacketLength else {
            throw RFBError.protocolViolation("Apple RSA: bad key packet length \(packetLength)")
        }
        let packet = try await reader.bytes(packetLength)
        let keyDER = try Self.parseKeyPacket(packet)

        if let verify = context.hostKeyVerifier {
            guard await verify(Data(keyDER)) else { throw RFBError.hostKeyRejected }
        }

        let response = try Self.makeResponse(publicKeyDER: keyDER, username: username, password: password)
        try await stream.write(Data(response))

        let ack = try await reader.bytes(4)
        guard ack == [0, 0, 0, 0] else {
            throw RFBError.protocolViolation(
                "Apple RSA: unexpected acknowledgement \(ack.map { String(format: "%02x", $0) }.joined())")
        }
        let result = try await reader.u32()
        guard result == 0 else { throw RFBError.authenticationFailed(nil) }
        return .completed
    }

    // MARK: - Wire pieces (internal for tests)

    /// `u32 10`, `01 00`, `"RSA1"`, `00 00 00 00`.
    static let keyRequest: [UInt8] = [0, 0, 0, 10, 1, 0] + Array("RSA1".utf8) + [0, 0, 0, 0]

    static func validate(username: String, password: String) throws {
        guard username.utf8.count < fieldSize else {
            throw RFBError.authenticationFailed("username is too long (max \(fieldSize - 1) UTF-8 bytes)")
        }
        guard password.utf8.count < fieldSize else {
            throw RFBError.authenticationFailed("password is too long (max \(fieldSize - 1) UTF-8 bytes)")
        }
        guard !username.utf8.contains(0), !password.utf8.contains(0) else {
            throw RFBError.authenticationFailed("username or password contains a NUL character")
        }
    }

    /// Extracts the DER SubjectPublicKeyInfo from the server's key packet (the bytes after the u32 length).
    static func parseKeyPacket(_ packet: [UInt8]) throws -> [UInt8] {
        guard packet.count >= 6 else { throw RFBError.protocolViolation("Apple RSA: key packet too short") }
        let keyLength = Int(packet[2]) << 24 | Int(packet[3]) << 16 | Int(packet[4]) << 8 | Int(packet[5])
        guard keyLength > 0, keyLength <= packet.count - 6 else {
            throw RFBError.protocolViolation("Apple RSA: key length \(keyLength) exceeds packet (\(packet.count))")
        }
        return Array(packet[6..<(6 + keyLength)])
    }

    /// Builds the full credential response including its u32 length prefix.
    /// `aesKey` / `padding` are injectable for tests only; production uses fresh random bytes.
    static func makeResponse(publicKeyDER: [UInt8], username: String, password: String,
                             aesKey suppliedKey: [UInt8]? = nil, padding suppliedPadding: [UInt8]? = nil) throws -> [UInt8] {
        try validate(username: username, password: password)
        let publicKey = try rsaPublicKey(fromSPKI: publicKeyDER)

        var aesKey = try suppliedKey ?? CryptoSupport.randomBytes(16)
        defer { CryptoSupport.wipe(&aesKey) }
        guard aesKey.count == 16 else { throw RFBError.cryptoFailed("AES key must be 16 bytes") }
        let padding = try suppliedPadding ?? CryptoSupport.randomBytes(2 * fieldSize)
        guard padding.count == 2 * fieldSize else { throw RFBError.cryptoFailed("padding must be 128 bytes") }

        var plain = try packCString(username, fieldSize: fieldSize, filler: padding[0..<fieldSize],
                                    what: "username")
        plain += try packCString(password, fieldSize: fieldSize,
                                 filler: padding[fieldSize..<(2 * fieldSize)], what: "password")
        defer { CryptoSupport.wipe(&plain) }
        let encryptedCredentials = try CryptoSupport.aes128ECB(plain, key: aesKey, encrypt: true)

        var error: Unmanaged<CFError>?
        guard let encryptedKey = SecKeyCreateEncryptedData(publicKey, .rsaEncryptionPKCS1,
                                                           Data(aesKey) as CFData, &error) as Data? else {
            let message = error?.takeRetainedValue().localizedDescription ?? "unknown error"
            throw RFBError.cryptoFailed("RSA encryption failed: \(message)")
        }

        var content: [UInt8] = [1, 0] + Array("RSA1".utf8) + [0, 1]
        content += encryptedCredentials
        content += [0, 1]
        content += Array(encryptedKey)

        var b = ByteBuilder(capacity: content.count + 4)
        b.u32(UInt32(content.count))
        b.bytes(content)
        return Array(b.data)
    }

    /// rsaEncryption OID 1.2.840.113549.1.1.1
    private static let rsaOID: [UInt8] = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01]

    static func rsaPublicKey(fromSPKI der: [UInt8]) throws -> SecKey {
        let bad = RFBError.protocolViolation("Apple RSA: server sent an invalid public key")
        var outer = DERReader(der)
        let spki = try outer.read(tag: 0x30)
        guard outer.isAtEnd else { throw bad }
        var body = DERReader(spki)
        let algorithm = try body.read(tag: 0x30)
        let bitString = try body.read(tag: 0x03)
        guard body.isAtEnd, bitString.first == 0, bitString.count > 1 else { throw bad }
        var alg = DERReader(algorithm)
        guard try alg.read(tag: 0x06) == rsaOID else { throw bad }
        let pkcs1 = Data(bitString.dropFirst())
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error) else {
            _ = error?.takeRetainedValue()
            throw bad
        }
        return key
    }

    /// Lowercase hex SHA-256 of the server's public key bytes, for trust-on-first-use storage/display.
    public static func sha256Fingerprint(of publicKeyDER: Data) -> String {
        SHA256.hash(data: publicKeyDER).map { String(format: "%02x", $0) }.joined()
    }
}

/// Minimal DER TLV reader (definite lengths up to 4 length bytes). Never traps on malformed input.
struct DERReader {
    private let bytes: [UInt8]
    private var offset = 0
    init(_ bytes: [UInt8]) { self.bytes = bytes }
    var isAtEnd: Bool { offset == bytes.count }

    mutating func read(tag: UInt8) throws -> [UInt8] {
        let bad = RFBError.protocolViolation("Apple RSA: malformed DER")
        guard offset < bytes.count, bytes[offset] == tag else { throw bad }
        offset += 1
        guard offset < bytes.count else { throw bad }
        let first = Int(bytes[offset])
        offset += 1
        var length = first
        if first & 0x80 != 0 {
            let n = first & 0x7f
            guard n >= 1, n <= 4, bytes.count - offset >= n else { throw bad }
            length = 0
            for _ in 0..<n { length = length << 8 | Int(bytes[offset]); offset += 1 }
        }
        guard length >= 0, length <= bytes.count - offset else { throw bad }
        let value = Array(bytes[offset..<(offset + length)])
        offset += length
        return value
    }
}
