import Foundation

@testable import BanditoKit

/// The real daemon of this repository (`daemon/target/debug/bandito`) in a temporary data folder, on a port of its own, for
/// the tests that talk to it. Never the person's own daemon: its folder, socket and port are made for the test, and the folder
/// goes with it. A test that needs it is skipped when the binary is not built (`cargo build --bin bandito` in `daemon/`, or
/// `BANDITO_DAEMON_BIN`).
final class DaemonProcess: @unchecked Sendable {
    static var binary: URL? {
        if let path = ProcessInfo.processInfo.environment["BANDITO_DAEMON_BIN"], FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        // …/apps/mac/BanditoKit/Tests/BanditoKitTests/Connect/DaemonProcess.swift → the repository root is 7 levels up.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        let candidate = url.appending(path: "daemon/target/debug/bandito")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    static var isAvailable: Bool { binary != nil }

    let home: URL
    let socketPath: String
    let port: Int
    private let process = Process()

    init() throws {
        guard let binary = Self.binary else { throw URLError(.fileDoesNotExist) }
        // A short path: a unix socket path is limited to about 100 bytes.
        home = URL(fileURLWithPath: "/tmp/bd-\(UUID().uuidString.prefix(8).lowercased())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        socketPath = home.appending(path: "bandito.sock").path
        port = Self.freePort()
        process.executableURL = binary
        process.arguments = ["--home", home.path, "daemon", "--listen", "127.0.0.1:\(port)"]
        var environment = ProcessInfo.processInfo.environment
        environment["BANDITO_HOME"] = home.path
        environment["BANDITO_RELAY_ALLOW_LOOPBACK_PLAIN"] = "1"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        // The socket appears when the daemon is up.
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: socketPath) { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        stop()
        throw URLError(.timedOut)
    }

    /// The config of a server on this daemon, reached over its unix socket (the owner, like the app on that Mac).
    func localConfig(id: UUID = UUID(), name: String = "Studio") -> ServerConfig {
        ServerConfig(id: id, name: name, endpoint: .local(socketPath: socketPath))
    }

    func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: home)
    }

    private static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &length) }
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
