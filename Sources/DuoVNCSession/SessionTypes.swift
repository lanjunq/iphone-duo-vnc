import Foundation
import RFBCore
import RFBMockServer
import DuoVNCKit

/// What a session connects to.
public enum SessionEndpoint: Sendable {
    /// A real server over TCP.
    case remote(host: SavedHost, credential: RFBCredential)
    /// An in-process `MockRFBServer` over a `PipeByteStream` pair (no network). Demo mode and tests.
    case inProcess(MockServerConfiguration, credential: RFBCredential)

    /// The app's offline demo: 3840x2160 `DemoDesktopScene`, no authentication.
    public static var demo: SessionEndpoint { .inProcess(.demo(), credential: .none) }

    public var isDemo: Bool {
        if case .inProcess = self { return true }
        return false
    }
}

/// Why the last host-key check refused the key (to explain `RFBError.hostKeyRejected`).
public enum HostKeyEvent: Equatable, Sendable {
    /// The user declined the fingerprint shown on first use.
    case declined
    /// A different key is pinned for this host.
    case mismatch(presented: String)
}

/// A failure the UI shows. `kind` decides whether to reconnect automatically.
public struct SessionFailure: Equatable, Sendable {
    public var kind: ReconnectPolicy.Failure
    /// User-facing text (Simplified Chinese). Never contains credentials.
    public var message: String
    public var error: RFBError?

    public init(kind: ReconnectPolicy.Failure, message: String, error: RFBError?) {
        self.kind = kind
        self.message = message
        self.error = error
    }
}

public enum SessionState: Equatable, Sendable {
    case idle
    /// `attempt` 0 = first connection; n > 0 = the n-th automatic reconnect.
    case connecting(attempt: Int)
    case connected(ServerInfo)
    /// A transient failure; the next attempt starts after `delay` seconds.
    case waitingToReconnect(attempt: Int, delay: TimeInterval, reason: String)
    /// Disconnected on purpose while the app is in the background; resumes on `resume()`.
    case suspended
    /// Gave up (authentication, host key, permanent error, or too many attempts).
    case failed(SessionFailure)
    /// Closed by the user.
    case closed

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    /// Text for the connection HUD; nil when nothing needs showing (connected / idle).
    public var hudText: String? {
        switch self {
        case .idle, .connected:
            return nil
        case .connecting(let attempt):
            return attempt == 0 ? "正在连接…" : "正在重新连接（第 \(attempt) 次）…"
        case .waitingToReconnect(_, let delay, let reason):
            let secs = max(1, Int(delay.rounded(.up)))
            return "\(reason)\n\(secs) 秒后自动重连"
        case .suspended:
            return "已暂停，回到前台后自动重连"
        case .failed(let f):
            return f.message
        case .closed:
            return "已断开"
        }
    }

    /// Whether the HUD should show a spinner.
    public var isBusy: Bool {
        switch self {
        case .connecting, .waitingToReconnect: return true
        default: return false
        }
    }
}

/// Maps client errors to user-facing text and a reconnect decision.
public enum SessionErrorDescription {
    public static func describe(_ error: RFBError, hostKeyEvent: HostKeyEvent? = nil) -> SessionFailure {
        switch error {
        case .connectionClosed:
            return SessionFailure(kind: .transient, message: "连接已断开", error: error)
        case .connectionFailed(let s):
            return SessionFailure(kind: .transient, message: "无法连接到 Mac（\(s)）。请确认 Mac 已开机、屏幕共享已打开、手机已连上 Tailscale", error: error)
        case .timeout:
            return SessionFailure(kind: .transient, message: "连接超时。请确认 Mac 在线、手机已连上 Tailscale", error: error)
        case .protocolViolation(let s):
            return SessionFailure(kind: .permanent, message: "服务器返回了无法识别的数据（\(s)）", error: error)
        case .unsupportedProtocolVersion(let s):
            return SessionFailure(kind: .permanent, message: "不支持的 VNC 协议版本：\(s)", error: error)
        case .noUsableSecurityType(let offered):
            let list = offered.map { String($0) }.joined(separator: ", ")
            return SessionFailure(kind: .permanent,
                                  message: "服务器不接受这种登录方式（服务器提供：\(list)）。Mac 账号需要类型 33 或 30，VNC 密码需要类型 2",
                                  error: error)
        case .authenticationFailed(let reason):
            var m = "登录失败：用户名或密码不对，或这个账号没有屏幕共享权限"
            if let reason, !reason.isEmpty { m += "（服务器：\(reason)）" }
            return SessionFailure(kind: .authentication, message: m, error: error)
        case .hostKeyRejected:
            switch hostKeyEvent {
            case .declined?:
                return SessionFailure(kind: .hostKey, message: "你没有信任这台 Mac 的主机指纹，已取消连接", error: error)
            case .mismatch(let presented)?:
                return SessionFailure(kind: .hostKey,
                                      message: "这台 Mac 的主机指纹和上次记住的不一致，已阻止连接。可能是重装了系统，也可能有人冒充。新指纹：\(HostKeyTrust.formatted(presented))。确认没问题后，在主机设置里清除已记住的指纹再连接",
                                      error: error)
            case nil:
                return SessionFailure(kind: .hostKey, message: "主机指纹验证失败，已阻止连接", error: error)
            }
        case .unsupportedEncoding(let e):
            return SessionFailure(kind: .permanent, message: "服务器使用了不支持的编码（\(e)）", error: error)
        case .decodeFailed(let s):
            return SessionFailure(kind: .transient, message: "画面解码失败（\(s)）", error: error)
        case .cryptoFailed(let s):
            return SessionFailure(kind: .permanent, message: "加密握手失败（\(s)）", error: error)
        }
    }
}
