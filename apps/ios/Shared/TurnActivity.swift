import ActivityKit
import AppIntents
import BanditoDesign
import Foundation
import SwiftUI

// The Live Activity of a long turn (docs/IOS_APP.md, "A long task"). The app starts it, updates it and ends it
// (`Bandito/LiveActivity`); the widget extension only draws it. Both compile this file, so they agree on what travels.
// Nothing here is an address or a token: a server is its id, an agent is its id, name and avatar.

/// What an avatar needs to be drawn again in the widget extension, which has no `Agent`: the palette color and the face
/// by their raw names, and a custom `#RRGGBB` tile color when the agent has one.
struct TurnAvatarSeed: Codable, Hashable, Sendable {
    var color: String
    var face: String
    var customHex: String?

    /// The avatar as `RaccoonFace` draws it; an unknown color or face (a newer app wrote it) falls back to the name's own.
    func resolved(name: String) -> ResolvedAvatar {
        AvatarResolver.resolve(name: name, color: AvatarColor(rawValue: color), face: AvatarFace(rawValue: face) ?? .auto)
    }

    /// The tile color: the custom one when it is a valid `#RRGGBB`, else the palette's.
    func tint(name: String) -> Color {
        if let customHex, let value = Self.rgb(customHex) {
            return Color(
                .sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255, opacity: 1)
        }
        return resolved(name: name).color.color
    }

    private static func rgb(_ hex: String) -> UInt32? {
        var digits = Substring(hex)
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit) else { return nil }
        return UInt32(digits, radix: 16)
    }
}

struct TurnActivityAttributes: ActivityAttributes {
    /// Where the turn is: running, or how it ended.
    enum Phase: String, Codable, Hashable, Sendable {
        case running
        case done
        case needsYou
        case failed
    }

    struct ContentState: Codable, Hashable, Sendable {
        /// What the agent does now, one short line.
        var doing: String
        var startedAt: Date
        var phase: Phase
    }

    let serverID: UUID
    let agentID: String
    let agentName: String
    let avatarSeed: TurnAvatarSeed

    /// `bandito://agent/<serverID>/<agentID>`: a tap on the activity opens the agent's chat.
    var link: URL {
        BanditoLink.agent(server: serverID.uuidString, id: agentID).url
    }
}

/// What the Stop button runs in the app's process (`LiveActivityIntent`). The app sets `handler` at launch; in the widget
/// extension it stays nil, because the system runs the intent in the app, never in the extension.
@MainActor
enum TurnStopRelay {
    static var handler: (@MainActor (_ serverID: String, _ agentID: String) async -> Void)?
}

/// The Stop button of the activity: interrupts the agent's turn through its server.
/// The titles are App Intents metadata: their English text is the key of `shortcut.title.*` in i18n/*.json, so they stay
/// literals (the metadata reads literals only). The button's own label is `L10n.Thread.stop`.
struct StopTurnIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop"
    static let isDiscoverable = false

    @Parameter(title: "Server")
    var serverID: String

    @Parameter(title: "Agent")
    var agentID: String

    init() {
        serverID = ""
        agentID = ""
    }

    init(serverID: UUID, agentID: String) {
        self.serverID = serverID.uuidString
        self.agentID = agentID
    }

    func perform() async throws -> some IntentResult {
        await TurnStopRelay.handler?(serverID, agentID)
        return .result()
    }
}
