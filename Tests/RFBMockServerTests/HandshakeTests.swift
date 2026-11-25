import Foundation
import Testing
@testable import RFBMockServer
import RFBBase

@Suite struct HandshakeTests {
    @Test func desKnownVector() throws {
        // FIPS 81 / classic DES example: key 0123456789ABCDEF, "Now is t" -> 3FA40E8A984D4815.
        let out = try MockVNCAuth.desECBEncrypt(key: [0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF],
                                                data: Array("Now is t".utf8))
        #expect(out == [0x3F, 0xA4, 0x0E, 0x8A, 0x98, 0x4D, 0x48, 0x15])
        // VNC key: bit-reversed bytes, zero padded, truncated at 8.
        #expect(MockVNCAuth.desKey(password: "a") == [0x86, 0, 0, 0, 0, 0, 0, 0])
        #expect(MockVNCAuth.desKey(password: "abcdefghXYZ") == MockVNCAuth.desKey(password: "abcdefgh"))
    }

    @Test func noneHandshake38() async throws {
        let h = Harness.start(MockServerConfiguration(width: 320, height: 200, desktopName: "Test Desk"))
        try await withTimeout { try await h.client.handshake() }
        #expect(h.client.serverVersion == "RFB 003.008\n")
        #expect(h.client.securityTypes == [1])
        #expect(h.client.width == 320 && h.client.height == 200)
        #expect(h.client.pixelFormat == .bgrx8888)
        #expect(h.client.name == "Test Desk")
        await h.finish()
        let ev = h.server.receivedEvents
        #expect(ev.contains(.clientVersion("RFB 003.008")))
        #expect(ev.contains(.securitySelected(1)))
        #expect(ev.contains(.clientInit(shared: true)))
        #expect(ev.last == .disconnected(nil))
    }

    @Test func appleVersionLine() async throws {
        let h = Harness.start(MockServerConfiguration(width: 64, height: 64, versionLine: "RFB 003.889\n"))
        try await withTimeout { try await h.client.handshake(reply: "RFB 003.889\n") }
        #expect(h.client.serverVersion == "RFB 003.889\n")
        #expect(h.client.width == 64)
        await h.finish()
    }

    @Test func rfb33NoneHasNoSecurityResult() async throws {
        let h = Harness.start(MockServerConfiguration(width: 64, height: 48))
        try await withTimeout { try await h.client.handshake(reply: "RFB 003.003\n") }
        #expect(h.client.securityTypes == [1])
        #expect(h.client.width == 64 && h.client.height == 48)
        await h.finish()
    }

    @Test func rfb37None() async throws {
        let h = Harness.start(MockServerConfiguration(width: 64, height: 48))
        try await withTimeout { try await h.client.handshake(reply: "RFB 003.007\n") }
        #expect(h.client.height == 48)
        await h.finish()
    }

    @Test func vncAuthSucceeds() async throws {
        let h = Harness.start(MockServerConfiguration(width: 64, height: 48, security: .vncPassword("s3cret!")))
        try await withTimeout { try await h.client.handshake(auth: .vnc("s3cret!")) }
        #expect(h.client.securityTypes == [2])
        #expect(h.client.width == 64)
        await h.finish()
        #expect(h.server.receivedEvents.contains(.authentication(succeeded: true)))
    }

    @Test func vncAuthOnlyFirstEightBytesCount() async throws {
        let h = Harness.start(MockServerConfiguration(width: 8, height: 8, security: .vncPassword("12345678abc")))
        try await withTimeout { try await h.client.handshake(auth: .vnc("12345678XYZ")) }
        await h.finish()
    }

    @Test func vncAuthFailureClosesConnection() async throws {
        let h = Harness.start(MockServerConfiguration(width: 64, height: 48, security: .vncPassword("right")))
        await #expect(throws: TestFailure.self) {
            try await withTimeout { try await h.client.handshake(auth: .vnc("wrong")) }
        }
        await h.serveTask.value
        await #expect(throws: RFBError.connectionClosed) { _ = try await h.client.reader.u8() }
        #expect(h.server.receivedEvents.contains(.authentication(succeeded: false)))
        #expect(h.server.activeConnectionCount == 0)
    }

    @Test func vncAuthFailureReasonText() async throws {
        let h = Harness.start(MockServerConfiguration(width: 64, height: 48, security: .vncPassword("right")))
        do {
            try await withTimeout { try await h.client.handshake(auth: .vnc("wrong")) }
            Issue.record("handshake should fail")
        } catch let e as TestFailure {
            #expect(e.description == "auth failed: Authentication failed")
        }
        await h.finish()
    }

    @Test func vncAuthFailure33HasNoReason() async throws {
        let h = Harness.start(MockServerConfiguration(width: 64, height: 48, security: .vncPassword("right")))
        do {
            try await withTimeout { try await h.client.handshake(reply: "RFB 003.003\n", auth: .vnc("wrong")) }
            Issue.record("handshake should fail")
        } catch let e as TestFailure {
            #expect(e.description == "auth failed: ")
        }
        await h.finish()
    }

    @Test func advertisedButUnsupportedTypeFails() async throws {
        let h = Harness.start(MockServerConfiguration(width: 64, height: 48, versionLine: "RFB 003.889\n",
                                                      security: .vncPassword("pw"), advertisedSecurityTypes: [30, 33, 36, 2, 35]))
        do {
            try await withTimeout { try await h.client.handshake(reply: "RFB 003.889\n", auth: .vnc("pw"), select: 33) }
            Issue.record("selecting 33 should fail")
        } catch let e as TestFailure {
            #expect(e.description == "auth failed: Security type 33 not supported")
        }
        #expect(h.client.securityTypes == [30, 33, 36, 2, 35])
        await h.finish()

        let h2 = Harness.start(MockServerConfiguration(width: 64, height: 48, security: .vncPassword("pw"),
                                                       advertisedSecurityTypes: [30, 33, 2]))
        try await withTimeout { try await h2.client.handshake(auth: .vnc("pw"), select: 2) }
        #expect(h2.client.width == 64)
        await h2.finish()
    }

    @Test func badVersionLineClosesWithoutCrash() async throws {
        let server = MockRFBServer(configuration: MockServerConfiguration(width: 8, height: 8))
        let (a, b) = PipeByteStream.makePair()
        let task = Task { await server.serve(stream: a) }
        let reader = RFBReader(stream: b)
        _ = try await reader.bytes(12)
        try await b.write(Data("HTTP/1.1 200".utf8))
        await task.value
        #expect(server.activeConnectionCount == 0)
        if case .disconnected(let reason)? = server.receivedEvents.last { #expect(reason != nil) } else { Issue.record("no disconnect") }
    }

    @Test func eofDuringHandshake() async throws {
        let server = MockRFBServer(configuration: MockServerConfiguration(width: 8, height: 8))
        let (a, b) = PipeByteStream.makePair()
        let task = Task { await server.serve(stream: a) }
        try await b.write(Data("RFB 003".utf8))
        b.close()
        await task.value
        #expect(server.receivedEvents.last == .disconnected(nil))
    }
}
