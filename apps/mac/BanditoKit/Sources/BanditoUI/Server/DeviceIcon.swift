/// The symbol that stands for a device: a laptop for a Mac, a phone for an iPhone, a desktop for anything else.
/// A platform the server reports wins. Otherwise the name decides, and only for the Mac models named in full:
/// a name that merely contains "mac" is not taken for a Mac.
enum DeviceIcon {
    static func symbol(platform: String?, name: String) -> String {
        switch platform?.lowercased() {
        case "macos": return "laptopcomputer"
        case "ios": return "iphone"
        default: break
        }
        let lower = name.lowercased()
        if lower.contains("macbook") { return "laptopcomputer" }
        if lower.contains("iphone") { return "iphone" }
        if lower.contains("ipad") { return "ipad" }
        // iMac, Mac mini, Mac Studio and Mac Pro are desktops; anything else gets the generic desktop too.
        return "desktopcomputer"
    }
}

extension DeviceIcon {
    /// The Mac model that a device name names in full ("Ivan's MacBook Pro" → "MacBook Pro"). Nil when it names none.
    static func macModel(in name: String) -> String? {
        let lower = name.lowercased()
        return ["MacBook Pro", "MacBook Air", "MacBook", "Mac mini", "Mac Studio", "Mac Pro", "iMac"]
            .first { lower.contains($0.lowercased()) }
    }
}
