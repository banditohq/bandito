import BanditoL10n
import Foundation

/// The daemon's reason for asking, in words: `risky: rm -r` → "deletes a whole folder". An unknown reason is shown as
/// it came, after "rule:".
public enum ApprovalReason {
    public static func text(_ reason: String) -> String {
        let r = reason.trimmingCharacters(in: .whitespaces)
        if r.hasPrefix("risky: ") {
            let rule = String(r.dropFirst("risky: ".count))
            switch rule {
            case "rm -r": return L10n.Approval.Why.deleteFolder
            case "git push": return L10n.Approval.Why.gitPush
            case "sql": return L10n.Approval.Why.sql
            case "sudo": return L10n.Approval.Why.sudo
            case "npm publish", "cargo publish": return L10n.Approval.Why.publish
            default: return L10n.Approval.Why.risky(rule: rule)
            }
        }
        if r.hasPrefix("reads credentials: ") {
            return L10n.Approval.Why.credentials(folder: String(r.dropFirst("reads credentials: ".count)))
        }
        if r.hasPrefix("writes outside ") { return L10n.Approval.Why.outside }
        if r.hasPrefix("can't check") { return L10n.Approval.Why.cantCheck }
        if r == "approval required for every action" { return L10n.Approval.Why.always }
        if r.hasPrefix("rule: ") { return L10n.Approval.Why.yourRule(rule: String(r.dropFirst("rule: ".count))) }
        if r == "touches Bandito's files by name" { return L10n.Approval.Why.bandito }
        if r == "agent: create" { return L10n.AgentCreate.why }
        if r == "service: confirm changes" { return L10n.Approval.Why.serviceConfirm }
        if r == "service: confirm tool" { return L10n.Approval.Why.serviceTool }
        return L10n.Approval.rule(rule: r)
    }

    /// Whether the daemon marks the request as risky: a rule the person set as risky (`risky: <rule>`), a credential
    /// read, a write outside the project, or a touch of Bandito's own files. The phone asks for Face ID before such a
    /// request is allowed (`IOSSettings.riskyNeedsFaceID`). Other reasons are not risky: they only say why it asks.
    public static func isRisky(_ reason: String) -> Bool {
        let r = reason.trimmingCharacters(in: .whitespaces)
        return r.hasPrefix("risky: ") || r.hasPrefix("reads credentials: ") || r.hasPrefix("writes outside ")
            || r == "touches Bandito's files by name"
    }
}
