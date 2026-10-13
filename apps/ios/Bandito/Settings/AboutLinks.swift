import BanditoL10n
import Foundation
import SafariServices
import SwiftUI

/// Where the About section points. Every link opens in an in-app Safari sheet, so the person stays in Bandito.
enum AboutLinks {
    // Literal URLs cannot fail to parse; the force unwraps are kept to this one place.
    static let website = URL(string: "https://bandito.dev")!
    static let docs = URL(string: "https://bandito.dev/docs")!
    static let reportProblem = URL(string: "https://github.com/banditohq/bandito/issues/new/choose")!
    static let privacy = URL(string: "https://bandito.dev/privacy")!
    /// The site's language folder for each app language (codes of `i18n/languages.json`) besides English: the site
    /// names Chinese and Portuguese `zh` and `pt`.
    private static let siteFolders: [String: String] = [
        "ru": "ru", "ja": "ja", "zh-Hans": "zh", "ko": "ko", "es": "es", "pt-BR": "pt", "de": "de", "fr": "fr",
    ]

    /// The terms page in the language of the app's strings: `/terms/` for English, `/<site folder>/terms/` for the others.
    /// Any other code gets English.
    static func terms(forLanguage code: String) -> URL {
        guard let folder = siteFolders[code] else { return URL(string: "https://bandito.dev/terms/")! }
        return URL(string: "https://bandito.dev/\(folder)/terms/")!
    }

    /// The terms page for the language the app is showing now.
    static var terms: URL {
        terms(forLanguage: L10n.locale.identifier.replacingOccurrences(of: "_", with: "-"))
    }

    /// The version and build from the bundle, for example "0.1.14 (1)".
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

/// A page shown in a sheet. `.sheet(item:)` needs an identity, and the URL is one.
struct WebPage: Identifiable {
    let url: URL

    var id: URL { url }
}

/// Safari View Controller: a web page inside the app, with the system's bar.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
