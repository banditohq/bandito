import Foundation

/// What a link in a message opens: a file (as written: absolute, `~/…`, or relative to the agent's folder) or a web
/// address.
public enum ChatLinkTarget: Equatable, Sendable {
    case file(String)
    case url(String)
}

/// One link found in a message text. `range` is the part of the text that becomes the link.
public struct ChatLink: Equatable, Sendable {
    public var range: Range<String.Index>
    public var target: ChatLinkTarget
}

/// Finds file paths and web addresses in the text of a message. Pure: the view turns the ranges into links.
///
/// A file is a path with a known file extension (`Composer.swift`, `/Users/me/a.png`, `src/x.rs:42`). Numbers and
/// words with a slash (`1/2`, `и/или`), dates and version numbers are not files, and neither is a bare domain.
public enum ChatLinks {
    /// Extensions that make a word a file name. Short and common on purpose: a word that only looks like a file
    /// (`example.com`) stays text.
    static let fileExtensions: Set<String> = [
        "swift", "m", "mm", "h", "c", "cpp", "hpp", "rs", "go", "kt", "java", "py", "rb", "php", "js", "jsx", "ts",
        "tsx", "vue", "dart", "lua", "sh", "sql", "css", "html", "xml", "plist", "entitlements", "strings",
        "stringsdict", "storyboard", "xib", "pbxproj", "xcconfig", "gradle", "kts", "toml", "yml", "yaml", "json",
        "lock", "env", "ini", "conf", "cfg", "md", "markdown", "txt", "log", "csv", "tsv", "pdf", "doc", "docx",
        "xls", "xlsx", "ppt", "pptx", "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "mp4", "mov", "mp3", "wav",
        "zip", "tar", "gz",
    ]

    private static let urlPattern = #"https?://[^\s<>"'`]+"#
    /// A run of characters that can make up a path. Anything else (spaces, quotes, brackets, backticks) ends it.
    private static let wordPattern = #"[\p{L}\p{N}_@%+~./\-]+"#
    /// Punctuation that ends a sentence, not the link.
    private static let trailingPunctuation = Set(".,;:!?)]}'\"")

    /// The links of `text`, in order and without overlaps. A web address wins over a file inside it.
    public static func find(in text: String) -> [ChatLink] {
        var links: [ChatLink] = []
        var taken: [Range<String.Index>] = []

        for range in matches(urlPattern, in: text) {
            var raw = String(text[range])
            while let last = raw.last, trailingPunctuation.contains(last) { raw.removeLast() }
            // A bare scheme with nothing after it is text.
            guard let schemeEnd = raw.range(of: "://")?.upperBound, schemeEnd < raw.endIndex else { continue }
            let end = text.index(range.lowerBound, offsetBy: raw.count)
            let linkRange = range.lowerBound..<end
            links.append(ChatLink(range: linkRange, target: .url(raw)))
            taken.append(linkRange)
        }

        for range in matches(wordPattern, in: text) {
            guard !taken.contains(where: { $0.overlaps(range) }) else { continue }
            guard let (path, pathRange) = filePath(in: text, word: range) else { continue }
            links.append(ChatLink(range: pathRange, target: .file(path)))
        }

        return links.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// The absolute path of a file link: `/…` and `~/…` are kept, a relative path is joined to the agent's folder.
    /// Without a folder a relative path stays as written.
    public static func absolutePath(_ path: String, folder: String?) -> String {
        if path.hasPrefix("/") || path.hasPrefix("~/") { return path }
        var relative = path
        while relative.hasPrefix("./") { relative.removeFirst(2) }
        guard let folder, !folder.isEmpty else { return relative }
        return folder.hasSuffix("/") ? folder + relative : folder + "/" + relative
    }

    // MARK: - Helpers

    private static func matches(_ pattern: String, in text: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let whole = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: whole).compactMap { Range($0.range, in: text) }
    }

    /// The file path a word stands for, with its range in the text, or `nil` when the word is not a file.
    /// The trailing `:line` or `:line:column` is not part of the path, and it is not part of the link either.
    private static func filePath(in text: String, word: Range<String.Index>) -> (String, Range<String.Index>)? {
        var range = word
        var raw = String(text[range])
        while let last = raw.last, trailingPunctuation.contains(last) {
            raw.removeLast()
        }
        range = range.lowerBound..<text.index(range.lowerBound, offsetBy: raw.count)
        // `:42` or `:42:7` after the name.
        if let colon = raw.range(of: #":\d+(:\d+)?$"#, options: .regularExpression) {
            raw = String(raw[..<colon.lowerBound])
            range = range.lowerBound..<text.index(range.lowerBound, offsetBy: raw.count)
        }
        guard isFilePath(raw) else { return nil }
        return (raw, range)
    }

    /// True for `name.ext`, `dir/name.ext`, `/abs/name.ext` and `~/name.ext` with a known extension.
    static func isFilePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.contains("//"), !path.contains("://") else { return false }
        let name = path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        // A bare "/" or "~/" has no name.
        guard !name.isEmpty, name != "~" else { return false }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let base = name[..<dot]
        let ext = name[name.index(after: dot)...].lowercased()
        guard !base.isEmpty, fileExtensions.contains(ext) else { return false }
        // Numbers with a dot are not files: `1.2`, `10.10.2026`.
        if base.allSatisfy({ $0.isNumber || $0 == "." }) { return false }
        return true
    }
}
