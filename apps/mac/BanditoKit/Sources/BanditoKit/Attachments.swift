import Foundation

// Files attached to a message. Source of truth: daemon/src/attachments.rs, docs/ARCHITECTURE.md#replies-and-attachments.

/// A file the person attached: saved on the server by `attachments.upload`, sent to the agent by `path` with
/// `agents.send`. The wire shape is `{path, name, size, mime}`.
public struct AgentAttachment: Codable, Sendable, Hashable, Identifiable {
    /// The real path on the server, in the agent's attachment folder.
    public var path: String
    public var name: String
    public var size: Int64
    public var mime: String

    public var id: String { path }

    public init(path: String, name: String, size: Int64, mime: String) {
        self.path = path
        self.name = name
        self.size = size
        self.mime = mime
    }
}

/// Checks a file before it is uploaded. The same rules as the daemon, so a refusal shows at once, next to the file.
public enum AttachmentRules {
    /// The largest file, after decoding (20 MB, as the daemon counts it).
    public static let maxBytes: Int64 = 20 * 1024 * 1024
    /// The longest file name, in UTF-8 bytes.
    public static let maxNameBytes = 200

    public enum Problem: Equatable, Sendable {
        case badName, hiddenName, nameTooLong, tooLarge
    }

    /// Why the file cannot be attached, or `nil` when it can.
    public static func problem(name: String, size: Int64) -> Problem? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || name.contains("/") || name.contains("\\") || name.contains("..")
            || name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        {
            return .badName
        }
        if name.hasPrefix(".") { return .hiddenName }
        if name.utf8.count > maxNameBytes { return .nameTooLong }
        if size > maxBytes { return .tooLarge }
        return nil
    }

    /// Extensions shown as a picture: a miniature in the thread and in the composer.
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic"]

    /// True when the file is a picture by its extension.
    public static func isImage(name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return imageExtensions.contains(ext)
    }
}

/// Body of `agents.send`. `attachments` (paths from the upload) is left out when there are none.
public struct AgentSendRequest: Encodable, Sendable, Equatable {
    public var agentId: String
    public var text: String
    public var attachments: [String]?

    public init(agentId: String, text: String, attachments: [String]?) {
        self.agentId = agentId
        self.text = text
        self.attachments = attachments
    }
}
