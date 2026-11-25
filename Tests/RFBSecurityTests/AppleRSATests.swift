import Foundation
import RFBBase
import Testing
@testable import RFBSecurity

/// Server side of type 33 as macOS 27 frames it: key packet = 00 01, u32 keyLen, SPKI, 00.
func keyPacket(_ spki: [UInt8], trailer: [UInt8] = [0]) -> [UInt8] {
    var body: [UInt8] = [0, 1]
    body += u32be(spki.count)
    body += spki
    body += trailer
    return u32be(body.count) + body
}

@Test func keyRequestBytes() {
    let expected: [UInt8] = [0, 0, 0, 10, 1, 0, 0x52, 0x53, 0x41, 0x31, 0, 0, 0, 0]
    #expect(AppleRSASecurityHandler.keyRequest == expected)
}

@Test func parsesRealServerKey() throws {
    // The exact SPKI the real macOS server sent; must load as an RSA public key.
    let der = hex(realServerSPKIHex)
    let key = try AppleRSASecurityHandler.rsaPublicKey(fromSPKI: der)
    let attrs = SecKeyCopyAttributes(key) as? [String: Any]
    #expect((attrs?[kSecAttrKeySizeInBits as String] as? Int) == 2048)
    // And the real packet framing (301 bytes after the length) parses back to it.
    let packet = Array(keyPacket(der).dropFirst(4))
    #expect(packet.count == 301)
    #expect(try AppleRSASecurityHandler.parseKeyPacket(packet) == der)
}

@Test func appleRSARoundTrip() async throws {
    let rsa = try TestRSAKey()
    let (client, server) = PipeByteStream.makePair()
    let seenKey = Box<Data?>(nil)
    let ctx = SecurityContext(serverVersion: "RFB 003.889") { key in
        seenKey.value = key
        return true
    }
    let username = "vnctest"
    let password = "pä$$ wörd ✓ 123"

    let serverTask = Task { () throws -> [UInt8] in
        let request = try await readExactly(server, 14)
        #expect(request == AppleRSASecurityHandler.keyRequest)
        try await server.write(Data(keyPacket(rsa.spkiDER)))
        let len = try await readExactly(server, 4)
        let n = Int(len[0]) << 24 | Int(len[1]) << 16 | Int(len[2]) << 8 | Int(len[3])
        let body = try await readExactly(server, n)
        try await server.write(Data([0, 0, 0, 0, 0, 0, 0, 0]))
        return body
    }

    let outcome = try await AppleRSASecurityHandler().authenticate(
        reader: RFBReader(stream: client), stream: client,
        credential: .macAccount(username: username, password: password), context: ctx)
    #expect(outcome == .completed)
    #expect(seenKey.value == Data(rsa.spkiDER))

    let body = try await serverTask.value
    let expectedBodyLength = 394  // 8 header + 128 credentials + 2 marker + 256 RSA block
    #expect(body.count == expectedBodyLength)
    let header: [UInt8] = [1, 0, 0x52, 0x53, 0x41, 0x31, 0, 1]
    let marker: [UInt8] = [0, 1]
    #expect(Array(body[0..<8]) == header)
    #expect(Array(body[136..<138]) == marker)
    let aesKey = try rsa.decrypt(Array(body[138...]))
    #expect(aesKey.count == 16)
    let plain = try CryptoSupport.aes128ECB(Array(body[8..<136]), key: aesKey, encrypt: false)
    #expect(cString(plain[0..<64]) == username)
    #expect(cString(plain[64..<128]) == password)
    #expect(plain[username.utf8.count] == 0)
    #expect(plain[64 + password.utf8.count] == 0)
}

@Test func appleRSADeterministicResponseLayout() throws {
    let rsa = try TestRSAKey()
    let aes = Array(UInt8(1)...16)
    let pad = [UInt8](repeating: 0xee, count: 128)
    let r = try AppleRSASecurityHandler.makeResponse(publicKeyDER: rsa.spkiDER, username: "ab", password: "",
                                                     aesKey: aes, padding: pad)
    #expect(Array(r[0..<4]) == u32be(394))
    let plain = try CryptoSupport.aes128ECB(Array(r[12..<140]), key: aes, encrypt: false)
    let userField: [UInt8] = [0x61, 0x62, 0, 0xee]
    #expect(Array(plain[0..<4]) == userField)
    #expect(plain[64] == 0)
    #expect(plain[65] == 0xee)
    #expect(try rsa.decrypt(Array(r[142...])) == aes)
    // 63-byte fields are the maximum (NUL still fits); 64 is rejected.
    let max = String(repeating: "x", count: 63)
    _ = try AppleRSASecurityHandler.makeResponse(publicKeyDER: rsa.spkiDER, username: max, password: max)
    #expect(throws: RFBError.self) {
        _ = try AppleRSASecurityHandler.makeResponse(publicKeyDER: rsa.spkiDER, username: max + "x", password: "p")
    }
}

@Test func appleRSAHostKeyRejectedSendsNoCredentials() async throws {
    let rsa = try TestRSAKey()
    let (client, server) = PipeByteStream.makePair()
    try await server.write(Data(keyPacket(rsa.spkiDER)))
    let ctx = SecurityContext(serverVersion: "RFB 003.889") { _ in false }
    await #expect(throws: RFBError.hostKeyRejected) {
        _ = try await AppleRSASecurityHandler().authenticate(
            reader: RFBReader(stream: client), stream: client,
            credential: .macAccount(username: "u", password: "p"), context: ctx)
    }
    #expect(try await readExactly(server, 14) == AppleRSASecurityHandler.keyRequest)
    client.close()
    // Nothing besides the key request was written.
    await #expect(throws: RFBError.connectionClosed) { _ = try await server.read(maxLength: 1) }
}

@Test func appleRSATooLongPasswordFailsBeforeAnyWrite() async throws {
    let (client, server) = PipeByteStream.makePair()
    await #expect(throws: RFBError.self) {
        _ = try await AppleRSASecurityHandler().authenticate(
            reader: RFBReader(stream: client), stream: client,
            credential: .macAccount(username: "u", password: String(repeating: "é", count: 32)),
            context: SecurityContext(serverVersion: "RFB 003.889"))
    }
    client.close()
    await #expect(throws: RFBError.connectionClosed) { _ = try await server.read(maxLength: 1) }
}

/// Runs the handler against a server that answers the key request with `serverBytes`.
func runAppleRSA(serverBytes: [UInt8], closeAfter: Bool = true) async throws -> SecurityOutcome {
    let (client, server) = PipeByteStream.makePair()
    try await server.write(Data(serverBytes))
    if closeAfter { server.close() }
    return try await AppleRSASecurityHandler().authenticate(
        reader: RFBReader(stream: client), stream: client,
        credential: .macAccount(username: "u", password: "p"), context: SecurityContext(serverVersion: "RFB 003.889"))
}

@Test func appleRSAMalformedKeyPackets() async throws {
    let rsa = try TestRSAKey()
    // Absurd packet length.
    await #expect(throws: RFBError.self) { _ = try await runAppleRSA(serverBytes: [0xff, 0xff, 0xff, 0xff]) }
    // Too short.
    await #expect(throws: RFBError.self) { _ = try await runAppleRSA(serverBytes: [0, 0, 0, 2, 0, 1]) }
    // keyLen larger than the packet.
    await #expect(throws: RFBError.self) {
        _ = try await runAppleRSA(serverBytes: [0, 0, 0, 8, 0, 1, 0, 0, 1, 0, 0x30, 0x00])
    }
    // keyLen 0.
    await #expect(throws: RFBError.self) { _ = try await runAppleRSA(serverBytes: [0, 0, 0, 6, 0, 1, 0, 0, 0, 0]) }
    // Truncated stream.
    await #expect(throws: RFBError.connectionClosed) {
        _ = try await runAppleRSA(serverBytes: Array(keyPacket(rsa.spkiDER).prefix(100)))
    }
    // Garbage DER of plausible size.
    await #expect(throws: RFBError.self) {
        _ = try await runAppleRSA(serverBytes: keyPacket([UInt8](repeating: 0x30, count: 294)))
    }
    // Non-RSA OID.
    var wrongOID = rsa.spkiDER
    if let i = (0..<(wrongOID.count - 2)).first(where: { wrongOID[$0] == 0x0d && wrongOID[$0 + 1] == 0x01 }) {
        wrongOID[i + 3] = 0x02
    }
    await #expect(throws: RFBError.self) { _ = try await runAppleRSA(serverBytes: keyPacket(wrongOID)) }
    // Valid key but a non-zero acknowledgement.
    await #expect(throws: RFBError.self) {
        let bytes: [UInt8] = keyPacket(rsa.spkiDER) + [0, 0, 0, 1]
        _ = try await runAppleRSA(serverBytes: bytes)
    }
}

@Test func derReaderNeverTraps() {
    var samples: [[UInt8]] = [[], [0x30], [0x30, 0x85, 1, 1, 1, 1, 1]]
    samples.append([0x30, 0x84, 0xff, 0xff, 0xff, 0xff])
    samples.append([0x30, 0x80])
    samples.append([0x30, 0x82, 0x01])
    samples.append([0x30, 0x03, 0x30, 0x01])
    for s in samples {
        #expect(throws: RFBError.self) { _ = try AppleRSASecurityHandler.rsaPublicKey(fromSPKI: s) }
    }
    for len in 0..<64 {
        let random = (0..<len).map { _ in UInt8.random(in: 0...255) }
        let blob: [UInt8] = [0x30] + random
        _ = try? AppleRSASecurityHandler.rsaPublicKey(fromSPKI: blob)
    }
}

@Test func fingerprint() {
    #expect(AppleRSASecurityHandler.sha256Fingerprint(of: Data("abc".utf8))
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}

/// Records each write as a separate chunk, forwarding to an inner stream.
final class RecordingStream: ByteStream, @unchecked Sendable {
    let inner: ByteStream
    let writes = Box<[[UInt8]]>([])
    init(_ inner: ByteStream) { self.inner = inner }
    func read(maxLength: Int) async throws -> Data { try await inner.read(maxLength: maxLength) }
    func write(_ data: Data) async throws { writes.value.append(Array(data)); try await inner.write(data) }
    func close() { inner.close() }
}

@Test func selectionByteAndKeyRequestGoOutInOneWrite() async throws {
    let rsa = try TestRSAKey()
    let (clientPipe, server) = PipeByteStream.makePair()
    let client = RecordingStream(clientPipe)
    let serverTask = Task { () throws -> Void in
        _ = try await readExactly(server, 15)
        try await server.write(Data(keyPacket(rsa.spkiDER)))
        let len = try await readExactly(server, 4)
        _ = try await readExactly(server, Int(len[2]) << 8 | Int(len[3]))
        try await server.write(Data([0, 0, 0, 0, 0, 0, 0, 0]))
    }
    let outcome = try await AppleRSASecurityHandler().selectAndAuthenticate(
        reader: RFBReader(stream: client), stream: client,
        credential: .macAccount(username: "u", password: "p"), context: SecurityContext(serverVersion: "RFB 003.889"))
    try await serverTask.value
    #expect(outcome == .completed)
    let writes = client.writes.value
    #expect(writes.count == 2)
    let first: [UInt8] = [33] + AppleRSASecurityHandler.keyRequest
    #expect(writes.first == first)
    #expect(writes.last?.count == 398)
}

@Test func selectAndAuthenticatePlainHandlerWritesBareSelection() async throws {
    let (clientPipe, server) = PipeByteStream.makePair()
    let client = RecordingStream(clientPipe)
    try await server.write(Data([UInt8](repeating: 9, count: 16)))
    _ = try await VNCPasswordSecurityHandler().selectAndAuthenticate(
        reader: RFBReader(stream: client), stream: client, credential: .vncPassword("pw"),
        context: SecurityContext(serverVersion: "RFB 003.008"))
    let writes = client.writes.value
    #expect(writes.count == 2)
    #expect(writes.first == [2])
    #expect(writes.last?.count == 16)
}

@Test func selectionPayloadRejectsBadCredentialBeforeSending() {
    #expect(throws: RFBError.self) { _ = try AppleRSASecurityHandler().selectionPayload(for: .vncPassword("x")) }
    #expect(throws: RFBError.self) {
        _ = try AppleRSASecurityHandler().selectionPayload(
            for: .macAccount(username: "u", password: String(repeating: "a", count: 64)))
    }
}

@Test func appleRSAFailureResultThrowsWithoutWaitingForReason() async throws {
    let rsa = try TestRSAKey()
    // Exactly what macOS 27.0.1 sent for a bad login: ack 0, result 1, and nothing else (stream stays open).
    let (client, server) = PipeByteStream.makePair()
    let serverTask = Task { () throws -> Void in
        _ = try await readExactly(server, 15)
        try await server.write(Data(keyPacket(rsa.spkiDER)))
        let len = try await readExactly(server, 4)
        _ = try await readExactly(server, Int(len[2]) << 8 | Int(len[3]))
        try await server.write(Data([0, 0, 0, 0, 0, 0, 0, 1]))
    }
    await #expect(throws: RFBError.authenticationFailed(nil)) {
        _ = try await AppleRSASecurityHandler().selectAndAuthenticate(
            reader: RFBReader(stream: client), stream: client,
            credential: .macAccount(username: "vnctest", password: "x"), context: SecurityContext(serverVersion: "RFB 003.889"))
    }
    try await serverTask.value
    client.close()
}
