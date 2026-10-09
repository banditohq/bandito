import Foundation

/// Rules of "Clone from a link" in the folder picker. Pure, so they can be tested.
enum CloneLogic {
    /// The folder a clone goes to: `name` inside `parent` (the folder on screen).
    static func destination(parent: String, name: String) -> String {
        parent.hasSuffix("/") ? parent + name : parent + "/" + name
    }

    /// A name that is one plain folder name: not empty, no slash, not "." or "..".
    static func isValidName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed != "." && trimmed != ".." && !trimmed.contains("/")
    }
}
