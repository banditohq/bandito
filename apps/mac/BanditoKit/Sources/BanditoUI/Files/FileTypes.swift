import BanditoKit

/// What a file is, from its kind and extension. Drives the icon, the tint, and which viewer opens it.
enum FileCategory: Sendable, Equatable {
    case folder, markdown, code, text, config, image, pdf, video, audio, binary, other
}

/// The viewer that shows a file in the Files mode.
enum FileViewerKind: Sendable, Equatable {
    case markdown, text, image, pdf, media, binary
}

enum FileTypes {
    private static let markdownExtensions: Set<String> = ["md", "markdown"]
    private static let codeExtensions: Set<String> = [
        "rs", "swift", "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "go", "rb", "php", "c", "h", "cc", "cpp",
        "hpp", "java", "kt", "cs", "sh", "bash", "zsh", "fish", "sql", "html", "css", "scss", "vue", "svelte",
        "lua", "zig", "ex", "exs", "dart", "m", "mm",
    ]
    private static let configExtensions: Set<String> = [
        "toml", "yaml", "yml", "json", "ini", "env", "conf", "cfg", "lock", "plist", "xml", "svg",
    ]
    private static let textExtensions: Set<String> = ["txt", "log", "csv", "rtf"]
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tif", "tiff"]
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm", "mkv", "avi"]
    private static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "aac", "flac", "ogg", "aiff"]
    private static let binaryExtensions: Set<String> = [
        "zip", "gz", "tgz", "tar", "bz2", "xz", "7z", "rar", "dmg", "pkg", "exe", "bin", "so", "dylib", "o", "a",
        "wasm", "sqlite", "db", "class", "jar", "iso", "ttf", "otf", "woff", "woff2", "psd", "key", "numbers", "pages",
    ]

    /// The category of an entry. Only folders and regular files get a real category; links and anything
    /// else are `.other`, which the viewer tries as text.
    static func category(name: String, ext: String?, kind: FsEntryKind) -> FileCategory {
        if kind == .dir { return .folder }
        guard kind == .file else { return .other }
        let ext = ext?.lowercased() ?? ""
        if markdownExtensions.contains(ext) { return .markdown }
        if codeExtensions.contains(ext) { return .code }
        if configExtensions.contains(ext) { return .config }
        if textExtensions.contains(ext) { return .text }
        if imageExtensions.contains(ext) { return .image }
        if ext == "pdf" { return .pdf }
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        if binaryExtensions.contains(ext) { return .binary }
        return .other
    }

    /// The viewer for a category, or `nil` for folders (they are browsed, not viewed).
    static func viewer(for category: FileCategory) -> FileViewerKind? {
        switch category {
        case .folder: nil
        case .markdown: .markdown
        case .code, .text, .config, .other: .text
        case .image: .image
        case .pdf: .pdf
        case .video, .audio: .media
        case .binary: .binary
        }
    }
}

/// Folder order in the browser: folders first, then files, each by natural name (`file2` before `file10`).
enum FileSorting {
    static func sorted(_ entries: [FsEntry]) -> [FsEntry] {
        entries.sorted { a, b in
            let aIsFolder = a.kind == .dir
            let bIsFolder = b.kind == .dir
            if aIsFolder != bIsFolder { return aIsFolder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
