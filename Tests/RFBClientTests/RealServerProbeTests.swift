import Foundation
import Testing
@testable import RFBClient
import RFBBase

/// Read-only probe of the local macOS Screen Sharing server: version line and security list only,
/// NO authentication attempt. Runs only when DUOVNC_PROBE=1 is set.
@Suite struct RealServerProbeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DUOVNC_PROBE"] == "1"))
    func probeVersionAndSecurityTypes() async throws {
        let s = try await NWByteStream.connect(host: "127.0.0.1", port: 5900, timeout: 5)
        defer { s.close() }
        let reader = RFBReader(stream: s)
        let version = try await reader.bytes(12)
        print("PROBE server version: \(String(decoding: version, as: UTF8.self).debugDescription)")
        let parsed = RFBClient.parseVersion(version)
        #expect(parsed != nil)
        try await s.write(Data("RFB 003.889\n".utf8))
        let count = Int(try await reader.u8())
        let types = try await reader.bytes(count)
        print("PROBE after replying 003.889: \(count) security types \(types)")
    }
}
