import AppIntents
import BanditoL10n
import Foundation

// The App Intents of the app (docs/IOS_APP.md, phase 3). Titles and phrases are English source text: the translations
// are in AppShortcuts.strings (generated from i18n/*.json, keys "shortcut.*"). Dialogs come from L10n at run time.

/// "What needs me in Bandito": the count and the names of what waits, and the small widget as a snippet. Runs without
/// opening the app.
struct WhatNeedsMeIntent: AppIntent {
    static let title: LocalizedStringResource = "What needs me"
    static let openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let snapshot = await AppIntentHub.shared.needsMeSnapshot()
        let line = WhatNeedsMeText.line(for: snapshot)
        return .result(dialog: IntentDialog(stringLiteral: line), view: WhatNeedsMeSnippet(snapshot: snapshot))
    }
}

/// "Ask Forge in Bandito <text>": sends the text to the agent, then shows the agent. Needs the app: the server answers
/// only to a running app.
struct AskAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask an agent"
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Agent")
    var agent: AgentEntity

    @Parameter(title: "Message")
    var text: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let line = try await AppIntentHub.shared.ask(agent, text: text)
        return .result(dialog: IntentDialog(stringLiteral: line))
    }
}

/// "Open Forge in Bandito": the agent's row in the Crew (`bandito://agent/<server>/<agent>`).
struct OpenAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Open an agent"
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Agent")
    var agent: AgentEntity

    func perform() async throws -> some IntentResult {
        await AppIntentHub.shared.open(.agent(server: agent.serverID, id: agent.agentID))
        return .result()
    }
}

/// The snippet's button: the Inbox (`bandito://inbox`).
struct OpenInboxIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Inbox"
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await AppIntentHub.shared.open(.inbox)
        return .result()
    }
}
