import Testing
import Foundation
@testable import RFBBase

@Suite struct RFBBaseTests {
    @Test func pipeRoundTripAndReader() async throws {
        let (a, b) = PipeByteStream.makePair()
        var m = ByteBuilder()
        m.u8(7); m.u16(0x1234); m.u32(0xdeadbeef); m.i32(-239); m.ascii("RFB 003.008\n")
        try await a.write(m.data)
        let r = RFBReader(stream: b)
        #expect(try await r.u8() == 7)
        #expect(try await r.u16() == 0x1234)
        #expect(try await r.u32() == 0xdeadbeef)
        #expect(try await r.i32() == -239)
        #expect(try await r.string(12) == "RFB 003.008\n")
    }

    @Test func readerWaitsAcrossChunksAndSeesClose() async throws {
        let (a, b) = PipeByteStream.makePair()
        let r = RFBReader(stream: b)
        let t = Task { try await r.bytes(6) }
        try await a.write(Data([1, 2, 3]))
        try await Task.sleep(nanoseconds: 20_000_000)
        try await a.write(Data([4, 5, 6]))
        #expect(try await t.value == [1, 2, 3, 4, 5, 6])
        a.close()
        await #expect(throws: RFBError.connectionClosed) { _ = try await r.u8() }
    }

    @Test func pixelFormatWireRoundTrip() throws {
        let enc = PixelFormat.bgrx8888.encoded()
        #expect(enc.count == 16)
        #expect(try PixelFormat(decoding: Array(enc)) == .bgrx8888)
    }

    @Test func framebufferOps() throws {
        let fb = Framebuffer(width: 8, height: 6)
        try fb.fill(RFBRect(x: 1, y: 1, width: 3, height: 2), blue: 10, green: 20, red: 30)
        #expect(fb.pixel(x: 1, y: 1) == (10, 20, 30))
        #expect(fb.pixel(x: 3, y: 2) == (10, 20, 30))
        #expect(fb.pixel(x: 4, y: 2) == (0, 0, 0))
        try fb.write24(RFBRect(x: 0, y: 0, width: 1, height: 1), [1, 2, 3], rgbOrder: true)
        #expect(fb.pixel(x: 0, y: 0) == (3, 2, 1))
        try fb.write24(RFBRect(x: 0, y: 0, width: 1, height: 1), [1, 2, 3], rgbOrder: false)
        #expect(fb.pixel(x: 0, y: 0) == (1, 2, 3))
        try fb.writeBGRX(RFBRect(x: 7, y: 5, width: 1, height: 1), [9, 8, 7, 0])
        #expect(try fb.copyPixels(RFBRect(x: 7, y: 5, width: 1, height: 1)) == [9, 8, 7, 255])
        try fb.copy(fromX: 1, y: 1, to: RFBRect(x: 2, y: 2, width: 3, height: 2))
        #expect(fb.pixel(x: 4, y: 3) == (10, 20, 30))
        #expect(throws: RFBError.self) { try fb.fill(RFBRect(x: 7, y: 5, width: 2, height: 1), blue: 0, green: 0, red: 0) }
        #expect(fb.makeCGImage()?.width == 8)
    }
}
