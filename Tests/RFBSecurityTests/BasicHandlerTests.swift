import Foundation
import RFBBase
import Testing
@testable import RFBSecurity

@Test func desClassicVector() throws {
    // FIPS-style worked example: key 133457799BBCDFF1, plaintext 0123456789ABCDEF.
    let out = try CryptoSupport.desECB(hex("0123456789abcdef"), key: hex("133457799bbcdff1"))
    #expect(hexString(out) == "85e813540f0ab405")
}

@Test func vncAuthKnownVector() throws {
    // Cross-checked with LibreSSL `openssl enc -des-ecb -K 0e86ceceeef64e26` (bit-reversed "password").
    let challenge = Array(UInt8(0)..<16)
    let r = try VNCPasswordSecurityHandler.response(challenge: challenge, password: "password")
    #expect(hexString(r) == "b866924125c8eebb9debc1db61c538e2")
    // Only the first 8 bytes matter.
    #expect(try VNCPasswordSecurityHandler.response(challenge: challenge, password: "password123") == r)
    #expect(VNCPasswordSecurityHandler.reverseBits(0x01) == 0x80)
    #expect(VNCPasswordSecurityHandler.reverseBits(0x70) == 0x0e)
}

@Test func vncAuthShortPasswordIsZeroPadded() throws {
    let challenge = [UInt8](repeating: 0xaa, count: 16)
    let a = try VNCPasswordSecurityHandler.response(challenge: challenge, password: "ab")
    let b = try VNCPasswordSecurityHandler.response(challenge: challenge, password: "ab\u{0}\u{0}")
    #expect(a == b)
    #expect(throws: RFBError.self) { try VNCPasswordSecurityHandler.response(challenge: [1, 2, 3], password: "x") }
}

@Test func vncHandlerOverPipe() async throws {
    let (client, server) = PipeByteStream.makePair()
    let challenge = (0..<16).map { UInt8($0 * 7 & 0xff) }
    try await server.write(Data(challenge))
    let outcome = try await VNCPasswordSecurityHandler().authenticate(
        reader: RFBReader(stream: client), stream: client, credential: .vncPassword("secret"),
        context: SecurityContext(serverVersion: "RFB 003.008"))
    #expect(outcome == .readSecurityResult)
    let got = try await readExactly(server, 16)
    #expect(got == (try VNCPasswordSecurityHandler.response(challenge: challenge, password: "secret")))
}

@Test func vncHandlerTruncatedChallengeThrows() async throws {
    let (client, server) = PipeByteStream.makePair()
    try await server.write(Data([1, 2, 3, 4, 5]))
    server.close()
    await #expect(throws: RFBError.connectionClosed) {
        _ = try await VNCPasswordSecurityHandler().authenticate(
            reader: RFBReader(stream: client), stream: client, credential: .vncPassword("x"),
            context: SecurityContext(serverVersion: "RFB 003.008"))
    }
}

@Test func canHandleMatrix() {
    let mac = RFBCredential.macAccount(username: "u", password: "p")
    let vnc = RFBCredential.vncPassword("p")
    #expect(AppleRSASecurityHandler().canHandle(mac))
    #expect(!AppleRSASecurityHandler().canHandle(vnc))
    #expect(!AppleRSASecurityHandler().canHandle(.none))
    #expect(ARDSecurityHandler().canHandle(mac))
    #expect(!ARDSecurityHandler().canHandle(vnc))
    #expect(!ARDSecurityHandler().canHandle(.none))
    #expect(VNCPasswordSecurityHandler().canHandle(vnc))
    #expect(!VNCPasswordSecurityHandler().canHandle(mac))
    #expect(!VNCPasswordSecurityHandler().canHandle(.none))
    #expect(NoneSecurityHandler().canHandle(.none))
    #expect(!NoneSecurityHandler().canHandle(mac))
    #expect(!NoneSecurityHandler().canHandle(vnc))
}

@Test func wrongCredentialPassedToAuthenticateThrows() async throws {
    let (client, _) = PipeByteStream.makePair()
    await #expect(throws: RFBError.self) {
        _ = try await AppleRSASecurityHandler().authenticate(
            reader: RFBReader(stream: client), stream: client, credential: .vncPassword("x"),
            context: SecurityContext(serverVersion: "RFB 003.889"))
    }
}

@Test func noneOutcomeDependsOnVersion() async throws {
    let (client, _) = PipeByteStream.makePair()
    func run(_ v: String) async throws -> SecurityOutcome {
        try await NoneSecurityHandler().authenticate(reader: RFBReader(stream: client), stream: client,
                                                     credential: .none, context: SecurityContext(serverVersion: v))
    }
    #expect(try await run("RFB 003.008") == .readSecurityResult)
    #expect(try await run("RFB 003.889") == .readSecurityResult)
    #expect(try await run("RFB 003.007") == .completed)
    #expect(try await run("RFB 003.003") == .completed)
    #expect(try await run("garbage") == .readSecurityResult)
}

@Test func defaultHandlerOrder() {
    #expect(DefaultSecurity.handlers.map(\.securityType) == [33, 30, 2, 1])
}

/// FIPS-197 Appendix C.1 known answer: the AES-128-ECB primitive used by types 30 and 33.
@Test func aes128KnownAnswerFIPS197() throws {
    let key = Array(UInt8(0)...15)
    let plain: [UInt8] = [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff]
    let want: [UInt8] = [0x69, 0xc4, 0xe0, 0xd8, 0x6a, 0x7b, 0x04, 0x30, 0xd8, 0xcd, 0xb7, 0x80, 0x70, 0xb4, 0xc5, 0x5a]
    #expect(try CryptoSupport.aes128ECB(plain, key: key, encrypt: true) == want)
}

/// RFC 1321 test suite: MD5("abc"), the digest type 30 uses to turn the DH secret into the AES key.
@Test func md5KnownAnswer() {
    let want: [UInt8] = [0x90, 0x01, 0x50, 0x98, 0x3c, 0xd2, 0x4f, 0xb0, 0xd6, 0x96, 0x3f, 0x7d, 0x28, 0xe1, 0x7f, 0x72]
    #expect(CryptoSupport.md5(Array("abc".utf8)) == want)
}
