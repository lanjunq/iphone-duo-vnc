import Foundation

/// Classifies where a host lives and whether connecting is allowed.
/// RFB traffic (other than the auth exchange) is unencrypted, so only loopback and Tailscale
/// (WireGuard-encrypted) are allowed silently.
public enum HostPolicy {
    public enum Kind: Equatable, Sendable {
        case loopback
        /// 100.64.0.0/10, fd7a:115c:a1e0::/48, or a `*.ts.net` name.
        case tailscale
        /// RFC 1918, link-local, IPv6 ULA (outside Tailscale's range), or a `*.local` name.
        case privateLAN
        case publicInternet
        /// A DNS name we cannot classify without resolving it.
        case unresolvedName
        /// Empty, malformed, unspecified (0.0.0.0, ::), multicast or broadcast.
        case invalid
    }

    public enum Decision: Equatable, Sendable {
        case allow
        case warn
        case block
    }

    public struct Classification: Equatable, Sendable {
        public var kind: Kind
        public var decision: Decision
        /// Short user-facing explanation (Simplified Chinese); nil when nothing needs saying.
        public var note: String?
        /// The normalized host (brackets, zone id and trailing dot removed; names lowercased).
        public var normalizedHost: String
    }

    /// Classifies a host string as typed by the user (IPv4, IPv6 with or without brackets/zone, or a name).
    public static func classify(_ host: String) -> Classification {
        let norm = normalize(host)
        if norm.isEmpty || norm.count > 253 || norm.contains(where: { $0.isWhitespace || $0 == "/" }) {
            return Classification(kind: .invalid, decision: .block, note: "主机地址无效", normalizedHost: norm)
        }
        if let v4 = parseIPv4(norm) { return classify(ipv4: v4, normalized: norm) }
        if norm.contains(":") {
            guard let v6 = parseIPv6(norm) else {
                return Classification(kind: .invalid, decision: .block, note: "主机地址无效", normalizedHost: norm)
            }
            return classify(ipv6: v6, normalized: norm)
        }
        return classify(name: norm)
    }

    static func make(_ kind: Kind, _ host: String) -> Classification {
        switch kind {
        case .loopback, .tailscale:
            return Classification(kind: kind, decision: .allow, note: nil, normalizedHost: host)
        case .privateLAN:
            return Classification(kind: kind, decision: .warn,
                                  note: "局域网连接：屏幕和键盘内容未加密，建议改用 Tailscale 地址", normalizedHost: host)
        case .publicInternet:
            return Classification(kind: kind, decision: .block,
                                  note: "公网地址：VNC 画面和键盘内容未加密，已阻止。请通过 Tailscale 连接", normalizedHost: host)
        case .unresolvedName:
            return Classification(kind: kind, decision: .warn,
                                  note: "无法确认这个域名指向哪里；连接后画面和键盘内容可能未加密", normalizedHost: host)
        case .invalid:
            return Classification(kind: kind, decision: .block, note: "主机地址无效", normalizedHost: host)
        }
    }

    // MARK: Names

    static func classify(name: String) -> Classification {
        // Hostname syntax: labels of letters, digits, hyphens (underscore tolerated), no empty labels.
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        let validLabel: (Substring) -> Bool = { l in
            !l.isEmpty && l.count <= 63 && !l.hasPrefix("-") && !l.hasSuffix("-")
                && l.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
        guard labels.allSatisfy(validLabel) else { return make(.invalid, name) }
        // A purely numeric dotted name that is not a valid IPv4 address is malformed.
        if labels.allSatisfy({ $0.allSatisfy { $0.isNumber } }) { return make(.invalid, name) }
        if name == "localhost" || name.hasSuffix(".localhost") { return make(.loopback, name) }
        if name.hasSuffix(".ts.net") { return make(.tailscale, name) }
        if name.hasSuffix(".local") { return make(.privateLAN, name) }
        if labels.count == 1 {
            return Classification(kind: .unresolvedName, decision: .allow,
                                  note: "短主机名，按 Tailscale MagicDNS 名称处理", normalizedHost: name)
        }
        return make(.unresolvedName, name)
    }

    // MARK: IPv4

    /// Strict dotted-quad parser (no octal, no short forms).
    static func parseIPv4(_ s: String) -> [UInt8]? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [UInt8] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 3, p.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let v = Int(p), v <= 255 else { return nil }
            if p.count > 1 && p.hasPrefix("0") { return nil }
            out.append(UInt8(v))
        }
        return out
    }

    static func classify(ipv4 a: [UInt8], normalized: String) -> Classification {
        switch (a[0], a[1]) {
        case (127, _): return make(.loopback, normalized)
        case (100, 64...127): return make(.tailscale, normalized)
        case (10, _), (172, 16...31), (192, 168), (169, 254): return make(.privateLAN, normalized)
        case (0, _), (224...255, _): return make(.invalid, normalized)
        default: return make(.publicInternet, normalized)
        }
    }

    // MARK: IPv6

    static func parseIPv6(_ s: String) -> [UInt8]? {
        var addr = in6_addr()
        let ok = s.withCString { inet_pton(AF_INET6, $0, &addr) }
        guard ok == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }

    static func classify(ipv6 b: [UInt8], normalized: String) -> Classification {
        guard b.count == 16 else { return make(.invalid, normalized) }
        // IPv4-mapped ::ffff:a.b.c.d
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {
            return classify(ipv4: Array(b[12..<16]), normalized: normalized)
        }
        if b[0..<15].allSatisfy({ $0 == 0 }) {
            return b[15] == 1 ? make(.loopback, normalized) : make(.invalid, normalized)  // ::1 / ::
        }
        // fd7a:115c:a1e0::/48
        if b[0] == 0xfd && b[1] == 0x7a && b[2] == 0x11 && b[3] == 0x5c && b[4] == 0xa1 && b[5] == 0xe0 {
            return make(.tailscale, normalized)
        }
        if b[0] & 0xfe == 0xfc { return make(.privateLAN, normalized) }                  // fc00::/7 ULA
        if b[0] == 0xfe && b[1] & 0xc0 == 0x80 { return make(.privateLAN, normalized) }  // fe80::/10
        if b[0] == 0xff { return make(.invalid, normalized) }                            // multicast
        return make(.publicInternet, normalized)
    }

    // MARK: Normalization

    static func normalize(_ host: String) -> String {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("[") && h.hasSuffix("]") && h.count >= 2 {
            h = String(h.dropFirst().dropLast())
        }
        if h.contains(":"), let pct = h.firstIndex(of: "%") {
            h = String(h[..<pct])   // drop IPv6 zone id
        }
        if h.hasSuffix(".") && !h.contains(":") { h = String(h.dropLast()) }
        return h.lowercased()
    }
}
