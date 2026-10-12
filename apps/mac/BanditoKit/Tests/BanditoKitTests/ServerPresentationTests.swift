@testable import BanditoKit
import Foundation
import Testing

/// What a saved server looks like and does for the person: one main server, the order, the name, the icon, the color,
/// the notifications, and a `servers.v1` record written before these fields existed.
@Suite struct ServerPresentationTests {
    private static let idA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private static let idB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    private static let idC = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!

    private static func config(_ id: UUID, _ name: String, primary: Bool = false) -> ServerConfig {
        ServerConfig(id: id, name: name, endpoint: .local(socketPath: "/tmp/bandito-test.sock"), isPrimary: primary)
    }

    // MARK: Main server

    @Test func settingPrimaryLeavesExactlyOneMainServer() {
        let configs = [Self.config(Self.idA, "A", primary: true), Self.config(Self.idB, "B"), Self.config(Self.idC, "C")]
        let moved = ServerConfigRules.settingPrimary(Self.idB, in: configs)
        #expect(moved.map(\.isPrimary) == [false, true, false])
    }

    @Test func settingNoPrimaryClearsTheFlag() {
        let configs = [Self.config(Self.idA, "A", primary: true), Self.config(Self.idB, "B")]
        #expect(ServerConfigRules.settingPrimary(nil, in: configs).map(\.isPrimary) == [false, false])
    }

    @Test func aSavedListWithTwoMainServersKeepsTheFirst() {
        let configs = [Self.config(Self.idA, "A", primary: true), Self.config(Self.idB, "B", primary: true)]
        let normalized = ServerConfigRules.normalizedPrimary(configs)
        #expect(normalized.map(\.isPrimary) == [true, false])
    }

    @Test func theServerThatOpensAtStartIsTheMainOneOrTheFirst() {
        let withMain = [Self.config(Self.idA, "A"), Self.config(Self.idB, "B", primary: true)]
        #expect(ServerConfigRules.startupServerID(withMain) == Self.idB)
        let withoutMain = [Self.config(Self.idA, "A"), Self.config(Self.idB, "B")]
        #expect(ServerConfigRules.startupServerID(withoutMain) == Self.idA)
        #expect(ServerConfigRules.startupServerID([]) == nil)
    }

    // MARK: Order

    @Test func aServerMovesToTheGivenPlace() {
        let configs = [Self.config(Self.idA, "A"), Self.config(Self.idB, "B"), Self.config(Self.idC, "C")]
        #expect(ServerConfigRules.moved(configs, id: Self.idC, to: 0).map(\.id) == [Self.idC, Self.idA, Self.idB])
        #expect(ServerConfigRules.moved(configs, id: Self.idA, to: 2).map(\.id) == [Self.idB, Self.idC, Self.idA])
        #expect(ServerConfigRules.moved(configs, id: Self.idB, to: 1).map(\.id) == [Self.idA, Self.idB, Self.idC])
    }

    @Test func aPlaceOutsideTheListStaysInside() {
        let configs = [Self.config(Self.idA, "A"), Self.config(Self.idB, "B")]
        #expect(ServerConfigRules.moved(configs, id: Self.idA, to: 99).map(\.id) == [Self.idB, Self.idA])
        #expect(ServerConfigRules.moved(configs, id: Self.idB, to: -4).map(\.id) == [Self.idB, Self.idA])
    }

    @Test func anUnknownServerChangesNoOrder() {
        let configs = [Self.config(Self.idA, "A"), Self.config(Self.idB, "B")]
        #expect(ServerConfigRules.moved(configs, id: Self.idC, to: 0).map(\.id) == [Self.idA, Self.idB])
    }

    // MARK: Name

    @Test func theNameIsTrimmedAndAnEmptyOneIsRefused() {
        #expect(ServerConfigRules.cleanName("  Office  ") == "Office")
        #expect(ServerConfigRules.cleanName("   ") == nil)
        #expect(ServerConfigRules.cleanName("") == nil)
    }

    @Test func aLongNameIsCutToTheLimit() {
        let long = String(repeating: "x", count: ServerConfigRules.nameLimit + 10)
        #expect(ServerConfigRules.cleanName(long)?.count == ServerConfigRules.nameLimit)
    }

    // MARK: Icon, color, notifications

    @Test func eightIconsAndEightColors() {
        #expect(ServerIcon.allCases.count == 8)
        #expect(ServerIcon.allCases.allSatisfy { !$0.rawValue.isEmpty })
        #expect(ServerTint.allCases.count == 8)
    }

    @Test func aScopeAllowsOnlyItsKinds() {
        #expect(NotificationScope.all.allows(.needsYou))
        #expect(NotificationScope.all.allows(.finished))
        #expect(NotificationScope.all.allows(.failed))
        #expect(NotificationScope.needsYou.allows(.needsYou))
        #expect(!NotificationScope.needsYou.allows(.finished))
        #expect(!NotificationScope.needsYou.allows(.failed))
        for kind in [ServerNoticeKind.needsYou, .finished, .failed] {
            #expect(!NotificationScope.off.allows(kind))
        }
    }

    // MARK: Records saved before these fields

    @Test func aRecordWithoutTheNewFieldsReadsTheDefaults() throws {
        let raw = #"{"id":"00000000-0000-0000-0000-00000000000A","name":"Old","endpoint":{"local":{"socketPath":"/tmp/x.sock"}},"isThisMac":true}"#
        let config = try JSONDecoder().decode(ServerConfig.self, from: Data(raw.utf8))
        #expect(config.name == "Old")
        #expect(config.isThisMac)
        #expect(!config.isPrimary)
        #expect(config.iconName == nil)
        #expect(config.icon == nil)
        #expect(config.tint == nil)
        #expect(config.notifications == .all)
    }

    @Test func unknownValuesOfTheNewFieldsReadAsTheDefaults() throws {
        let raw = #"{"id":"00000000-0000-0000-0000-00000000000A","name":"New","endpoint":{"local":{"socketPath":"/tmp/x.sock"}},"iconName":"future.symbol","tintName":"hotpink","notifications":"loud"}"#
        let config = try JSONDecoder().decode(ServerConfig.self, from: Data(raw.utf8))
        #expect(config.iconName == "future.symbol")
        #expect(config.icon == nil)
        #expect(config.tint == nil)
        #expect(config.notifications == .all)
    }

    @Test func theNewFieldsRoundTrip() throws {
        var config = Self.config(Self.idA, "Lab", primary: true)
        config.iconName = ServerIcon.cloud.rawValue
        config.tintName = ServerTint.teal.rawValue
        config.notifications = .needsYou
        let data = try JSONEncoder().encode(config)
        let back = try JSONDecoder().decode(ServerConfig.self, from: data)
        #expect(back == config)
        #expect(back.icon == .cloud)
        #expect(back.tint == .teal)
        #expect(back.isPrimary)
        #expect(back.notifications == .needsYou)
    }

    @Test func theTokenIsStillNeverEncoded() throws {
        var config = Self.config(Self.idA, "Token")
        config.token = "secret-token"
        let json = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        #expect(!json.contains("secret-token"))
    }
}
