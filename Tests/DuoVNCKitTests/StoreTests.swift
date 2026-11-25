import Foundation
import Testing
@testable import DuoVNCKit

/// A scratch directory inside the project's build folder (tests must not write outside the project).
func makeScratchDir() throws -> URL {
    let base = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/kit-test-tmp", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

@Suite struct HostStoreTests {
    @Test func roundTripAndUpsertOrder() throws {
        let dir = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HostStore(fileURL: dir.appendingPathComponent("sub/hosts.json"))
        #expect(try store.load().isEmpty)    // missing file
        let a = SavedHost(displayName: "家里 Mac mini", host: "100.100.20.30", username: "vnctest",
                          authKind: .macAccount, knownHostKeySHA256: String(repeating: "ab", count: 32))
        let b = SavedHost(displayName: "VNC", host: "lanjuns-mac-mini", port: 5901, authKind: .vncPassword)
        try store.upsert(a)
        try store.upsert(b)
        #expect(try store.load() == [a, b])
        var a2 = a
        a2.displayName = "Renamed"
        try store.upsert(a2)
        #expect(try store.load() == [a2, b])      // position kept
        try store.remove(id: a.id)
        #expect(try store.load() == [b])
        try store.remove(id: UUID())               // absent: no error
        // A fresh instance reads the same file.
        #expect(try HostStore(fileURL: store.fileURL).load() == [b])
        let json = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(json.contains("\"version\" : 1"))
        #expect(!json.lowercased().contains("password\" :"))
    }

    @Test func corruptFileThrows() throws {
        let dir = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("hosts.json")
        try Data("{not json".utf8).write(to: url)
        let store = HostStore(fileURL: url)
        #expect(throws: HostStoreError.self) { try store.load() }
        // Empty file = empty list.
        try Data().write(to: url)
        #expect(try store.load().isEmpty)
    }

    @Test func lenientDecoding() throws {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","host":"10.0.0.2","authKind":"somethingNew"}"#
        let h = try JSONDecoder().decode(SavedHost.self, from: Data(json.utf8))
        #expect(h.id == id && h.host == "10.0.0.2" && h.displayName == "10.0.0.2")
        #expect(h.port == 5900 && h.authKind == .macAccount && h.username == nil && h.knownHostKeySHA256 == nil)
        #expect(h.secretAccount == id.uuidString)
        let bad = #"{"id":"\#(id.uuidString)","host":"x","port":70000}"#
        #expect(throws: (any Error).self) { try JSONDecoder().decode(SavedHost.self, from: Data(bad.utf8)) }
    }

    @Test func codableRoundTrip() throws {
        let h = SavedHost(displayName: "a", host: "b", port: 1, username: "u", authKind: .vncPassword, knownHostKeySHA256: "00")
        let back = try JSONDecoder().decode(SavedHost.self, from: JSONEncoder().encode(h))
        #expect(back == h)
    }
}

@Suite struct SecretStoreTests {
    @Test func inMemory() throws {
        let s: any SecretStore = InMemorySecretStore()
        #expect(try s.secret(for: "x") == nil)
        try s.setSecret("p@ss wörd", for: "x")
        #expect(try s.secret(for: "x") == "p@ss wörd")
        try s.setSecret("new", for: "x")
        #expect(try s.secret(for: "x") == "new")
        try s.deleteSecret(for: "x")
        try s.deleteSecret(for: "x")
        #expect(try s.secret(for: "x") == nil)
    }

    @Test func keychainStoreConfiguration() {
        // The real Keychain is deliberately not touched by tests (it is outside the project).
        #expect(KeychainStore().service == "com.lanjunq.duovnc")
        #expect(KeychainStore(service: "t").service == "t")
    }
}

@Suite struct ReconnectPolicyTests {
    @Test func backoffSchedule() {
        var p = ReconnectPolicy()
        let delays = (0..<9).compactMap { _ in p.nextDelay(after: .transient) }
        #expect(delays == [0.5, 1, 2, 4, 8, 15, 30, 30, 30])
        #expect(p.attempts == 9)
        p.reset()
        #expect(p.nextDelay(after: .transient) == 0.5)
    }

    @Test func maxAttempts() {
        var p = ReconnectPolicy(schedule: [1, 2], maxAttempts: 3)
        #expect(p.nextDelay(after: .transient) == 1)
        #expect(p.nextDelay(after: .transient) == 2)
        #expect(p.nextDelay(after: .transient) == 2)
        #expect(p.nextDelay(after: .transient) == nil)
        #expect(p.attempts == 3)
        #expect(p.delay(forAttempt: 3) == 2 && p.delay(forAttempt: 4) == nil && p.delay(forAttempt: 0) == nil)
        var u = ReconnectPolicy(schedule: [5], maxAttempts: nil)
        for _ in 0..<100 { #expect(u.nextDelay(after: .transient) == 5) }
    }

    @Test func nonTransientNeverRetries() {
        var p = ReconnectPolicy()
        #expect(p.nextDelay(after: .authentication) == nil)
        #expect(p.nextDelay(after: .hostKey) == nil)
        #expect(p.nextDelay(after: .permanent) == nil)
        #expect(p.attempts == 0)
    }

    @Test func sanitizesSchedule() {
        let p = ReconnectPolicy(schedule: [], maxAttempts: -3)
        #expect(p.schedule == [1] && p.maxAttempts == 0)
        let q = ReconnectPolicy(schedule: [-1, .nan, 2])
        #expect(q.schedule == [0, 0, 2])
    }
}
