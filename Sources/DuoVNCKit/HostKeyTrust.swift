import Foundation

/// Trust on first use for the type 33 server key (pinned as a lowercase hex SHA-256 in `SavedHost`).
public enum HostKeyTrust {
    public enum Verdict: Equatable, Sendable {
        /// The presented key matches the pinned one.
        case trusted
        /// Nothing pinned yet: ask the user, then pin.
        case firstUse
        /// A different key is pinned: block.
        case mismatch(pinned: String)
    }

    /// Compares fingerprints case-insensitively, ignoring spaces and colons.
    public static func evaluate(pinned: String?, presented: String) -> Verdict {
        guard let pinned, !normalize(pinned).isEmpty else { return .firstUse }
        return normalize(pinned) == normalize(presented) ? .trusted : .mismatch(pinned: pinned)
    }

    /// Lowercase hex without separators.
    public static func normalize(_ fingerprint: String) -> String {
        String(fingerprint.lowercased().filter { $0 != " " && $0 != ":" })
    }

    /// Human-readable form: uppercase groups of 4 hex digits separated by spaces, e.g. "AB12 CD34 ...".
    public static func formatted(_ fingerprint: String) -> String {
        let hex = normalize(fingerprint).uppercased()
        var groups: [String] = []
        var current = ""
        for ch in hex {
            current.append(ch)
            if current.count == 4 { groups.append(current); current = "" }
        }
        if !current.isEmpty { groups.append(current) }
        return groups.joined(separator: " ")
    }
}
