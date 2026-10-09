import Foundation

/// Appends lines to an ssh `known_hosts` file without losing anything that is already there.
///
/// The existing bytes are read first; a read failure stops everything, and nothing is written. The new file is
/// assembled in a temporary file in the same folder and moved over the old one, so a crash leaves either the
/// old file or the new one. Permissions of an existing file are kept; a new file gets 0600, and a new folder 0700.
public enum KnownHostsFile {
    public static func append(lines: [String], to url: URL) throws {
        let fileManager = FileManager.default
        let folder = url.deletingLastPathComponent()

        var existing = Data()
        var mode = 0o600
        if fileManager.fileExists(atPath: url.path) {
            do {
                existing = try Data(contentsOf: url)
            } catch {
                throw SSHHostKeyError.readFailed(url.lastPathComponent)
            }
            if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                let permissions = attributes[.posixPermissions] as? NSNumber
            {
                mode = permissions.intValue
            }
        }

        var addition = ""
        if let last = existing.last, last != UInt8(ascii: "\n") {
            addition += "\n"
        }
        addition += lines.map { $0 + "\n" }.joined()
        var content = existing
        content.append(Data(addition.utf8))

        let temporary = folder.appending(path: ".known_hosts.bandito-\(UUID().uuidString).tmp")
        do {
            if !fileManager.fileExists(atPath: folder.path) {
                try fileManager.createDirectory(
                    at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            try content.write(to: temporary, options: .withoutOverwriting)
            try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: temporary.path)
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: url)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw SSHHostKeyError.writeFailed(url.lastPathComponent)
        }
    }
}
