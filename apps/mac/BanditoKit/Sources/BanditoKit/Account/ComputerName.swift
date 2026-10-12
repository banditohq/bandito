#if os(macOS)
import Foundation
import SystemConfiguration

/// The name of this Mac as System Settings shows it.
///
/// `Host.current()` looks the name up on the network: that blocks for seconds without one and makes macOS ask the
/// person for access to the local network. These two calls read the local settings only.
public enum ComputerName {
    /// "Anna's MacBook Pro", or the plain host name, or nil when neither can be read.
    public static func current() -> String? {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty { return name }
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count - 1) == 0 else { return nil }
        let host = String(cString: buffer)
        return host.isEmpty ? nil : host
    }
}
#endif
