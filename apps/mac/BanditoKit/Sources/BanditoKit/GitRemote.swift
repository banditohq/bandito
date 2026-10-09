import Foundation

/// Helpers for git remote addresses, used by "Clone from a link".
public enum GitRemote {
    /// The folder name a clone gets by default: the last part of the path, without `.git`.
    /// Works for `https://host/a/b.git` and scp-style `git@host:a/b`. Returns nil when the path is empty.
    public static func folderName(from address: String) -> String? {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: Substring
        if let scheme = text.range(of: "://") {
            // The path starts at the first "/" after the host. A bare host has no folder name.
            let afterScheme = text[scheme.upperBound...]
            guard let slash = afterScheme.firstIndex(of: "/") else { return nil }
            path = afterScheme[slash...]
        } else if let colon = text.firstIndex(of: ":") {
            // scp-style: user@host:path
            path = text[text.index(after: colon)...]
        } else {
            path = text[...]
        }
        let last = path.split(separator: "/").last.map(String.init) ?? ""
        let name = last.hasSuffix(".git") ? String(last.dropLast(4)) : last
        return name.isEmpty ? nil : name
    }
}
