import Foundation

/// What Return does in the message field: plain Return sends the message; Shift or Option with Return makes a new line.
enum ComposerReturn {
    enum Action: Equatable {
        case send
        case newLine
    }

    static func action(shift: Bool, option: Bool) -> Action {
        shift || option ? .newLine : .send
    }
}
