import Foundation

// The pure rules of the share extension, compiled by the extension and by the app (so the tests reach them).

enum ShareRules {
    /// At most this many pictures go with one message; the rest are left out.
    static let maxImages = 4
    /// The longer side of a picture is brought down to this many pixels before it is saved.
    static let maxPixel = 2048
    static let jpegQuality = 0.8
    /// The agent last chosen in the extension, kept in the App Group's defaults as `<server>/<agent>`.
    static let lastKey = "share.last"

    /// The message as the box shows it: the shared texts, then each link on a new line. The same text twice, and a
    /// link that the text already holds, are not repeated.
    static func compose(texts: [String], urls: [String]) -> String {
        var parts: [String] = []
        for text in texts {
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty, !parts.contains(clean) { parts.append(clean) }
        }
        for url in urls {
            let clean = url.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty, !parts.contains(where: { $0.contains(clean) }) { parts.append(clean) }
        }
        return parts.joined(separator: "\n")
    }

    /// The picker's order: the agent chosen last first (when it is still listed), then the directory's order.
    static func order(_ agents: [WidgetSnapshot.Listing], last: String?) -> [WidgetSnapshot.Listing] {
        guard let last, let index = agents.firstIndex(where: { key($0) == last }) else { return agents }
        var result = agents
        result.insert(result.remove(at: index), at: 0)
        return result
    }

    static func key(_ agent: WidgetSnapshot.Listing) -> String {
        "\(agent.server)/\(agent.id)"
    }

    /// A message can be sent when an agent is chosen and there is some text or a picture.
    static func canSend(text: String, imageCount: Int, agentChosen: Bool) -> Bool {
        agentChosen && (imageCount > 0 || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
