import BanditoKit
import Foundation

#if os(macOS)
import Darwin
#endif

/// The Mac's model, in the words people use ("MacBook Pro"). The hardware identifier (`hw.model`, such as
/// "MacBookPro18,3") gives it for the Intel and older models. Newer identifiers ("Mac15,3") name no family, so the
/// device's name decides then, as before. Nil when neither names a model.
enum MacModel {
    /// Identifier prefixes, most specific first.
    static let prefixes: [(prefix: String, name: String)] = [
        ("MacBookPro", "MacBook Pro"),
        ("MacBookAir", "MacBook Air"),
        ("MacBook", "MacBook"),
        ("Macmini", "Mac mini"),
        ("iMac", "iMac"),
        ("MacStudio", "Mac Studio"),
        ("MacPro", "Mac Pro"),
    ]

    /// The model named by a hardware identifier, or nil for an identifier that names no family.
    static func name(hardwareModel: String?) -> String? {
        guard let hardwareModel, !hardwareModel.isEmpty else { return nil }
        return prefixes.first { hardwareModel.hasPrefix($0.prefix) }?.name
    }

    /// The model for this Mac: from the identifier when it names a family, else from the device's name.
    static func current(hardwareModel: String? = hardwareIdentifier(), deviceName: String = DeviceDescriptor.current.name) -> String? {
        name(hardwareModel: hardwareModel) ?? DeviceIcon.macModel(in: deviceName)
    }

    /// `hw.model` of this Mac, or nil when the system does not answer.
    static func hardwareIdentifier() -> String? {
        #if os(macOS)
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
        #else
        return nil
        #endif
    }
}
