import AppKit
import Foundation

/// The logos of catalog services, shipped as SVG in `Resources/ServiceLogos` (Simple Icons, CC0; see the README there).
/// A logo is a single-colour mark: it is drawn as a template, so the tile's foreground colour paints it.
enum ServiceLogo {
    /// The logo of a catalog template by its id (`github`, `brave-search`). Nil when the catalog has no logo for it.
    static func image(for templateID: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: templateID, withExtension: "svg", subdirectory: "ServiceLogos"),
            let image = NSImage(contentsOf: url), image.isValid
        else { return nil }
        image.isTemplate = true
        return image
    }
}
