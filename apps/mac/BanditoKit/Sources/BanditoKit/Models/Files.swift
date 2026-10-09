import Foundation

// Wire models for `fs.*` (docs/ARCHITECTURE.md#files). Decoded with `.convertFromSnakeCase`.

public enum FsEntryKind: String, ForwardCompatibleEnum, CaseIterable {
    case file, dir, symlink, other

    /// Something the app can't browse as a file or folder; shown without actions.
    public static var fallback: FsEntryKind { .other }
}

/// One file, folder or link in a listing (`Entry` on the wire).
public struct FsEntry: Codable, Sendable, Identifiable, Hashable {
    public var name: String
    public var path: String
    public var kind: FsEntryKind
    /// Bytes.
    public var size: Int64
    /// Unix milliseconds.
    public var modifiedMs: Int64
    public var hidden: Bool
    public var readonly: Bool
    public var symlinkTarget: String?
    /// Lowercase, without the dot.
    public var ext: String?

    public var id: String { path }
}

/// A folder's entries (`Listing` on the wire).
public struct FsListing: Codable, Sendable, Hashable {
    public var path: String
    /// `nil` at the root.
    public var parent: String?
    public var entries: [FsEntry]
    public var truncated: Bool
    /// Entries left out because their names are not valid UTF-8.
    public var skipped: Int
}

/// A text file read with `fs.read`. `etag` goes back with `fs.write` to detect concurrent edits.
public struct TextFile: Codable, Sendable, Hashable {
    public var path: String
    public var content: String
    public var etag: String
    public var size: Int64
    public var modifiedMs: Int64
    public var readonly: Bool
}

/// A folder that looks like a project (`fs.projects`).
public struct ProjectHint: Codable, Sendable, Identifiable, Hashable {
    public var path: String
    public var name: String
    public var isGit: Bool
    public var modifiedMs: Int64

    public var id: String { path }
}
