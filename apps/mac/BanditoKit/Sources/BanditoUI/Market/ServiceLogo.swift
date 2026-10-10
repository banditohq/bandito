import AppKit
import Foundation

/// The logos of catalog services, shipped as SVG in `Resources/ServiceLogos` (Simple Icons, CC0; see the README there).
/// A logo is a single-colour mark: it is drawn as a template, so the tile's foreground colour paints it.
enum ServiceLogo {
    /// The logo of a catalog template by its id (`github`, `brave-search`). Nil when the catalog has no logo for it.
    /// Each file is read once per launch; the result, nil included, is kept in `cache`.
    static func image(for templateID: String) -> NSImage? {
        cache.image(for: templateID)
    }

    /// The process-wide cache. Reads from the bundle on first use.
    static let cache = ServiceLogoCache(load: loadFromBundle)

    /// Reads `<id>.svg` from the bundle's ServiceLogos folder. Nil when the file is missing or is not an image.
    static func loadFromBundle(_ templateID: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: templateID, withExtension: "svg", subdirectory: "ServiceLogos"),
            let image = NSImage(contentsOf: url), image.isValid
        else { return nil }
        image.isTemplate = true
        return image
    }
}

/// Keeps the logos read so far, by template id. Thread-safe (a lock), so any view can ask from any thread. The loader
/// runs at most once per id; a miss is remembered too, so a service without a logo is not read again.
final class ServiceLogoCache: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [String: NSImage?] = [:]
    private let load: (String) -> NSImage?

    init(load: @escaping (String) -> NSImage?) {
        self.load = load
    }

    func image(for templateID: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = images[templateID] {
            return cached
        }
        let loaded = load(templateID)
        images[templateID] = loaded
        return loaded
    }
}
