#if os(macOS)
import AppKit
import BanditoDesign
import BanditoKit
import BanditoL10n
import Foundation

/// The smoothness check as a program of its own: `Bandito --perf-check` opens only the check's window and runs every
/// page on the demo daemons, so it can be measured on anyone's Mac without touching their Bandito.
///
/// Nothing of the app proper starts: no `AppModel` with the saved servers (the demo world has its own, never saved),
/// no pairing with this Mac's daemon, no embedded daemon, no Keychain, no account, no statistics, no updates (the
/// app's `AppUpdater` is never made), no sounds. The defaults it writes are its own suite (`PerfDemoWorld`) and the
/// keys a run changes are put back (`DefaultsGuard`). At the end the window shows the table with "Copy", and the
/// results are saved as JSON in Application Support (the path is printed on standard output).
public enum PerfStandalone {
    /// The command-line switch.
    public static let argument = "--perf-check"

    public static func isRequested(_ arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.contains(argument)
    }

    /// Runs the check as the whole program; returns when the person quits.
    @MainActor
    public static func run() -> Never {
        let app = NSApplication.shared
        let delegate = PerfStandaloneDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.mainMenu = PerfStandaloneDelegate.menu()
        withExtendedLifetime(delegate) { app.run() }
        exit(0)
    }

    /// Where the results of a run finished at `date` are saved: `~/Library/Application Support/<bundle id>/`.
    static func resultsURL(bundleID: String?, date: Date, support: URL? = nil) -> URL {
        let base =
            support ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return base.appending(path: bundleID ?? "dev.bandito.mac.perf", directoryHint: .isDirectory)
            .appending(path: "perf-check-\(formatter.string(from: date)).json")
    }

    /// The saved file: the reports, with the screen and the system they were measured on.
    struct Results: Codable {
        var version: String
        var system: String
        var screenFPS: Int
        var reports: [PerfReport]
    }

    /// Writes the results and returns where.
    @discardableResult
    static func save(_ reports: [PerfReport], fps: Int, to url: URL) throws -> URL {
        let results = Results(
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            system: ProcessInfo.processInfo.operatingSystemVersionString, screenFPS: fps, reports: reports)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(results).write(to: url, options: .atomic)
        return url
    }
}

@MainActor
private final class PerfStandaloneDelegate: NSObject, NSApplicationDelegate {
    private var controller: PerfCheckWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = BanditoFont.registerBundledFonts()
        HangMonitor.start()
        // For the whole program, not only during the run: nothing here is a use of Bandito.
        Telemetry.isPaused = true
        SoundPlayer.isMuted = true
        let controller = PerfCheckWindowController()
        controller.keepsSilent = true
        self.controller = controller
        controller.onClose = { NSApp.terminate(nil) }
        controller.showWindow(nil)
        NSApp.activate()
        controller.window?.makeKeyAndOrderFront(nil)
        controller.run(PerfScenario.allCases) { [weak controller] reports in
            let fps = controller?.state.screenFPS ?? 60
            let url = PerfStandalone.resultsURL(bundleID: Bundle.main.bundleIdentifier, date: Date())
            do {
                try PerfStandalone.save(reports, fps: fps, to: url)
                print("perf-check: \(url.path)")
            } catch {
                print("perf-check: could not save the results: \(error.localizedDescription)")
            }
            print(PerfCheck.text(reports, fps: fps))
            fflush(stdout)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// The application menu with Quit, and Edit for ⌘C in the table.
    static func menu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: L10n.PerfCheck.quit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        return main
    }
}
#endif
