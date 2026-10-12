import Foundation
import Testing

@testable import BanditoUI

@Suite struct UpdateBannerRuleTests {
    static let one = UUID()
    static let two = UUID()
    static let three = UUID()

    static func server(_ id: UUID, _ name: String, version: String?, live: Bool = true) -> ServerUpdateCandidate {
        ServerUpdateCandidate(id: id, name: name, version: version, isLive: live)
    }

    static func noneDismissed(_: UUID, _: String) -> Bool { false }

    @Test func theAppUpdateWinsOverAServerOffer() {
        let choice = UpdateBannerRule.choose(
            appVisible: true, servers: [Self.server(Self.one, "forge", version: "0.3.0")], selected: Self.one,
            isDismissed: Self.noneDismissed)
        #expect(choice == .app)
    }

    @Test func aServerOfferShowsWhenTheAppHasNoUpdate() {
        let choice = UpdateBannerRule.choose(
            appVisible: false, servers: [Self.server(Self.one, "forge", version: "0.3.0")], selected: nil,
            isDismissed: Self.noneDismissed)
        #expect(choice == .server(id: Self.one, version: "0.3.0"))
    }

    @Test func nothingShowsWithoutAnAppOrServerUpdate() {
        let idle = [Self.server(Self.one, "forge", version: nil)]
        #expect(UpdateBannerRule.choose(appVisible: false, servers: idle, selected: nil, isDismissed: Self.noneDismissed) == .none)
        #expect(UpdateBannerRule.choose(appVisible: false, servers: [], selected: nil, isDismissed: Self.noneDismissed) == .none)
    }

    @Test func aServerThatIsNotConnectedOffersNothing() {
        // The app leaves the version out for a server that is not connected, so it is not offered.
        let offline = [Self.server(Self.one, "forge", version: nil, live: false)]
        #expect(UpdateBannerRule.serverOffer(servers: offline, selected: Self.one) == nil)
    }

    @Test func theSelectedServerComesFirst() {
        let servers = [Self.server(Self.one, "forge", version: "0.3.0"), Self.server(Self.two, "scout", version: "0.4.0")]
        #expect(UpdateBannerRule.choose(appVisible: false, servers: servers, selected: Self.two, isDismissed: Self.noneDismissed)
            == .server(id: Self.two, version: "0.4.0"))
        #expect(UpdateBannerRule.choose(appVisible: false, servers: servers, selected: Self.one, isDismissed: Self.noneDismissed)
            == .server(id: Self.one, version: "0.3.0"))
    }

    @Test func withoutASelectedOfferTheFirstServerInOrderIsShown() {
        let servers = [
            Self.server(Self.one, "forge", version: nil),
            Self.server(Self.two, "scout", version: "0.3.0"),
            Self.server(Self.three, "lab", version: "0.5.0"),
        ]
        // The selected server has no offer: the first one in order that has one.
        #expect(UpdateBannerRule.choose(appVisible: false, servers: servers, selected: Self.one, isDismissed: Self.noneDismissed)
            == .server(id: Self.two, version: "0.3.0"))
        // Nothing selected at all: the same.
        #expect(UpdateBannerRule.choose(appVisible: false, servers: servers, selected: nil, isDismissed: Self.noneDismissed)
            == .server(id: Self.two, version: "0.3.0"))
    }

    @Test func aDismissedOfferFallsToTheNextServer() {
        let servers = [Self.server(Self.one, "forge", version: "0.3.0"), Self.server(Self.two, "scout", version: "0.4.0")]
        let dismissedForge: (UUID, String) -> Bool = { id, version in id == Self.one && version == "0.3.0" }
        #expect(UpdateBannerRule.choose(appVisible: false, servers: servers, selected: Self.one, isDismissed: dismissedForge)
            == .server(id: Self.two, version: "0.4.0"))
    }

    @Test func aDismissedOnlyOfferShowsNothing() {
        let servers = [Self.server(Self.one, "forge", version: "0.3.0")]
        let all: (UUID, String) -> Bool = { _, _ in true }
        #expect(UpdateBannerRule.choose(appVisible: false, servers: servers, selected: Self.one, isDismissed: all) == .none)
    }

    @Test func aNewerVersionShowsAgainAfterADismiss() {
        // The dismissal is for 0.3.0 only: 0.4.0 of the same server is a new offer.
        let servers = [Self.server(Self.one, "forge", version: "0.4.0")]
        let dismissedOld: (UUID, String) -> Bool = { _, version in version == "0.3.0" }
        #expect(UpdateBannerRule.choose(appVisible: false, servers: servers, selected: Self.one, isDismissed: dismissedOld)
            == .server(id: Self.one, version: "0.4.0"))
    }

    @Test func theMenuOffersLiveUpdatesOnlyAndIgnoresDismissals() {
        // The outcome of an update that was just run is not offered again; a dismissed live offer still is in the menu.
        let outcome = [Self.server(Self.one, "forge", version: "0.3.0", live: false)]
        #expect(UpdateBannerRule.serverOffer(servers: outcome, selected: Self.one, liveOnly: true) == nil)
        #expect(UpdateBannerRule.serverOffer(servers: outcome, selected: Self.one)?.id == Self.one)
        let live = [Self.server(Self.one, "forge", version: "0.3.0")]
        let all: (UUID, String) -> Bool = { _, _ in true }
        #expect(UpdateBannerRule.serverOffer(servers: live, selected: Self.one, isDismissed: all) == nil)
        #expect(UpdateBannerRule.serverOffer(servers: live, selected: Self.one, liveOnly: true)?.version == "0.3.0")
    }

    @Test func dismissalKeepsOneVersionPerServerAndSurvivesARestart() {
        let suite = "bandito.update-banner-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        var dismissals = ServerUpdateDismissals.load(defaults: defaults)
        #expect(!dismissals.isDismissed(server: Self.one, version: "0.3.0"))

        dismissals.dismiss(server: Self.one, version: "0.3.0", defaults: defaults)
        #expect(dismissals.isDismissed(server: Self.one, version: "0.3.0"))
        #expect(!dismissals.isDismissed(server: Self.one, version: "0.4.0"))
        #expect(!dismissals.isDismissed(server: Self.two, version: "0.3.0"))

        // A later dismissal of the same server replaces the earlier version.
        dismissals.dismiss(server: Self.one, version: "0.4.0", defaults: defaults)
        #expect(!dismissals.isDismissed(server: Self.one, version: "0.3.0"))
        #expect(dismissals.isDismissed(server: Self.one, version: "0.4.0"))

        // Saved: a new load (the next launch) reads the same.
        let reloaded = ServerUpdateDismissals.load(defaults: defaults)
        #expect(reloaded.isDismissed(server: Self.one, version: "0.4.0"))
        #expect(reloaded == dismissals)
    }
}
