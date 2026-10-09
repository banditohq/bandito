import BanditoL10n
import Foundation

/// The line the thread shows when an agent moves between runtimes (`runtime.switched`).
public enum RuntimeSwitchNote {
    /// The display name of a runtime kind. Unknown kinds are shown as the daemon sent them.
    public static func runtimeName(_ raw: String) -> String {
        switch raw {
        case "claude": "Claude"
        case "codex": "Codex"
        case "grok": "Grok"
        default: raw
        }
    }

    /// "Лимит Claude кончился — продолжаю на Codex до 18:20", or "Вернулся на Claude" when `to` is the agent's
    /// primary runtime. `until` is Unix seconds; without it no clock time is shown.
    public static func text(
        from: String, to: String, until: Int64?, primary: String, timeZone: TimeZone = .current
    ) -> String {
        if to == primary {
            return L10n.Thread.runtimeReturned(runtime: runtimeName(to))
        }
        let fromName = runtimeName(from)
        let toName = runtimeName(to)
        if let until {
            return L10n.Thread.runtimeLimitUntil(from: fromName, to: toName, time: clock(until, in: timeZone))
        }
        return L10n.Thread.runtimeLimit(from: fromName, to: toName)
    }

    /// 24-hour HH:mm in `timeZone`, the way the daemon's reset time is shown to the user.
    static func clock(_ unixSeconds: Int64, in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(unixSeconds)))
    }
}
