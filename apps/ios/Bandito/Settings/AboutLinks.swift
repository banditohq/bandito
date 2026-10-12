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
    /// The site has no terms page; the terms are the license in the repository.
    static let terms = URL(string: "https://github.com/banditohq/bandito/blob/main/LICENSE.md")!

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
