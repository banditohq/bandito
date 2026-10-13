#if DEBUG
import Foundation
import UIKit

/// Launch arguments for the screenshots and the UI tests (debug builds only):
/// `-chat <agent name>` opens that agent's chat from the Crew (`CrewScreen`),
/// `-chat-draft <text>` puts the text in the message box and opens the keyboard,
/// `-chat-send <text>` sends a message as soon as the chat is on screen,
/// `-chat-top` scrolls to the first message,
/// `-chat-row <part of a row id>` puts that row at the top of the screen.
@MainActor
enum ChatLaunchHooks {
    static func value(after flag: String, in arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    static func apply(to controller: ChatViewController) {
        let arguments = ProcessInfo.processInfo.arguments
        if let draft = value(after: "-chat-draft", in: arguments) {
            controller.composer.text = draft
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(900))
                controller.composer.textField.becomeFirstResponder()
            }
        }
        if let text = value(after: "-chat-send", in: arguments) {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(900))
                controller.composer.text = text
                controller.composer.send()
            }
        }
        if let part = value(after: "-chat-row", in: arguments) {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1200))
                controller.scrollToRow(idContaining: part)
            }
        }
        if arguments.contains("-chat-top") {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1200))
                controller.collectionView.setContentOffset(.zero, animated: false)
            }
        }
    }
}
#endif
