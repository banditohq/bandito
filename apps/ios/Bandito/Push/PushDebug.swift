#if DEBUG
import CryptoKit
import Foundation

/// Debug helpers for trying push on the Simulator (docs/IOS_APP.md, Push). Nothing here is compiled into a release.
enum PushDebug {
    /// The server a debug key is kept for.
    static let testServerRef = "TEST"
    static let testKeyArgument = "-push-test-key"

    /// `-push-test-key <base64>` keeps a known key for the server `TEST`, so a push made by a script can be opened with no
    /// server. The push's associated data names the phone's handle, which `push-debug.json` shows.
    static func installTestKey(from arguments: [String], keychain: PushKeychain) {
        guard let index = arguments.firstIndex(of: testKeyArgument), index + 1 < arguments.count,
            let data = Data(base64Encoded: arguments[index + 1]), data.count == PushKeychain.keyBytes
        else { return }
        try? keychain.save(SymmetricKey(data: data), for: testServerRef)
    }

    /// `Documents/push-debug.json`: the token, the handle and the environment, for the scripts that send a push.
    static func write(token: String?, handle: String?, env: String, allowed: Bool) {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let info: [String: Any] = [
            "token": token ?? "", "handle": handle ?? PushKeychain.shared.handle ?? "", "env": env, "allowed": allowed,
            "keys": PushKeychain.shared.serverRefs(),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: documents.appending(path: "push-debug.json"), options: .atomic)
        }
    }
}
#endif
