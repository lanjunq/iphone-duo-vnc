import Foundation
import Testing
@testable import RFBMockServer
import Network
import RFBBase

enum NWConnectionStreamFactory {
    static let queue = DispatchQueue(label: "test.client")
    /// A client-side stream to 127.0.0.1:port (reuses the server's NWConnection-based ByteStream).
    static func connect(port: UInt16) -> NWConnectionStream {
        let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let s = NWConnectionStream(connection: conn, queue: queue)
        conn.start(queue: queue)
        return s
    }
}
