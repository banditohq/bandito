import Foundation

// Push notifications (docs/ARCHITECTURE.md#push). The phone gives the daemon the address the Bandito cloud gave it
// (`handle`) and a key of its own for this server; the daemon encrypts what it sends. Needs `"push"` in `daemon.info`.
// The key is passed once and never read back.

extension ServerModel {
    /// Whether the daemon sends push notifications (`"push"` in its features). An older daemon is left alone.
    public var supportsPush: Bool { info?.supports("push") ?? false }

    /// `push.register`: this device's push address for this server. `key` is the 32 bytes the phone made for the server,
    /// `serverRef` is what the push calls the server (the phone's id for it), `kinds` are `approval`, `question`, `done`
    /// and `error`, `lang` the phone's language code. Registering again replaces the earlier registration.
    public func pushRegister(handle: String, key: Data, serverRef: String, kinds: [String], lang: String?) async throws {
        struct Params: Encodable {
            var handle: String
            var key: String
            var serverRef: String
            var kinds: [String]
            var lang: String?
        }
        try await rpc().call(
            "push.register",
            Params(handle: handle, key: key.base64EncodedString(), serverRef: serverRef, kinds: kinds, lang: lang))
    }

    /// `push.unregister`: the daemon stops sending for this device (also when nothing was registered).
    public func pushUnregister() async throws {
        struct None: Encodable {}
        try await rpc().call("push.unregister", None())
    }

    /// `push.status`: whether the daemon holds a registration of this device. It forgets one when the cloud says the
    /// address is gone.
    public func pushIsRegistered() async throws -> Bool {
        struct None: Encodable {}
        struct Status: Decodable { var registered: Bool }
        return try await rpc().call("push.status", None(), as: Status.self).registered
    }
}
