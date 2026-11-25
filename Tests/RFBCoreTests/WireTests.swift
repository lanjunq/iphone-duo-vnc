import Foundation
import Testing
@testable import RFBCore

/// Records every write call (to check how bytes are grouped into writes).
final class WriteRecordingStream: ByteStream, @unchecked Sendable {
    let inner: ByteStream
    private let lock = NSLock()
    private var _writes: [Data] = []
    init(_ inner: ByteStream) { self.inner = inner }
    var writes: [Data] { lock.withLock { _writes } }
    func read(maxLength: Int) async throws -> Data { try await inner.read(maxLength: maxLength) }
    func write(_ data: Data) async throws {
        lock.withLock { _writes.append(data) }
        try await inner.write(data)
    }
    func close() { inner.close() }
}

@Suite struct WireTests {
    /// macOS closes the connection unless the type 33 selection byte and the 14-byte key request
    /// arrive in one write. The standard configuration must produce exactly that.
    @Test func appleRSASelectionIsCoalescedWithKeyRequest() async throws {
        let (serverEnd, clientEnd) = PipeByteStream.makePair()
        let recorder = WriteRecordingStream(clientEnd)
        let cfg = RFBClientConfiguration.standard(host: "fake", credential: .macAccount(username: "vnctest", password: "x"))
        let client = RFBClient(configuration: cfg, stream: recorder)
        let server = Task { () -> [UInt8] in
            try await serverEnd.write(Data("RFB 003.889\n".utf8))
            try await serverEnd.write(Data([5, 30, 33, 36, 2, 35]))
            let reader = RFBReader(stream: serverEnd)
            let version = try await reader.bytes(12)
            #expect(String(decoding: version, as: UTF8.self) == "RFB 003.889\n")
            let afterVersion = try await reader.bytes(15)
            serverEnd.close()
            return afterVersion
        }
        await #expect(throws: RFBError.self) { _ = try await client.connect() }
        let bytes = try await server.value
        #expect(bytes == [33, 0, 0, 0, 10, 1, 0] + Array("RSA1".utf8) + [0, 0, 0, 0])
        let writes = recorder.writes
        #expect(writes.count == 2)
        #expect(writes.last.map { [UInt8]($0) } == bytes)
    }

    @Test func standardConfigurationWiring() {
        let cfg = RFBClientConfiguration.standard(host: "h", credential: .none)
        #expect(cfg.port == 5900)
        #expect(cfg.securityHandlers.map(\.securityType) == [33, 30, 2, 1])
        #expect(cfg.decoderFactory().map(\.encoding) == DefaultDecoders.preferenceOrder)
        #expect(cfg.shared && cfg.requestRemoteCursor)
        #expect(cfg.jpegQuality == 6 && cfg.compressionLevel == 6)
    }
}
