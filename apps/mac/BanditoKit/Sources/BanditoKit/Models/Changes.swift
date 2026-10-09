import Foundation

// Wire models for `changes.*` (docs/ARCHITECTURE.md#changes).

public enum CheckpointKind: String, ForwardCompatibleEnum, CaseIterable {
    case before, after, restore

    public static var fallback: CheckpointKind { .after }
}

/// A snapshot of an agent's working folder.
public struct Checkpoint: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    /// Commit in the agent's shadow repository.
    public var sha: String
    public var label: String
    public var kind: CheckpointKind
    public var turnId: String?
    /// Unix milliseconds.
    public var createdAt: Int64
}

public enum ChangeStatus: String, ForwardCompatibleEnum, CaseIterable {
    case added, modified, deleted, renamed

    public static var fallback: ChangeStatus { .modified }
}

/// One changed file between two checkpoints. `additions`/`deletions` are nil for binary files.
public struct FileChange: Codable, Sendable, Identifiable, Hashable {
    /// Relative to the working folder, `/` separated.
    public var path: String
    public var status: ChangeStatus
    /// The old path of a renamed file.
    public var from: String?
    public var additions: Int?
    public var deletions: Int?

    public var id: String { path }
}

/// Files changed between `from` and `to` (checkpoint ids; `nil` `to` is the working folder now).
public struct ChangesDiff: Codable, Sendable, Hashable {
    public var from: String?
    public var to: String?
    public var files: [FileChange]

    /// Lines added across all files (binary files count as zero).
    public var additions: Int { files.reduce(0) { $0 + ($1.additions ?? 0) } }
    /// Lines removed across all files (binary files count as zero).
    public var deletions: Int { files.reduce(0) { $0 + ($1.deletions ?? 0) } }
}
