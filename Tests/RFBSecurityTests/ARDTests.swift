import Foundation
import RFBBase
import Testing
@testable import RFBSecurity

@Test func modexpSmallVectors() throws {
    let m = try #require(MontgomeryModulus(bigEndian: hex("fffffffb")))
    #expect(m.power(base: [0x30, 0x39], exponent: hex("010932"), width: 4) == u32be(3674144792))
    let m2 = try #require(MontgomeryModulus(bigEndian: u32be(1000003)))
    // 5^(2^40+3) mod 1000003 = 770813 (Python pow)
    #expect(m2.power(base: [5], exponent: hex("010000000003"), width: 4) == u32be(770813))
    #expect(m2.power(base: [5], exponent: [], width: 4) == u32be(1))
    #expect(MontgomeryModulus(bigEndian: [0x10]) == nil)    // even
    #expect(MontgomeryModulus(bigEndian: [1]) == nil)
}

@Test func modexp1024AgainstPython() throws {
    let p = hex(oakley2Hex.lowercased())
    let m = try #require(MontgomeryModulus(bigEndian: p))
    let x = hex(String(repeating: "0123456789abcdef", count: 15) + "fedcba98")
    #expect(hexString(m.power(base: [2], exponent: x, width: 128)!) ==
        "24d8e8de3a5281356a9b12d8903d9a23d3ae9e6d5483c404f7ed28686b8049f245295d2cfda9c85e38d73993c52582ca78c75fa768204cca77fcec03c5a541f9d03c5f286cf3ed27c0cb5c1b80bae5d428f07d5d9b6722eac71cddbe8760c6809b935e2d1eea7b695790fa9ae702d8d644c8e28e13ac6bb2f62f381d58e11142")
    let y = hex(String(repeating: "deadbeef", count: 30))
    #expect(hexString(m.power(base: y, exponent: x, width: 128)!) ==
        "32dbe52239be5c9b213e6c648d9cfbbf4a43b451c7806d14e02f57a9b6dbb6bd3c39ef1b6432dbb87343239239e33f810f312c9607ab0111b6959e5f230a7a1a69ab7951c4ccf1d211970dd0878fb216cccdc583be9105067e6ca44ea11384a83f182da1079e67be2e4c06436ade4bbfb7d422c3c1717fab48f1b79c94fa4b5e")
    // Fermat: a^(p-1) = 1 mod p.
    let pm1 = try ARDSecurityHandler.subtractSmall(p, 1)
    #expect(m.power(base: [7], exponent: pm1, width: 128) == [UInt8](repeating: 0, count: 127) + [1])
    // Base >= modulus is rejected rather than silently reduced.
    #expect(m.power(base: p, exponent: [3], width: 128) == nil)
}

/// In-test ARD server: sends DH params, receives the response, recovers the credentials.
func ardServer(_ server: ByteStream, prime: [UInt8], generator: UInt16) async throws -> (String, String) {
    let k = prime.count
    let m = try #require(MontgomeryModulus(bigEndian: prime))
    let serverPriv = try ARDSecurityHandler.randomPrivateKey(below: prime)
    let g: [UInt8] = [UInt8(generator >> 8), UInt8(generator & 0xff)]
    let serverPub = try #require(m.power(base: g, exponent: serverPriv, width: k))
    var params: [UInt8] = g
    params += [UInt8(k >> 8), UInt8(k & 0xff)]
    params += prime
    params += serverPub
    try await server.write(Data(params))
    let response = try await readExactly(server, 128 + k)
    let clientPub = Array(response[128...])
    let shared = try #require(m.power(base: clientPub, exponent: serverPriv, width: k))
    let key = CryptoSupport.md5(shared)
    let plain = try CryptoSupport.aes128ECB(Array(response[0..<128]), key: key, encrypt: false)
    return (cString(plain[0..<64]), cString(plain[64..<128]))
}

@Test func ardRoundTrip() async throws {
    let prime = hex(oakley2Hex.lowercased())
    for (user, pass) in [("vnctest", "made-up pw"), ("ユーザー", String(repeating: "z", count: 63))] {
        let (client, server) = PipeByteStream.makePair()
        let serverTask = Task { try await ardServer(server, prime: prime, generator: 2) }
        let outcome = try await ARDSecurityHandler().authenticate(
            reader: RFBReader(stream: client), stream: client,
            credential: .macAccount(username: user, password: pass),
            context: SecurityContext(serverVersion: "RFB 003.889"))
        #expect(outcome == .readSecurityResult)
        let (u, p) = try await serverTask.value
        #expect(u == user)
        #expect(p == pass)
    }
}

@Test func ardDeterministicVector() throws {
    // Fixed private key: client public must equal 2^x mod p (Python-verified above).
    let prime = hex(oakley2Hex.lowercased())
    let x = hex(String(repeating: "0123456789abcdef", count: 15) + "fedcba98")
    let serverPub = hex(String(repeating: "deadbeef", count: 30))
    let paddedPub: [UInt8] = [UInt8](repeating: 0, count: 8) + serverPub
    let r = try ARDSecurityHandler.makeResponse(generator: 2, prime: prime, serverPublic: paddedPub,
                                                username: "a", password: "b", privateKey: x,
                                                padding: [UInt8](repeating: 0, count: 128))
    #expect(hexString(r[128...]).hasPrefix("24d8e8de3a528135"))
    let shared = hex("32dbe52239be5c9b213e6c648d9cfbbf4a43b451c7806d14e02f57a9b6dbb6bd3c39ef1b6432dbb87343239239e33f810f312c9607ab0111b6959e5f230a7a1a69ab7951c4ccf1d211970dd0878fb216cccdc583be9105067e6ca44ea11384a83f182da1079e67be2e4c06436ade4bbfb7d422c3c1717fab48f1b79c94fa4b5e")
    let plain = try CryptoSupport.aes128ECB(Array(r[0..<128]), key: CryptoSupport.md5(shared), encrypt: false)
    let u: [UInt8] = [0x61, 0], pw: [UInt8] = [0x62, 0]
    #expect(Array(plain[0..<2]) == u)
    #expect(Array(plain[64..<66]) == pw)
}

@Test func ardMalformedParameters() async throws {
    func run(_ bytes: [UInt8]) async throws {
        let (client, server) = PipeByteStream.makePair()
        try await server.write(Data(bytes))
        server.close()
        _ = try await ARDSecurityHandler().authenticate(
            reader: RFBReader(stream: client), stream: client,
            credential: .macAccount(username: "u", password: "p"), context: SecurityContext(serverVersion: "RFB 003.889"))
    }
    let p = hex(oakley2Hex.lowercased())
    let one = [UInt8](repeating: 0, count: 127) + [1]
    let two = [UInt8](repeating: 0, count: 127) + [2]
    await #expect(throws: RFBError.self) { try await run([0, 2, 0, 0]) }                       // key length 0
    await #expect(throws: RFBError.self) { try await run([0, 2, 0xff, 0xff]) }                 // key length too big
    await #expect(throws: RFBError.connectionClosed) { try await run([0, 2, 0, 128] + p) }     // truncated
    await #expect(throws: RFBError.self) { try await run([0, 2, 0, 128] + p + one) }           // public = 1
    await #expect(throws: RFBError.self) { try await run([0, 2, 0, 128] + p + p) }             // public = p
    var even = p; even[127] = 0xfe
    await #expect(throws: RFBError.self) { try await run([0, 2, 0, 128] + even + two) }        // even prime
    await #expect(throws: RFBError.self) { try await run([0, 1, 0, 128] + p + two) }           // generator 1
    await #expect(throws: RFBError.self) { try await run([0, 2, 0, 1, 3, 2]) }                 // tiny prime
}
