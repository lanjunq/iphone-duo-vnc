import Foundation
import RFBBase

/// Security type 1 (None).
///
/// RFC 6143 §7.2.1: in RFB 3.8 the server still sends a SecurityResult after None; in 3.7 and 3.3 it
/// does not. The decision uses the server's version line from `SecurityContext` (the client answers with
/// min(server, 3.8), so a server at >= 3.8, including Apple's 003.889, means a SecurityResult follows).
public struct NoneSecurityHandler: SecurityHandler {
    public init() {}
    public var securityType: UInt8 { 1 }

    /// Only `.none`: a macOS or VNC credential means the user expects to authenticate.
    public func canHandle(_ credential: RFBCredential) -> Bool { credential == .none }

    public func authenticate(reader: RFBReader, stream: ByteStream, credential: RFBCredential,
                             context: SecurityContext) async throws -> SecurityOutcome {
        guard canHandle(credential) else { throw RFBError.noUsableSecurityType(offered: [securityType]) }
        if let minor = RFBVersionLine.minor(of: context.serverVersion), minor < 8 {
            return .completed
        }
        return .readSecurityResult
    }
}

/// Parses "RFB 003.008" style lines.
enum RFBVersionLine {
    /// The minor version number when the line is "RFB 003.xxx", else nil.
    static func minor(of line: String) -> Int? {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("RFB 003."), t.count == 11 else { return nil }
        return Int(t.suffix(3))
    }
}

/// Security type 2 (classic VNC authentication, RFC 6143 §7.2.2).
///
/// The server sends a 16-byte challenge; the client returns it DES-ECB encrypted with the password as
/// key (first 8 UTF-8 bytes, zero padded, each key byte bit-reversed). The server then sends a
/// SecurityResult (in every protocol version), so this returns `.readSecurityResult`.
public struct VNCPasswordSecurityHandler: SecurityHandler {
    public init() {}
    public var securityType: UInt8 { 2 }

    public func canHandle(_ credential: RFBCredential) -> Bool {
        if case .vncPassword = credential { return true }
        return false
    }

    public func authenticate(reader: RFBReader, stream: ByteStream, credential: RFBCredential,
                             context: SecurityContext) async throws -> SecurityOutcome {
        guard case .vncPassword(let password) = credential else {
            throw RFBError.noUsableSecurityType(offered: [securityType])
        }
        let challenge = try await reader.bytes(16)
        let response = try Self.response(challenge: challenge, password: password)
        try await stream.write(Data(response))
        return .readSecurityResult
    }

    /// The 16-byte VNC authentication response. Exposed for tests and the mock server.
    public static func response(challenge: [UInt8], password: String) throws -> [UInt8] {
        guard challenge.count == 16 else {
            throw RFBError.protocolViolation("VNC auth challenge must be 16 bytes, got \(challenge.count)")
        }
        var key = Array(password.utf8.prefix(8))
        key.append(contentsOf: [UInt8](repeating: 0, count: 8 - key.count))
        for i in key.indices { key[i] = reverseBits(key[i]) }
        defer { CryptoSupport.wipe(&key) }
        return try CryptoSupport.desECB(challenge, key: key, encrypt: true)
    }

    static func reverseBits(_ b: UInt8) -> UInt8 {
        var x = b, r: UInt8 = 0
        for _ in 0..<8 { r = (r << 1) | (x & 1); x >>= 1 }
        return r
    }
}

/// The handlers this package ships, in preference order: Apple RSA (33), ARD DH (30), VNC (2), None (1).
public enum DefaultSecurity {
    public static let handlers: [any SecurityHandler] = [
        AppleRSASecurityHandler(),
        ARDSecurityHandler(),
        VNCPasswordSecurityHandler(),
        NoneSecurityHandler(),
    ]
}
