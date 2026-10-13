import BanditoL10n

/// The group's headline from the state of its calls: still running (a call may be waiting for an approval), none ran
/// (all failed or were declined), or done.
public enum ToolGroupTitle {
    public static func text(oks: [Bool?]) -> String {
        if oks.contains(where: { $0 == nil }) { return L10n.Thread.runningCommands(count: oks.count) }
        if !oks.isEmpty, oks.allSatisfy({ $0 == false }) { return L10n.Thread.notRanCommands(count: oks.count) }
        return L10n.Thread.ranCommands(count: oks.count)
    }
}
