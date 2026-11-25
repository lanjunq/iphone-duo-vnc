// rfbprobe: headless RFB (VNC) probe for Duo VNC.
//
//   rfbprobe <host> [--port N] [--user U --password-env VAR | --vnc-password-env VAR | --env-file PATH]
//            [--encodings tight,zrle,...] [--no-jpeg] [--png out.png] [--seconds N] [--expect-key SHA256]
//
// Without credentials it only reads the version line and the security types, then closes (no
// authentication attempt). With credentials it runs a full session through RFBCore and prints
// ServerInfo and statistics. Passwords are only read from environment variables or an env file
// (DUOVNC_USER / DUOVNC_PASS for a macOS account, DUOVNC_VNC_PASS for a VNC password), never argv.
//
// Hidden test mode: `--mock` (or `--mock=pattern`) starts an in-process MockRFBListener on
// 127.0.0.1 and probes that instead of <host>; `--mock-vnc-password-env VAR` makes it require
// that VNC password.

import Foundation
import ImageIO
import RFBCore
import RFBMockServer

// MARK: - Options

struct Options {
    var host: String?
    var port: UInt16 = 5900
    var user: String?
    var passwordEnv: String?
    var vncPasswordEnv: String?
    var envFile: String?
    var encodings: [Int32]?
    var jpeg = true
    var png: String?
    var seconds: Double = 3
    var expectKey: String?
    var mock: String?
    var mockVNCPasswordEnv: String?
    var noAuth = false
}

let usage = """
usage: rfbprobe <host> [--port N] [--user U --password-env VAR | --vnc-password-env VAR | --env-file PATH]
                [--encodings tight,zrle,zlib,hextile,rre,raw,copyrect] [--no-jpeg] [--png out.png]
                [--seconds N] [--expect-key SHA256HEX] [--no-auth]
Without credentials: prints the version line and the offered security types only.
--no-auth runs a full session with security type None (servers that allow it).
Env file keys: DUOVNC_USER + DUOVNC_PASS (macOS account), or DUOVNC_VNC_PASS (VNC password).
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("rfbprobe: \(message)\n".utf8))
    exit(code)
}

let encodingNames: [String: Int32] = [
    "raw": RFBEncoding.raw, "copyrect": RFBEncoding.copyRect, "rre": RFBEncoding.rre,
    "hextile": RFBEncoding.hextile, "zlib": RFBEncoding.zlib, "tight": RFBEncoding.tight, "zrle": RFBEncoding.zrle,
]

func encodingName(_ e: Int32) -> String {
    switch e {
    case RFBEncoding.cursor: return "Cursor"
    case RFBEncoding.desktopSize: return "DesktopSize"
    case RFBEncoding.lastRect: return "LastRect"
    case RFBEncoding.extendedDesktopSize: return "ExtendedDesktopSize"
    default:
        if let n = encodingNames.first(where: { $0.value == e })?.key { return n.capitalized }
        return "encoding \(e)"
    }
}

func securityName(_ t: UInt8) -> String {
    switch t {
    case 1: return "None"
    case 2: return "VNC password"
    case 30: return "Apple Remote Desktop (DH)"
    case 33: return "Apple RSA (macOS account)"
    case 35: return "Apple (35, unsupported)"
    case 36: return "Apple (36, unsupported)"
    case 16: return "Tight"
    case 18: return "TLS"
    case 19: return "VeNCrypt"
    default: return "unknown"
    }
}

func parse(_ args: [String]) -> Options {
    var o = Options()
    var i = 0
    func value(_ flag: String) -> String {
        i += 1
        guard i < args.count else { fail("\(flag) needs a value\n\(usage)") }
        return args[i]
    }
    while i < args.count {
        let a = args[i]
        switch a {
        case "-h", "--help": print(usage); exit(0)
        case "--port":
            guard let p = UInt16(value(a)), p > 0 else { fail("bad --port") }
            o.port = p
        case "--user": o.user = value(a)
        case "--password-env": o.passwordEnv = value(a)
        case "--vnc-password-env": o.vncPasswordEnv = value(a)
        case "--env-file": o.envFile = value(a)
        case "--encodings":
            var list: [Int32] = []
            for name in value(a).lowercased().split(separator: ",") {
                guard let e = encodingNames[String(name).trimmingCharacters(in: .whitespaces)] else {
                    fail("unknown encoding '\(name)'")
                }
                list.append(e)
            }
            o.encodings = list
        case "--no-jpeg": o.jpeg = false
        case "--no-auth": o.noAuth = true
        case "--png": o.png = value(a)
        case "--seconds":
            guard let s = Double(value(a)), s >= 0, s <= 3600 else { fail("bad --seconds") }
            o.seconds = s
        case "--expect-key": o.expectKey = value(a).lowercased()
        case "--mock": o.mock = "demo"
        case "--mock-vnc-password-env": o.mockVNCPasswordEnv = value(a)
        case "--password", "--pass", "--vnc-password":
            fail("passwords are never accepted on the command line; use --password-env, --vnc-password-env or --env-file")
        default:
            if a.hasPrefix("--mock=") { o.mock = String(a.dropFirst(7)); break }
            if a.hasPrefix("-") { fail("unknown option \(a)\n\(usage)") }
            guard o.host == nil else { fail("more than one host given") }
            o.host = a
        }
        i += 1
    }
    return o
}

/// KEY=VALUE lines; '#' comments; optional surrounding quotes. Values are never printed.
func readEnvFile(_ path: String) -> [String: String] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("cannot read env file \(path)") }
    var out: [String: String] = [:]
    for raw in text.split(whereSeparator: \.isNewline) {
        var line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
        guard let eq = line.firstIndex(of: "=") else { continue }
        let key = line[..<eq].trimmingCharacters(in: .whitespaces)
        var val = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if val.count >= 2, let f = val.first, f == val.last, f == "\"" || f == "'" {
            val = String(val.dropFirst().dropLast())
        }
        out[key] = val
    }
    return out
}

func credential(from o: Options) -> RFBCredential? {
    let env = ProcessInfo.processInfo.environment
    func envValue(_ name: String) -> String {
        guard let v = env[name], !v.isEmpty else { fail("environment variable \(name) is not set") }
        return v
    }
    if o.noAuth { return RFBCredential.none }
    if let vncVar = o.vncPasswordEnv {
        return .vncPassword(envValue(vncVar))
    }
    if let user = o.user {
        guard let pv = o.passwordEnv else { fail("--user needs --password-env VAR") }
        return .macAccount(username: user, password: envValue(pv))
    }
    if o.passwordEnv != nil { fail("--password-env needs --user U") }
    if let path = o.envFile {
        let kv = readEnvFile(path)
        if let u = kv["DUOVNC_USER"], !u.isEmpty {
            guard let p = kv["DUOVNC_PASS"], !p.isEmpty else { fail("env file has DUOVNC_USER but no DUOVNC_PASS") }
            return .macAccount(username: u, password: p)
        }
        if let p = kv["DUOVNC_VNC_PASS"], !p.isEmpty { return .vncPassword(p) }
        fail("env file has neither DUOVNC_USER/DUOVNC_PASS nor DUOVNC_VNC_PASS")
    }
    return nil
}

// MARK: - Probe without credentials

func printable(_ bytes: [UInt8]) -> String {
    String(decoding: bytes.map { (0x20...0x7e).contains($0) ? $0 : 0x2e }, as: UTF8.self)
}

/// Reads the version line and security list, then closes. Sends only our version line.
func probeSecurity(host: String, port: UInt16) async throws {
    let stream = try await NWByteStream.connect(host: host, port: port, timeout: 10)
    defer { stream.close() }
    let reader = RFBReader(stream: stream)
    let version = try await reader.bytes(12)
    print("version line: \"\(printable(Array(version.prefix(11))))\\n\"")
    let text = String(decoding: version, as: UTF8.self)
    guard text.hasPrefix("RFB "), version.count == 12, let minor = Int(text.dropFirst(8).prefix(3)),
          let major = Int(text.dropFirst(4).prefix(3)) else {
        throw RFBError.unsupportedProtocolVersion(printable(version))
    }
    let reply: String
    if major == 3 && minor == 889 { reply = "RFB 003.889\n" }
    else if major > 3 || minor >= 8 { reply = "RFB 003.008\n" }
    else if minor == 7 { reply = "RFB 003.007\n" }
    else { reply = "RFB 003.003\n" }
    try await stream.write(Data(reply.utf8))
    print("client replied: \"\(reply.dropLast())\\n\"")
    var types: [UInt8]
    if reply == "RFB 003.003\n" {
        let t = try await reader.u32()
        types = t == 0 ? [] : [UInt8(truncatingIfNeeded: t)]
    } else {
        let n = Int(try await reader.u8())
        types = try await reader.bytes(n)
    }
    if types.isEmpty {
        let len = Int(try await reader.u32())
        let reason = try await reader.string(min(len, 4096))
        print("server refused: \(reason)")
        return
    }
    print("security types: [\(types.map(String.init).joined(separator: ", "))]")
    for t in types { print("  \(t): \(securityName(t))") }
    let usable = DefaultSecurity.handlers.map(\.securityType).filter(types.contains)
    print("usable by Duo VNC (preference order): [\(usable.map(String.init).joined(separator: ", "))]")
}

// MARK: - Full session

func writePNG(_ fb: Framebuffer, to path: String) throws {
    guard let image = fb.makeCGImage() else { throw RFBError.decodeFailed("empty framebuffer") }
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else {
        throw RFBError.connectionFailed("cannot create \(path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw RFBError.connectionFailed("cannot write \(path)") }
}

final class KeyRecorder: @unchecked Sendable {
    let lock = NSLock()
    var fingerprint: String?
}

func ms(_ a: Date?, _ b: Date?) -> String {
    guard let a, let b else { return "n/a" }
    return String(format: "%.0f ms", b.timeIntervalSince(a) * 1000)
}

func runSession(host: String, port: UInt16, credential: RFBCredential, options o: Options) async -> Int32 {
    let keys = KeyRecorder()
    let expect = o.expectKey
    var cfg = RFBClientConfiguration.standard(host: host, port: port, credential: credential) { der in
        let fp = AppleRSASecurityHandler.sha256Fingerprint(of: der)
        keys.lock.withLock { keys.fingerprint = fp }
        print("server public key SHA-256: \(fp)")
        if let expect, expect != fp {
            print("host key does not match --expect-key; aborting before sending credentials")
            return false
        }
        return true
    }
    if let e = o.encodings { cfg.decoderFactory = DefaultDecoders.factory(only: e) }
    if !o.jpeg { cfg.jpegQuality = nil }
    let client = RFBClient(configuration: cfg)

    final class Log: @unchecked Sendable {
        let lock = NSLock()
        var firstFullFrameAt: Date?
        var closed: RFBError??
    }
    let log = Log()
    let eventsTask = Task {
        for await e in client.events {
            switch e {
            case .framebufferUpdated(let rects):
                let (w, h) = client.framebuffer.size
                let full = rects.contains { $0.x == 0 && $0.y == 0 && $0.width == w && $0.height == h }
                    || (rects.reduce(0) { $0 + $1.width * $1.height } >= w * h && w * h > 0)
                if full { log.lock.withLock { if log.firstFullFrameAt == nil { log.firstFullFrameAt = Date() } } }
            case .desktopResized(let w, let h): print("event: desktop resized to \(w)x\(h)")
            case .cursorChanged(let c): print("event: cursor \(c.width)x\(c.height) hotspot \(c.hotspotX),\(c.hotspotY)")
            case .bell: print("event: bell")
            case .clipboard(let t): print("event: clipboard (\(t.count) characters)")
            case .closed(let err):
                log.lock.withLock { log.closed = .some(err) }
                if let err { print("event: closed with error \(err)") }
            }
        }
    }

    let info: ServerInfo
    do {
        info = try await client.connect()
    } catch {
        print("connect failed: \(error)")
        _ = await eventsTask.value
        return 2
    }
    print("connected")
    print("  server version: \(info.serverVersion)")
    print("  security: \(info.securityType) (\(securityName(info.securityType))) of offered [\(info.offeredSecurityTypes.map(String.init).joined(separator: ", "))]")
    print("  desktop: \"\(info.name)\" \(info.width)x\(info.height)")
    let pf = info.nativePixelFormat
    print("  native pixel format: \(pf.bitsPerPixel) bpp, depth \(pf.depth), \(pf.bigEndian ? "big" : "little") endian, true colour \(pf.trueColor), max \(pf.redMax)/\(pf.greenMax)/\(pf.blueMax) shift \(pf.redShift)/\(pf.greenShift)/\(pf.blueShift)")

    // Wait for the first full frame (up to 30 s), then keep the session for --seconds.
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
        if log.lock.withLock({ log.firstFullFrameAt != nil || log.closed != nil }) { break }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    if o.seconds > 0 { try? await Task.sleep(nanoseconds: UInt64(o.seconds * 1_000_000_000)) }

    let stats = client.statistics
    let firstFull = log.lock.withLock { log.firstFullFrameAt }
    print("statistics")
    print("  time to ServerInit: \(ms(stats.connectStartedAt, stats.serverInitAt))")
    print("  time to first update: \(ms(stats.connectStartedAt, stats.firstUpdateAt))")
    print("  time to first full frame: \(ms(stats.connectStartedAt, firstFull))")
    print("  updates: \(stats.updates), rects: \(stats.rects)")
    for (enc, n) in stats.rectsByEncoding.sorted(by: { $0.key > $1.key }) {
        print("    \(encodingName(enc)) (\(enc)): \(n)")
    }
    print("  bytes received: \(stats.bytesReceived), sent: \(stats.bytesSent)")

    var code: Int32 = 0
    if let png = o.png {
        do {
            try writePNG(client.framebuffer, to: png)
            print("wrote \(png) (\(client.framebuffer.width)x\(client.framebuffer.height))")
        } catch {
            print("PNG failed: \(error)")
            code = 3
        }
    }
    let closedEarly = log.lock.withLock { log.closed }
    client.disconnect()
    _ = await eventsTask.value
    if let closedEarly, closedEarly != nil { code = 2 }
    if firstFull == nil { print("no full frame received"); code = code == 0 ? 4 : code }
    return code
}

// MARK: - Main

let options = parse(Array(CommandLine.arguments.dropFirst()))
var host = options.host
var port = options.port
var mockListener: MockRFBListener?

if let mode = options.mock {
    var cfg: MockServerConfiguration
    switch mode {
    case "demo": cfg = .demo()
    case "pattern": cfg = MockServerConfiguration(width: 1280, height: 800)
    default: fail("unknown --mock mode \(mode) (demo, pattern)")
    }
    if let v = options.mockVNCPasswordEnv {
        guard let p = ProcessInfo.processInfo.environment[v], !p.isEmpty else { fail("environment variable \(v) is not set") }
        cfg.security = .vncPassword(p)
    }
    let listener = MockRFBListener(server: MockRFBServer(configuration: cfg))
    do { port = try await listener.start() } catch { fail("mock listener: \(error)") }
    mockListener = listener
    host = "127.0.0.1"
    print("mock server (\(mode)) listening on 127.0.0.1:\(port)")
}

guard let target = host else { fail("no host given\n\(usage)") }
print("probing \(target):\(port)")

do {
    try await probeSecurity(host: target, port: port)
} catch {
    print("probe failed: \(error)")
    exit(2)
}

guard let cred = credential(from: options) else {
    print("no credentials given: stopping after the security list (no authentication attempted)")
    mockListener?.stop()
    exit(0)
}

let status = await runSession(host: target, port: port, credential: cred, options: options)
mockListener?.stop()
exit(status)
