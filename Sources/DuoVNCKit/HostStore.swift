import Foundation

/// How the app authenticates to a saved host.
public enum HostAuthKind: String, Codable, Sendable, CaseIterable {
    /// macOS account (Apple security types 33 / 30): username + password.
    case macAccount
    /// Classic VNC password (security type 2).
    case vncPassword
}

/// A saved connection. Secrets are NOT stored here (see `SecretStore`).
public struct SavedHost: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var displayName: String
    public var host: String
    public var port: UInt16
    /// macOS account name (nil / empty for VNC password hosts).
    public var username: String?
    public var authKind: HostAuthKind
    /// Lowercase hex SHA-256 of the server's public key, pinned on first use (TOFU). nil = not pinned yet.
    public var knownHostKeySHA256: String?

    public init(id: UUID = UUID(), displayName: String, host: String, port: UInt16 = 5900,
                username: String? = nil, authKind: HostAuthKind = .macAccount, knownHostKeySHA256: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.port = port
        self.username = username
        self.authKind = authKind
        self.knownHostKeySHA256 = knownHostKeySHA256
    }

    enum CodingKeys: String, CodingKey {
        case id, displayName, host, port, username, authKind, knownHostKeySHA256
    }

    /// Lenient decoding: missing optional fields get defaults (port 5900, macAccount).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        host = try c.decode(String.self, forKey: .host)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? host
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? 5900
        username = try c.decodeIfPresent(String.self, forKey: .username)
        authKind = (try? c.decodeIfPresent(HostAuthKind.self, forKey: .authKind)) ?? .macAccount
        knownHostKeySHA256 = try c.decodeIfPresent(String.self, forKey: .knownHostKeySHA256)
    }

    /// Key under which this host's secret lives in a `SecretStore`.
    public var secretAccount: String { id.uuidString }
}

public enum HostStoreError: Error, Equatable, Sendable {
    /// The file exists but is not valid host-store JSON.
    case corrupt(String)
    case ioFailed(String)
}

/// Persists `[SavedHost]` as JSON at an injected file URL. Thread-safe (internally locked).
/// File format: `{"version":1,"hosts":[...]}`.
public final class HostStore: @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()

    private struct FileFormat: Codable {
        var version: Int
        var hosts: [SavedHost]
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// All saved hosts in stored order. A missing file is an empty list; an unreadable one throws.
    public func load() throws -> [SavedHost] {
        try lock.withLock { try loadUnlocked() }
    }

    /// Replaces the whole list (atomic write, creates the parent directory).
    public func save(_ hosts: [SavedHost]) throws {
        try lock.withLock { try saveUnlocked(hosts) }
    }

    /// Inserts or replaces (by id) one host, keeping the position of an existing entry.
    public func upsert(_ host: SavedHost) throws {
        try lock.withLock {
            var hosts = try loadUnlocked()
            if let i = hosts.firstIndex(where: { $0.id == host.id }) {
                hosts[i] = host
            } else {
                hosts.append(host)
            }
            try saveUnlocked(hosts)
        }
    }

    /// Removes a host by id (no error if absent).
    public func remove(id: UUID) throws {
        try lock.withLock {
            var hosts = try loadUnlocked()
            hosts.removeAll { $0.id == id }
            try saveUnlocked(hosts)
        }
    }

    private func loadUnlocked() throws -> [SavedHost] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw HostStoreError.ioFailed(error.localizedDescription)
        }
        if data.isEmpty { return [] }
        do {
            return try JSONDecoder().decode(FileFormat.self, from: data).hosts
        } catch {
            throw HostStoreError.corrupt(String(describing: error))
        }
    }

    private func saveUnlocked(_ hosts: [SavedHost]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(FileFormat(version: 1, hosts: hosts))
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            throw HostStoreError.ioFailed(error.localizedDescription)
        }
    }
}
