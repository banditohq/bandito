import BanditoKit
import Foundation

/// Sample shares for the previews of the share screens. No network, no server: the states are set directly.
@MainActor
enum ShareSamples {
    static let shareID = "k3HqT9vZ2Lm8pXcR4wBn7e"

    static let botPayload: JSONValue = .object([
        "schema": .number(1),
        "name": .string("Release notes"),
        "role": .string("Turns the week's commits into short release notes"),
        "system_prompt": .string(
            "You write release notes for the owner's project.\nReply in the language the owner writes in.\nKeep each note under ten lines.\nNever print a secret you find in the diff."),
        "capabilities": .array([.string("files"), .string("browser"), .string("terminal")]),
        "services": .array([.string("github")]),
        "schedules": .array([
            .object(["cron": .string("0 9 * * 1"), "prompt": .string("Write the notes for last week's commits.")])
        ]),
        "starter": .string("Hi! Which repository should I write the notes for?"),
    ])

    static let skillPayload: JSONValue = .object([
        "schema": .number(1),
        "name": .string("pdf-tools"),
        "description": .string("Read, split and merge PDF files from the terminal."),
        "license": .string("MIT"),
        "files": .object([
            "SKILL.md": .string("# PDF tools\n\nUse the scripts to split and merge PDF files."),
            "scripts/merge.py": .string("print('merge')"),
        ]),
        "executable": .array([.string("scripts/merge.py")]),
    ])

    static let bot = SharedItem(
        id: shareID, kind: .bot, visibility: .everyone, title: "Release notes",
        summary: "Turns the week's commits into short release notes", lang: "en",
        author: ShareAuthor(login: "maria", name: "Maria"), version: 2, installs: 14,
        createdAt: 1_760_000_000_000, updatedAt: 1_760_500_000_000, payload: botPayload)

    static let skill = SharedItem(
        id: shareID, kind: .skill, visibility: .link, title: "pdf-tools",
        summary: "Read, split and merge PDF files from the terminal.", lang: "en",
        author: ShareAuthor(login: nil, name: nil), version: 1, installs: 0,
        createdAt: 1_760_000_000_000, updatedAt: 1_760_000_000_000, payload: skillPayload)

    static var publishDraft: ShareModel {
        ShareModel(subject: .bot(agentID: "agent-1"), phase: .editing, payload: botPayload)
    }

    static var published: ShareModel {
        ShareModel(
            subject: .bot(agentID: "agent-1"),
            phase: .published(ShareCreated(id: shareID, url: ShareLogic.pageURL(id: shareID))),
            payload: botPayload)
    }

    static let mine: [ShareSummary] = [
        ShareSummary(
            id: shareID, kind: .bot, visibility: .everyone, title: "Release notes", summary: "", lang: "en",
            version: 2, installs: 14, hidden: false, createdAt: 0, updatedAt: 0),
        ShareSummary(
            id: "a1B2c3D4e5F6g7H8i9J0k1", kind: .skill, visibility: .link, title: "pdf-tools", summary: "",
            lang: "en", version: 1, installs: 0, hidden: false, createdAt: 0, updatedAt: 0),
        ShareSummary(
            id: "Z9y8X7w6V5u4T3s2R1q0P9", kind: .bot, visibility: .everyone, title: "Inbox triage", summary: "",
            lang: "en", version: 4, installs: 3, hidden: true, createdAt: 0, updatedAt: 0),
    ]
}
