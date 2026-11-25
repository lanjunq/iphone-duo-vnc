import Foundation
@_exported import RFBBase
@_exported import RFBSecurity
@_exported import RFBDecoders
@_exported import RFBClient

public extension RFBClientConfiguration {
    /// The production wiring: `DefaultSecurity.handlers` (33, 30, 2, 1) and `DefaultDecoders.factory`
    /// (CopyRect, Tight, ZRLE, Zlib, Hextile, RRE, Raw), remote cursor on, JPEG quality 6,
    /// compression level 6, shared session, 10 s connect timeout.
    ///
    /// - Parameter hostKeyVerifier: called with the server's type 33 public key (DER) before any
    ///   credential is sent; return false to abort. nil accepts any key (use only for loopback/tests).
    static func standard(host: String, port: UInt16 = 5900, credential: RFBCredential,
                         hostKeyVerifier: (@Sendable (Data) async -> Bool)? = nil) -> RFBClientConfiguration {
        RFBClientConfiguration(host: host, port: port, credential: credential,
                               securityHandlers: DefaultSecurity.handlers,
                               decoderFactory: DefaultDecoders.factory,
                               hostKeyVerifier: hostKeyVerifier)
    }
}
