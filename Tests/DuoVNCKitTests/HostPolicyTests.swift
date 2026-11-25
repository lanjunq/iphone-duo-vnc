import Foundation
import Testing
@testable import DuoVNCKit

@Suite struct HostPolicyTests {
    func kind(_ s: String) -> HostPolicy.Kind { HostPolicy.classify(s).kind }
    func decision(_ s: String) -> HostPolicy.Decision { HostPolicy.classify(s).decision }

    @Test func loopback() {
        for h in ["127.0.0.1", "127.255.0.9", "::1", "[::1]", "localhost", "LOCALHOST.", "foo.localhost", "::ffff:127.0.0.1"] {
            #expect(kind(h) == .loopback, "\(h)")
            #expect(decision(h) == .allow)
        }
    }

    @Test func tailscale() {
        for h in ["100.64.0.1", "100.100.20.30", "100.127.255.255", "fd7a:115c:a1e0::1", "[fd7a:115c:a1e0:ab12::5]",
                  "lanjuns-mac-mini.tail1234.ts.net", "Mini.Tail-Net.TS.NET."] {
            #expect(kind(h) == .tailscale, "\(h)")
            #expect(decision(h) == .allow)
        }
        // Just outside 100.64.0.0/10.
        #expect(kind("100.63.255.255") == .publicInternet)
        #expect(kind("100.128.0.0") == .publicInternet)
        // Outside fd7a:115c:a1e0::/48 but still ULA.
        #expect(kind("fd7a:115c:a1e1::1") == .privateLAN)
    }

    @Test func privateLAN() {
        for h in ["10.0.0.1", "172.16.0.1", "172.31.255.255", "192.168.1.20", "169.254.3.4", "fe80::1", "fe80::1%en0",
                  "[fe80::1%25en0]", "fd00::1", "fc12::1", "Example-Mac-Mini.local", "::ffff:192.168.0.1"] {
            #expect(kind(h) == .privateLAN, "\(h)")
            #expect(decision(h) == .warn)
            #expect(HostPolicy.classify(h).note != nil)
        }
        #expect(kind("172.15.0.1") == .publicInternet)
        #expect(kind("172.32.0.1") == .publicInternet)
    }

    @Test func publicBlocked() {
        for h in ["8.8.8.8", "1.1.1.1", "2001:4860:4860::8888", "203.0.113.5"] {
            #expect(kind(h) == .publicInternet, "\(h)")
            #expect(decision(h) == .block)
        }
    }

    @Test func names() {
        let short = HostPolicy.classify("lanjuns-mac-mini")
        #expect(short.kind == .unresolvedName && short.decision == .allow && short.note != nil)
        let fqdn = HostPolicy.classify("vnc.example.com")
        #expect(fqdn.kind == .unresolvedName && fqdn.decision == .warn)
    }

    @Test func invalid() {
        for h in ["", "   ", "0.0.0.0", "::", "224.0.0.1", "255.255.255.255", "ff02::1", "1.2.3", "1.2.3.4.5", "256.1.1.1",
                  "01.2.3.4", "a b", "host/path", "-bad.example", "bad-.example", "a..b", "::g", "1:2:3:4:5:6:7:8:9",
                  String(repeating: "a", count: 300), "x_y..", "中文.com"] {
            #expect(kind(h) == .invalid, "\(h)")
            #expect(decision(h) == .block)
        }
    }

    @Test func normalization() {
        #expect(HostPolicy.classify("  [FE80::1%en0] ").normalizedHost == "fe80::1")
        #expect(HostPolicy.classify("Mini.Local.").normalizedHost == "mini.local")
    }
}
