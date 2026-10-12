import AppKit
import BanditoUI

/// `Bandito --perf-check` runs only the smoothness check (`PerfStandalone`): none of the app starts, so it can be
/// measured on any Mac without touching its Bandito. Without the switch, the app.
@main
enum Main {
    static func main() {
        if PerfStandalone.isRequested() {
            MainActor.assumeIsolated { PerfStandalone.run() }
        } else {
            BanditoApp.main()
        }
    }
}
