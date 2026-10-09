import Foundation

/// File names for duplicates and copies: `file 2.txt`, `webhook копия.rs`.
enum FileNaming {
    /// Splits `name` into stem and extension. A leading dot (`.env`) or a trailing dot is not an extension.
    static func split(_ name: String) -> (stem: String, ext: String?) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, nil) }
        let ext = String(name[name.index(after: dot)...])
        guard !ext.isEmpty else { return (name, nil) }
        return (String(name[..<dot]), ext)
    }

    /// `name` if it is free, else the first free `stem N.ext` with N from 2 (the "Keep both" choice).
    static func nextFreeName(for name: String, existing: Set<String>) -> String {
        guard existing.contains(name) else { return name }
        let (stem, ext) = split(name)
        return firstFree(base: stem, ext: ext, existing: existing, startingAt: 2)
    }

    /// The name for a copy (⌘D): `stem копия.ext`, then `stem копия 2.ext`, and so on. Folders have no extension.
    static func copyName(for name: String, isFolder: Bool, existing: Set<String>) -> String {
        let (stem, ext) = isFolder ? (name, nil) : split(name)
        let base = "\(stem) копия"
        let first = joined(base, ext)
        guard existing.contains(first) else { return first }
        return firstFree(base: base, ext: ext, existing: existing, startingAt: 2)
    }

    private static func firstFree(base: String, ext: String?, existing: Set<String>, startingAt: Int) -> String {
        var number = startingAt
        while true {
            let candidate = joined("\(base) \(number)", ext)
            if !existing.contains(candidate) { return candidate }
            number += 1
        }
    }

    private static func joined(_ stem: String, _ ext: String?) -> String {
        guard let ext else { return stem }
        return "\(stem).\(ext)"
    }
}

/// One step of a breadcrumb trail: the label shown and the absolute path it opens.
struct PathCrumb: Equatable, Sendable {
    var title: String
    var path: String
}

enum FilePath {
    /// The trail for `path`. Inside the home folder it starts with `~`; elsewhere it starts with `/`.
    static func crumbs(for path: String, home: String?) -> [PathCrumb] {
        let path = normalized(path)
        if let home, path == home || path.hasPrefix(home + "/") {
            var crumbs = [PathCrumb(title: "~", path: home)]
            var current = home
            for part in path.dropFirst(home.count).split(separator: "/") {
                current = join(current, String(part))
                crumbs.append(PathCrumb(title: String(part), path: current))
            }
            return crumbs
        }
        var crumbs = [PathCrumb(title: "/", path: "/")]
        var current = "/"
        for part in path.split(separator: "/") {
            current = join(current, String(part))
            crumbs.append(PathCrumb(title: String(part), path: current))
        }
        return crumbs
    }

    /// The enclosing folder, or `nil` at the root.
    static func parent(of path: String) -> String? {
        let path = normalized(path)
        guard path != "/" else { return nil }
        guard let slash = path.lastIndex(of: "/") else { return nil }
        return slash == path.startIndex ? "/" : String(path[..<slash])
    }

    /// `path` joined with a child name.
    static func join(_ folder: String, _ name: String) -> String {
        folder == "/" ? "/\(name)" : "\(folder)/\(name)"
    }

    private static func normalized(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

/// How long ago a file changed, in the coarse steps the browser shows.
enum TimeBucket: Equatable, Sendable {
    case justNow
    case minutes(Int)
    case today
    case yesterday
    case earlier
}

enum RelativeTime {
    /// Classifies a Unix-millisecond timestamp against `now`. Times in the future count as just now.
    static func bucket(ms: Int64, now: Date, calendar: Calendar) -> TimeBucket {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return .justNow }
        if seconds < 3600 { return .minutes(Int(seconds / 60)) }
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return .yesterday
        }
        return .earlier
    }
}
