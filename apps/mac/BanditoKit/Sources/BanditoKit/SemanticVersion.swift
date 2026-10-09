import Foundation

/// A release version such as `0.5.1` or `v0.6.0-beta.1`. Build metadata (`+…`) is ignored.
public struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// Text after `-`, such as `beta.1`. A release without it sorts after its pre-releases.
    public let prerelease: String?

    public init?(_ text: String) {
        var rest = Substring(text)
        if rest.hasPrefix("v") { rest = rest.dropFirst() }
        if let plus = rest.firstIndex(of: "+") { rest = rest[..<plus] }
        var pre: String?
        if let dash = rest.firstIndex(of: "-") {
            let tail = String(rest[rest.index(after: dash)...])
            guard !tail.isEmpty else { return nil }
            pre = tail
            rest = rest[..<dash]
        }
        let parts = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
            let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]),
            major >= 0, minor >= 0, patch >= 0
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = pre
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let left = (lhs.major, lhs.minor, lhs.patch)
        let right = (rhs.major, rhs.minor, rhs.patch)
        if left != right { return left < right }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (_?, nil): return true
        case (nil, _?): return false
        case (let a?, let b?): return a.compare(b, options: .numeric) == .orderedAscending
        }
    }

    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.map { "\(core)-\($0)" } ?? core
    }
}
