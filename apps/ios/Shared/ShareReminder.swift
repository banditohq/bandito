import Foundation

/// The local notification the share sheet leaves ("Open to send the task to Forge"): its id and its link. The app takes
/// it down once it has the task, and a press on it opens the link.
enum ShareReminder {
    static let userInfoKey = "link"

    static func identifier(for taskID: UUID) -> String {
        "share-\(taskID.uuidString)"
    }
}
