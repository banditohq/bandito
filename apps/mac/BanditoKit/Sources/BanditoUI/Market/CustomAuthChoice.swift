import BanditoKit

/// How "Своя интеграция" signs in to the address the owner typed: with the header fields of a key, or in the browser.
/// A service that answers an unsigned request 401 with its sign-in metadata is found by `integrations.probe`
/// (`oauth: true`, feature `integrations_oauth_probe`); the sheet then offers "Войти в браузере" instead of the fields.
enum CustomAuthChoice: Equatable {
    case headers
    case browserSignIn

    /// The browser sign-in when the address is an http one, the daemon found the sign-in, and this daemon can start it.
    static func of(kind: IntegrationKind, test: IntegrationTest?, canSignIn: Bool) -> CustomAuthChoice {
        kind == .http && canSignIn && test?.oauth == true ? .browserSignIn : .headers
    }

    /// Whether "Добавить" checks the address first: an http address that no check has looked at yet (the check
    /// clears when the address is edited). Without that, a service that signs in in the browser would be saved with
    /// empty header fields.
    static func checksBeforeAdd(kind: IntegrationKind, test: IntegrationTest?, canSignIn: Bool) -> Bool {
        kind == .http && canSignIn && test == nil
    }
}
