import BanditoKit

/// Which listening ports the Ports screen and the overview show. Ports of agents and terminals always. Other ports
/// only in 3000–9999, and not the ones macOS keeps for itself (AirPlay Receiver, Control Center, Handoff and the like).
enum PreviewPorts {
    /// AirPlay Receiver listens here. It sits in the preview range, and nobody previews it.
    static let systemPorts: Set<Int> = [5000, 7000]
    /// macOS services that listen on the network. lsof cuts process names, so these are prefixes.
    static let systemProcessPrefixes = [
        "ControlCe", "rapportd", "AirPlayXPC", "sharingd", "identitys", "mDNSRespo", "remoted", "launchd",
    ]

    static func isPreviewable(_ port: ListeningPort) -> Bool {
        isPreviewable(number: port.port, process: port.process, owner: port.owner?.kind)
    }

    static func isPreviewable(number: Int, process: String?, owner: ProcessOwnerKind?) -> Bool {
        if owner == .agent || owner == .terminal { return true }
        guard (3000...9999).contains(number), !systemPorts.contains(number) else { return false }
        if let process, systemProcessPrefixes.contains(where: { process.hasPrefix($0) }) { return false }
        return true
    }
}
