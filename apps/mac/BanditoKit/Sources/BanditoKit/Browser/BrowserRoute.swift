import Foundation

// The daemon's browser routes (`/v1/browser/tabs`, `/v1/browser/cdp…`, docs/ARCHITECTURE.md#browser). The
// address and the token come from `ServerModel.daemonRequest`, like the other daemon routes.

enum BrowserRoute {
    /// A target id as the daemon accepts it in a route: 1 to 64 ASCII letters or digits.
    static func isValidTargetID(_ id: String) -> Bool {
        (1...64).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// The `workspace` query value of a browser route, when a workspace is named.
    static func query(workspace: String?) -> [(name: String, value: String)] {
        workspace.map { [(name: "workspace", value: $0)] } ?? []
    }
}
