import Foundation
import SwiftUI
import Combine
import DuoVNCKit
import RFBCore

/// User settings that affect a session (UserDefaults keys shared with `@AppStorage`).
struct SessionSettings {
    var explicitShift: Bool
    var naturalScrolling: Bool
    /// Zoom (relative to fit) from which a one-finger tap clicks directly instead of only aiming.
    var directTapZoom: CGFloat

    static let explicitShiftKey: String = "explicitShift"
    static let naturalScrollingKey: String = "naturalScrolling"
    static let directTapZoomKey: String = "directTapZoom"

    static func current() -> SessionSettings {
        let d: UserDefaults = UserDefaults.standard
        let explicitShift: Bool = d.bool(forKey: explicitShiftKey)
        let natural: Bool = d.object(forKey: naturalScrollingKey) == nil ? true : d.bool(forKey: naturalScrollingKey)
        let zoomValue: Double = d.object(forKey: directTapZoomKey) == nil ? 4.0 : d.double(forKey: directTapZoomKey)
        let zoom: CGFloat = CGFloat(zoomValue >= 1.0 && zoomValue <= 16.0 ? zoomValue : 4.0)
        return SessionSettings(explicitShift: explicitShift, naturalScrolling: natural, directTapZoom: zoom)
    }
}

/// Saved hosts (JSON in Application Support) and their passwords (Keychain, this device only).
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var hosts: [SavedHost] = []
    @Published var errorMessage: String?

    private let store: HostStore
    private let secrets: SecretStore

    init() {
        let fm: FileManager = FileManager.default
        let base: URL = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let file: URL = base.appendingPathComponent("DuoVNC", isDirectory: true).appendingPathComponent("hosts.json")
        store = HostStore(fileURL: file)
        secrets = KeychainStore()
        reload()
    }

    func reload() {
        do {
            hosts = try store.load()
        } catch {
            errorMessage = "读取已保存的主机失败：\(String(describing: error))"
        }
    }

    /// Saves a host. `password` nil or empty = keep the stored one.
    func save(_ host: SavedHost, password: String?) {
        do {
            try store.upsert(host)
            if let password = password, !password.isEmpty {
                try secrets.setSecret(password, for: host.secretAccount)
            }
            reload()
        } catch {
            // The error text never contains the password (HostStoreError / SecretStoreError only).
            errorMessage = "保存失败：\(String(describing: error))"
        }
    }

    func delete(_ host: SavedHost) {
        do {
            try store.remove(id: host.id)
            reload()
            try secrets.deleteSecret(for: host.secretAccount)
        } catch {
            reload()
            errorMessage = "删除失败：\(String(describing: error))"
        }
    }

    /// Persists a newly pinned host key (called by the session after the user trusted it).
    func pin(_ host: SavedHost) {
        guard var stored = hosts.first(where: { $0.id == host.id }) else { return }
        stored.knownHostKeySHA256 = host.knownHostKeySHA256
        save(stored, password: nil)
    }

    func hasPassword(_ host: SavedHost) -> Bool {
        let secret: String? = (try? secrets.secret(for: host.secretAccount)) ?? nil
        return !(secret ?? "").isEmpty
    }

    /// The credential to connect with, or nil if something required is missing.
    func credential(for host: SavedHost) -> RFBCredential? {
        let stored: String? = (try? secrets.secret(for: host.secretAccount)) ?? nil
        guard let password = stored, !password.isEmpty else { return nil }
        switch host.authKind {
        case .macAccount:
            let user: String = (host.username ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !user.isEmpty else { return nil }
            return RFBCredential.macAccount(username: user, password: password)
        case .vncPassword:
            return RFBCredential.vncPassword(password)
        }
    }
}
