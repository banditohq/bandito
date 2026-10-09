import BanditoL10n
import Foundation
import Observation
import SwiftUI

/// Where a command is active. A binding may repeat across contexts, but not inside one context
/// or against `global`, which is active everywhere.
public enum KeyContext: String, Codable, CaseIterable, Sendable {
    case global, team, terminals, files, viewer, browser, screen

    public var title: String {
        switch self {
        case .global: L10n.Keys.Context.global
        case .team: L10n.Keys.Context.team
        case .terminals: L10n.Keys.Context.terminals
        case .files: L10n.Keys.Context.files
        case .viewer: L10n.Keys.Context.viewer
        case .browser: L10n.Keys.Context.browser
        case .screen: L10n.Keys.Context.screen
        }
    }
}

public enum KeyModifier: String, Codable, CaseIterable, Sendable, Hashable {
    case control, option, shift, command
}

/// One shortcut: a key plus modifiers.
///
/// `key` is a single character ("k", "1", "[", "+"), or one of the names
/// "↑" "↓" "←" "→" "return" "escape" "delete" "tab" "space".
public struct KeyBinding: Codable, Hashable, Sendable {
    public var key: String
    public var modifiers: Set<KeyModifier>

    public init(key: String, modifiers: Set<KeyModifier> = []) {
        self.key = key
        self.modifiers = modifiers
    }

    /// The shortcut as menus print it, in macOS order: ⌃⌥⇧⌘ then the key, e.g. "⌃⌥⌫".
    public var symbols: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + Self.keySymbol(key)
    }

    /// The SwiftUI shortcut for menus and buttons. `nil` when the key has no SwiftUI equivalent.
    public var keyboardShortcut: KeyboardShortcut? {
        guard let equivalent = keyEquivalent else { return nil }
        return KeyboardShortcut(equivalent, modifiers: eventModifiers)
    }

    var keyEquivalent: KeyEquivalent? {
        switch key {
        case "↑": .upArrow
        case "↓": .downArrow
        case "←": .leftArrow
        case "→": .rightArrow
        case "return": .return
        case "escape": .escape
        case "delete": .delete
        case "tab": .tab
        case "space": .space
        default: key.count == 1 ? KeyEquivalent(Character(key)) : nil
        }
    }

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.control) { result.insert(.control) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.command) { result.insert(.command) }
        return result
    }

    static func keySymbol(_ key: String) -> String {
        switch key {
        case "return": "↵"
        case "escape": "⎋"
        case "delete": "⌫"
        case "tab": "⇥"
        case "space": "Space"
        default: key.uppercased()
        }
    }
}

/// An action in the app. Each command has at most one default shortcut; pairs such as back and
/// forward, or the four pane directions, are separate commands so each can be rebound alone.
public struct Command: Identifiable, Hashable, Sendable {
    /// Stable id, stored in the user's overrides: "<context>.<name>".
    public let id: String
    /// Name shown in menus and the settings list.
    public let title: String
    public let context: KeyContext
    /// The shortcut out of the box, or `nil` when the command has none.
    public let defaultBinding: KeyBinding?

    public init(id: String, title: String, context: KeyContext, defaultBinding: KeyBinding?) {
        self.id = id
        self.title = title
        self.context = context
        self.defaultBinding = defaultBinding
    }

    /// Every command, in the order the settings list shows them within a context.
    public static let all: [Command] = [
        // Everywhere
        command("global.quickOpen", L10n.Keys.quickOpen, .global, "k", .command),
        command("global.mode.team", L10n.Keys.goTo(mode: AppMode.team.title), .global, "1", .command),
        command("global.mode.files", L10n.Keys.goTo(mode: AppMode.files.title), .global, "2", .command),
        command("global.mode.terminals", L10n.Keys.goTo(mode: AppMode.terminals.title), .global, "3", .command),
        command("global.mode.browser", L10n.Keys.goTo(mode: AppMode.browser.title), .global, "4", .command),
        command("global.mode.screen", L10n.Keys.goTo(mode: AppMode.screen.title), .global, "5", .command),
        command("global.mode.server", L10n.Keys.goTo(mode: AppMode.server.title), .global, "6", .command),
        command("global.newAgent", L10n.Keys.newAgent, .global, "n", .command),
        command("global.back", L10n.Keys.back, .global, "[", .command),
        command("global.forward", L10n.Keys.forward, .global, "]", .command),
        command("global.toggleSidebar", L10n.Keys.toggleSidebar, .global, "s", .control, .command),
        command("global.usage", L10n.Keys.usage, .global, "u", .option, .command),
        command("global.settings", L10n.Keys.settings, .global, ",", .command),
        command("global.searchHistory", L10n.Keys.searchHistory, .global, "f", .shift, .command),
        // Team
        command("team.previousAgent", L10n.Keys.previousAgent, .team, "↑", .option, .command),
        command("team.nextAgent", L10n.Keys.nextAgent, .team, "↓", .option, .command),
        command("team.needsYou", L10n.Keys.needsYou, .team, "a", .shift, .command),
        command("team.approve", L10n.Keys.approve, .team, "return", .command),
        command("team.deny", L10n.Keys.deny, .team, "escape"),
        command("team.stop", L10n.Keys.stop, .team, ".", .command),
        command("team.pauseAll", L10n.Keys.pauseAll, .team, "p", .shift, .command),
        command("team.whatChanged", L10n.Keys.whatChanged, .team, "d", .shift, .command),
        command("team.agentDetails", L10n.Keys.agentDetails, .team, "i", .command),
        // Terminals
        command("terminals.new", L10n.Keys.newTerminal, .terminals, "t", .command),
        command("terminals.splitVertical", L10n.Keys.splitVertical, .terminals, "d", .command),
        command("terminals.splitHorizontal", L10n.Keys.splitHorizontal, .terminals, "d", .shift, .command),
        command("terminals.collapse", L10n.Keys.collapse, .terminals, "↓", .shift, .command),
        command("terminals.restoreCollapsed", L10n.Keys.restoreCollapsed, .terminals, "t", .shift, .command),
        command("terminals.paneLeft", L10n.Keys.Pane.left, .terminals, "←", .option, .command),
        command("terminals.paneRight", L10n.Keys.Pane.right, .terminals, "→", .option, .command),
        command("terminals.paneUp", L10n.Keys.Pane.up, .terminals, "↑", .option, .command),
        command("terminals.paneDown", L10n.Keys.Pane.down, .terminals, "↓", .option, .command),
        command("terminals.close", L10n.Keys.closeTerminal, .terminals, "w", .command),
        command("terminals.clear", L10n.Keys.clear, .terminals, "k", .shift, .command),
        command("terminals.fontBigger", L10n.Keys.fontBigger, .terminals, "+", .command),
        command("terminals.fontSmaller", L10n.Keys.fontSmaller, .terminals, "-", .command),
        command("terminals.fontReset", L10n.Keys.fontReset, .terminals, "0", .command),
        // Files
        command("files.open", L10n.Keys.open, .files, "↓", .command),
        command("files.enclosingFolder", L10n.Keys.enclosingFolder, .files, "↑", .command),
        command("files.quickLook", L10n.Keys.quickLook, .files, "space"),
        command("files.newFolder", L10n.Keys.newFolder, .files, "n", .shift, .command),
        command("files.newFile", L10n.Keys.newFile, .files, "n", .option, .command),
        command("files.rename", L10n.Keys.rename, .files, "return"),
        command("files.trash", L10n.Keys.trash, .files, "delete", .command),
        command("files.copyPath", L10n.Keys.copyPath, .files, "c", .option, .command),
        command("files.duplicate", L10n.Keys.duplicate, .files, "d", .command),
        // File viewer
        command("viewer.toggleEdit", L10n.Keys.toggleEdit, .viewer, "e", .command),
        command("viewer.sideBySide", L10n.Keys.sideBySide, .viewer, "return", .option, .command),
        command("viewer.save", L10n.Keys.save, .viewer, "s", .command),
        command("viewer.nextTab", L10n.Keys.nextTab, .viewer, "tab", .control),
        command("viewer.previousTab", L10n.Keys.previousTab, .viewer, "tab", .control, .shift),
        // Browser
        command("browser.address", L10n.Keys.address, .browser, "l", .command),
        command("browser.reload", L10n.Keys.reload, .browser, "r", .command),
        command("browser.newTab", L10n.Keys.newTab, .browser, "t", .command),
        command("browser.closeTab", L10n.Keys.closeTab, .browser, "w", .command),
        command("browser.takeControl", L10n.Keys.takeControl, .browser, "c", .shift, .command),
        // Server screen
        command("screen.takeControl", L10n.Keys.takeControl, .screen, "c", .shift, .command),
        command("screen.sendCtrlAltDelete", L10n.Keys.sendToServer, .screen, "delete", .control, .option),
    ]

    private static let byID: [String: Command] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    public static func find(_ id: String) -> Command? {
        byID[id]
    }

    private static func command(
        _ id: String, _ title: String, _ context: KeyContext, _ key: String, _ modifiers: KeyModifier...
    ) -> Command {
        Command(id: id, title: title, context: context, defaultBinding: KeyBinding(key: key, modifiers: Set(modifiers)))
    }
}

/// A named set of shortcut changes, relative to the Bandito defaults.
public enum KeymapPreset: String, CaseIterable, Sendable {
    case bandito, vscode, iterm, slack

    public var title: String {
        switch self {
        case .bandito: L10n.Keys.Preset.bandito
        case .vscode: L10n.Keys.Preset.vscode
        case .iterm: L10n.Keys.Preset.iterm
        case .slack: L10n.Keys.Preset.slack
        }
    }

    /// Only the commands the preset changes. Everything else keeps its default.
    var overrides: [String: KeyBinding] {
        switch self {
        case .bandito:
            [:]
        case .vscode:
            [
                "global.quickOpen": KeyBinding(key: "p", modifiers: [.command]),
                "global.toggleSidebar": KeyBinding(key: "b", modifiers: [.command]),
            ]
        case .iterm:
            [
                "terminals.new": KeyBinding(key: "t", modifiers: [.command]),
                "terminals.splitVertical": KeyBinding(key: "d", modifiers: [.command]),
                "terminals.splitHorizontal": KeyBinding(key: "d", modifiers: [.command, .shift]),
            ]
        case .slack:
            [
                "global.quickOpen": KeyBinding(key: "k", modifiers: [.command]),
                "team.previousAgent": KeyBinding(key: "↑", modifiers: [.option]),
                "team.nextAgent": KeyBinding(key: "↓", modifiers: [.option]),
            ]
        }
    }
}

/// One saved change to a command's shortcut. A missing `binding` means the user removed it.
struct KeymapChange: Codable, Hashable {
    var command: String
    var binding: KeyBinding?
}

/// The file format of `keymap.v1` and of the exported keymap.
struct KeymapFile: Codable {
    var version: Int = 1
    var changes: [KeymapChange]
}

/// The effective shortcut of every command: the defaults, plus what the user changed.
///
/// Changes are stored as JSON under `keymap.v1`. Menus and views read `binding(for:)`, so a
/// rebinding takes effect everywhere at once.
@MainActor
@Observable
public final class Keymap {
    public static let storageKey = "keymap.v1"

    @ObservationIgnored private let defaults: UserDefaults
    /// Commands whose shortcut the user replaced.
    private var overrides: [String: KeyBinding] = [:]
    /// Commands whose shortcut the user removed.
    private var cleared: Set<String> = []

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    /// The shortcut that applies now, or `nil` when the command has none.
    public func binding(for id: String) -> KeyBinding? {
        if cleared.contains(id) { return nil }
        if let custom = overrides[id] { return custom }
        return Command.find(id)?.defaultBinding
    }

    /// Replaces the shortcut of `id`. `nil` removes it. Setting the default value drops the override.
    public func set(_ binding: KeyBinding?, for id: String) {
        guard let command = Command.find(id) else { return }
        if binding == command.defaultBinding {
            removeOverride(id)
        } else if let binding {
            cleared.remove(id)
            overrides[id] = binding
        } else {
            overrides[id] = nil
            cleared.insert(id)
        }
        save()
    }

    /// Puts the default shortcut of `id` back.
    public func reset(_ id: String) {
        removeOverride(id)
        save()
    }

    public func resetAll() {
        overrides = [:]
        cleared = []
        save()
    }

    public func isCustomized(_ id: String) -> Bool {
        overrides[id] != nil || cleared.contains(id)
    }

    /// How many commands differ from the defaults.
    public var customizedCount: Int {
        Set(overrides.keys).union(cleared).count
    }

    /// Commands that would answer `binding` in `context`: the same context, or a global command,
    /// and every command when `context` is global. `excluding` is the command being rebound.
    public func conflicts(for binding: KeyBinding, in context: KeyContext, excluding id: String? = nil) -> [Command] {
        Command.all.filter { command in
            guard command.id != id, self.binding(for: command.id) == binding else { return false }
            return command.context == context || command.context == .global || context == .global
        }
    }

    /// Replaces every shortcut with the preset's ones. The default bindings stay as they are for the rest.
    public func apply(preset: KeymapPreset) {
        overrides = [:]
        cleared = []
        for (id, binding) in preset.overrides {
            set(binding, for: id)
        }
        save()
    }

    /// The overrides as JSON, for Export.
    public func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(currentFile())
    }

    /// Replaces the overrides with the ones in `data`, for Import. Unknown commands are skipped.
    public func importData(_ data: Data) throws {
        let file = try JSONDecoder().decode(KeymapFile.self, from: data)
        overrides = [:]
        cleared = []
        apply(changes: file.changes)
        save()
    }

    private func removeOverride(_ id: String) {
        overrides[id] = nil
        cleared.remove(id)
    }

    private func apply(changes: [KeymapChange]) {
        for change in changes where Command.find(change.command) != nil {
            if let binding = change.binding {
                if binding == Command.find(change.command)?.defaultBinding {
                    continue
                }
                overrides[change.command] = binding
            } else {
                cleared.insert(change.command)
            }
        }
    }

    private func currentFile() -> KeymapFile {
        let ids = Set(overrides.keys).union(cleared).sorted()
        let changes = ids.map { id in KeymapChange(command: id, binding: overrides[id]) }
        return KeymapFile(changes: changes)
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey),
            let file = try? JSONDecoder().decode(KeymapFile.self, from: data)
        else { return }
        apply(changes: file.changes)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(currentFile()) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
