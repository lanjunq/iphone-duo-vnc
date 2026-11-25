import Foundation
import ImageIO
import RFBCore
import DuoVNCKit

// usage: rfbctl <host> <env-file> op [op ...]
// ops: wait:SEC  png:PATH  move:X,Y  click:X,Y  dclick:X,Y  rclick:X,Y  scroll:X,Y,DY
//      type:TEXT (keysym only)  typeshift:TEXT (explicit shift)  key:NAME  down:NAME  up:NAME
// Coordinates are remote pixels. Key names: return tab escape backspace space left right up down
// shift control option command, or a single character.

func loadEnv(_ path: String) -> [String: String] {
    var out = [String: String]()
    guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return out }
    for line in s.split(separator: "\n") {
        guard let i = line.firstIndex(of: "=") else { continue }
        out[String(line[..<i])] = String(line[line.index(after: i)...])
    }
    return out
}

func keysym(_ name: String) -> UInt32? {
    switch name {
    case "return": return 0xff0d
    case "tab": return 0xff09
    case "escape": return 0xff1b
    case "backspace": return 0xff08
    case "space": return 0x20
    case "left": return 0xff51
    case "up": return 0xff52
    case "right": return 0xff53
    case "down": return 0xff54
    case "shift": return 0xffe1
    case "control": return 0xffe3
    case "option", "alt": return 0xffe9
    case "meta": return 0xffe7
    case "command", "super": return 0xffeb
    default:
        if name.count == 1, let c = name.first { return KeyMapper.keysyms(for: c).first }
        if name.hasPrefix("0x"), let v = UInt32(name.dropFirst(2), radix: 16) { return v }
        return nil
    }
}

func writePNG(_ fb: Framebuffer, _ path: String) {
    guard let image = fb.makeCGImage(),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
    else { print("png failed"); return }
    CGImageDestinationAddImage(dest, image, nil)
    print(CGImageDestinationFinalize(dest) ? "wrote \(path)" : "png failed")
}

let keyDelay = (Double(ProcessInfo.processInfo.environment["RFBCTL_KEY_DELAY_MS"] ?? "12") ?? 12) / 1000
func pause(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 3 else { print("usage: rfbctl <host> <env-file> op..."); exit(64) }
let env = loadEnv(args[1])
guard let user = env["DUOVNC_USER"], let pass = env["DUOVNC_PASS"] else { print("env file needs DUOVNC_USER/DUOVNC_PASS"); exit(64) }
let cfg = RFBClientConfiguration.standard(host: args[0], credential: .macAccount(username: user, password: pass))
let client = RFBClient(configuration: cfg)
let events = Task {
    for await e in client.events {
        switch e {
        case .cursorChanged(let c): print("event: cursor \(c.width)x\(c.height)")
        case .desktopResized(let w, let h): print("event: resized \(w)x\(h)")
        case .closed(let err): print("event: closed \(String(describing: err))")
        case .clipboard(let t): print("event: clipboard \(t.count) chars")
        default: break
        }
    }
}
do {
    let info = try await client.connect()
    print("connected \(info.width)x\(info.height) sec \(info.securityType)")
} catch { print("connect failed: \(error)"); exit(2) }
await pause(1.5)

func xy(_ s: Substring) -> (Int, Int, Int) {
    let p = s.split(separator: ",").map { Int($0) ?? 0 }
    return (p.count > 0 ? p[0] : 0, p.count > 1 ? p[1] : 0, p.count > 2 ? p[2] : 0)
}

for op in args.dropFirst(2) {
    guard let i = op.firstIndex(of: ":") else { print("bad op \(op)"); continue }
    let name = op[..<i], arg = op[op.index(after: i)...]
    switch name {
    case "wait": await pause(Double(arg) ?? 1)
    case "png": writePNG(client.framebuffer, String(arg))
    case "move":
        let (x, y, _) = xy(arg); client.sendPointer(x: x, y: y, buttons: [])
    case "click", "dclick", "rclick":
        let (x, y, _) = xy(arg)
        let b: RFBButtonMask = name == "rclick" ? .right : .left
        client.sendPointer(x: x, y: y, buttons: [])
        await pause(0.08)
        for _ in 0..<(name == "dclick" ? 2 : 1) {
            client.sendPointer(x: x, y: y, buttons: b)
            await pause(0.06)
            client.sendPointer(x: x, y: y, buttons: [])
            await pause(0.08)
        }
    case "scroll":
        let (x, y, dy) = xy(arg); client.sendScroll(x: x, y: y, deltaX: 0, deltaY: dy, buttons: [])
    case "type", "typeshift":
        let strategy: ShiftStrategy = name == "typeshift" ? .explicitShift : .keysymOnly
        for ev in KeyMapper.keystrokes(for: String(arg), shiftStrategy: strategy) {
            client.sendKey(keysym: ev.keysym, down: ev.down)
            if keyDelay > 0 { await pause(keyDelay) }
        }
    case "key":
        if let k = keysym(String(arg)) { client.sendKey(keysym: k, down: true); await pause(0.03); client.sendKey(keysym: k, down: false) } else { print("unknown key \(arg)") }
    case "down": if let k = keysym(String(arg)) { client.sendKey(keysym: k, down: true) }
    case "up": if let k = keysym(String(arg)) { client.sendKey(keysym: k, down: false) }
    default: print("unknown op \(name)")
    }
    await pause(0.05)
}
await pause(0.3)
client.disconnect()
_ = await events.value
