import BanditoKit
import Foundation

/// What the composer's hint needs to name a connect request the agent waits on.
struct ConnectWait: Equatable {
    var requestId: String
    /// The service's name as the catalog spells it (its id when the catalog has no entry).
    var serviceName: String
}

/// The rules of the "agent needs a service" card (docs/ARCHITECTURE.md#connect-requests). The card starts the same
/// connection the Marketplace does: a sign-in in the browser, or the sheet of keys.
enum AgentConnectRules {
    /// What pressing Connect does.
    enum Start {
        /// The browser sign-in of a service that signs in there (`app.oauth.begin`).
        case signIn(OAuthBeginTarget)
        /// The sign-in with a code, in the sheet that shows it (`app.device.begin`).
        case deviceSignIn(DeviceBeginTarget)
        /// The sheet of keys (a new service from the catalog) or the sheet of a service that is there already.
        case sheet(IntegrationTarget)
        /// The server cannot do this kind of sign-in (`device`: the one with a code): it has to be updated first.
        case needsUpdate(device: Bool)
    }

    /// The connection a card starts is told which request it answers, so that it closes that card and no other.
    struct SheetItem: Identifiable {
        var target: IntegrationTarget
        var requestId: String
        var id: String { "\(requestId)-\(target.id)" }
    }

    /// `existing` is the integration of that service already on the server (made from the template: it has the
    /// template's id as its name), for example one that is turned off or whose sign-in ran out. It is repaired, not
    /// added a second time.
    static func start(
        entry: IntegrationCatalogEntry, existing: Integration?, supportsOAuth: Bool, supportsDevice: Bool = true
    ) -> Start {
        if entry.usesDevice, let url = entry.url {
            guard supportsDevice else { return .needsUpdate(device: true) }
            if let existing { return .deviceSignIn(.existing(id: existing.id)) }
            return .deviceSignIn(.draft(NewIntegration(name: entry.id, kind: .http, url: url)))
        }
        if entry.usesOAuth, let url = entry.url {
            guard supportsOAuth else { return .needsUpdate(device: false) }
            if let existing { return .signIn(.existing(id: existing.id)) }
            return .signIn(.draft(NewIntegration(name: entry.id, kind: .http, url: url)))
        }
        if let existing { return .sheet(.edit(existing)) }
        return .sheet(.catalog(entry))
    }

    /// The integration a catalog service already has on the server: the one named like the template.
    static func existing(for entry: IntegrationCatalogEntry, in integrations: [Integration]) -> Integration? {
        integrations.first { $0.name == entry.id }
    }

    /// The card's heading names the service as the catalog does; without an entry, as the agent wrote the id.
    static func serviceName(of row: ConnectRow, catalog: [IntegrationCatalogEntry]) -> String {
        catalog.first { $0.id == row.service }?.name ?? row.service
    }

    /// The request the composer's hint is about: the newest that waits.
    static func waiting(in pending: [ConnectRow], catalog: [IntegrationCatalogEntry]) -> ConnectWait? {
        guard let row = pending.last else { return nil }
        return ConnectWait(requestId: row.requestId, serviceName: serviceName(of: row, catalog: catalog))
    }
}
