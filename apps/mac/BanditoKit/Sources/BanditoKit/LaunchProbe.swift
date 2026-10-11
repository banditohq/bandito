import Foundation

/// Tests only: hears what a piece of code started that touches the person's own Bandito (the model of the saved
/// servers, a pairing with this Mac's daemon). Task-local, so a test hears only the code it runs itself; nothing in
/// the app sets it.
public enum LaunchProbe {
    @TaskLocal public static var record: (@Sendable (String) -> Void)?
}
