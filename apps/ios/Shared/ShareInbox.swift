import Foundation

// What the share extension hands to the app. The extension never talks to a server and never reads a token: it writes
// the task (the agent, the text, the pictures) into a folder of the App Group and opens the app, which sends it through
// its own queue. The app and the extension both compile this file, so they agree on the folder.

/// A picture that is already on the server: what `ChatOutbox` needs to attach it. Kept in `task.json`, so a task that
/// is tried again does not upload the same picture twice.
struct SharedUpload: Codable, Equatable, Sendable {
    let path: String
    let name: String
    let size: Int64
    let mime: String
}

/// One message a person shared to an agent from another app.
struct SharedTask: Codable, Equatable, Sendable {
    /// After this many failed uploads (with the server connected) the task is dropped.
    static let maxAttempts = 5

    let id: UUID
    /// The server's id (a UUID string), as the widget snapshot names it. Never an address.
    let serverID: String
    let agentID: String
    let text: String
    /// File names of the pictures inside the task's folder (`0.jpg`, `1.jpg`, ...), in the order they were shared.
    let images: [String]
    let createdAt: Date
    /// The agent's name when it was shared, for the notice that says what became of the task. Empty in old files.
    var agentName: String = ""
    /// Failed picture uploads so far. Old files have none: 0.
    var attempts: Int = 0
    /// The pictures that are on the server already, by file name.
    var uploaded: [String: SharedUpload] = [:]

    init(
        id: UUID, serverID: String, agentID: String, text: String, images: [String], createdAt: Date,
        agentName: String = "", attempts: Int = 0, uploaded: [String: SharedUpload] = [:]
    ) {
        self.id = id
        self.serverID = serverID
        self.agentID = agentID
        self.text = text
        self.images = images
        self.createdAt = createdAt
        self.agentName = agentName
        self.attempts = attempts
        self.uploaded = uploaded
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        serverID = try c.decode(String.self, forKey: .serverID)
        agentID = try c.decode(String.self, forKey: .agentID)
        text = try c.decode(String.self, forKey: .text)
        images = try c.decode([String].self, forKey: .images)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        agentName = try c.decodeIfPresent(String.self, forKey: .agentName) ?? ""
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        uploaded = try c.decodeIfPresent([String: SharedUpload].self, forKey: .uploaded) ?? [:]
    }

    /// The name to say in a notice: the agent's, else its id.
    var displayName: String { agentName.isEmpty ? agentID : agentName }
}

/// The folder `<App Group>/Share/`: each task is a sub-folder named by its id, with `task.json` and its pictures.
struct ShareInbox: Sendable {
    /// A task nobody took within this long is dropped (the app was not opened, or the server is gone).
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    static let taskFileName = "task.json"
    static let folderName = "Share"

    let root: URL

    /// The inbox in the App Group container; nil when the group is not available (an unsigned build, no entitlement).
    static func appGroup(fileManager: FileManager = .default) -> ShareInbox? {
        guard let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: WidgetAppGroup.identifier)
        else { return nil }
        return ShareInbox(root: container.appendingPathComponent(folderName, isDirectory: true))
    }

    private static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]

    private func folder(_ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Writes the pictures first and `task.json` last, so a task that is only half written has no `task.json` and is
    /// never offered by `pending`. Returns the task as stored: its pictures are named `0.jpg`, `1.jpg`, ...
    @discardableResult
    func save(_ task: SharedTask, images: [Data]) throws -> SharedTask {
        let stored = SharedTask(
            id: task.id, serverID: task.serverID, agentID: task.agentID, text: task.text,
            images: images.indices.map { "\($0).jpg" }, createdAt: task.createdAt, agentName: task.agentName,
            attempts: task.attempts, uploaded: task.uploaded)
        let directory = folder(task.id)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            for (index, data) in images.enumerated() {
                try data.write(to: directory.appendingPathComponent(stored.images[index]), options: Self.writeOptions)
            }
            try Self.encoder.encode(stored)
                .write(to: directory.appendingPathComponent(Self.taskFileName), options: Self.writeOptions)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
        return stored
    }

    /// Writes the task's `task.json` again (its attempts and uploaded pictures changed). Nothing happens when the task's
    /// folder is gone.
    func update(_ task: SharedTask) {
        let file = folder(task.id).appendingPathComponent(Self.taskFileName)
        guard FileManager.default.fileExists(atPath: file.path),
              let data = try? Self.encoder.encode(task) else { return }
        try? data.write(to: file, options: Self.writeOptions)
    }

    /// The tasks waiting, the oldest first. A folder without a readable `task.json` is skipped.
    func pending() -> [SharedTask] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        var tasks: [SharedTask] = []
        for entry in entries {
            guard let id = UUID(uuidString: entry.lastPathComponent),
                  let data = try? Data(contentsOf: entry.appendingPathComponent(Self.taskFileName)),
                  let task = try? Self.decoder.decode(SharedTask.self, from: data), task.id == id
            else { continue }
            tasks.append(task)
        }
        return tasks.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    /// One task by id, nil when it is gone or unreadable.
    func task(id: UUID) -> SharedTask? {
        pending().first { $0.id == id }
    }

    /// The bytes of one of the task's pictures. The name must be a plain file name of the task, never a path.
    func imageData(task: SharedTask, name: String) -> Data? {
        guard task.images.contains(name), name == (name as NSString).lastPathComponent else { return nil }
        return try? Data(contentsOf: folder(task.id).appendingPathComponent(name))
    }

    /// Deletes the task and its pictures. A task that is not there is not an error.
    func remove(id: UUID) {
        try? FileManager.default.removeItem(at: folder(id))
    }

    /// Deletes tasks older than `age`, and folders that never got a readable `task.json` once their folder is that old.
    func removeOlder(than age: TimeInterval = ShareInbox.maxAge, now: Date = Date()) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        else { return }
        let cutoff = now.addingTimeInterval(-age)
        for entry in entries {
            let created: Date?
            if let id = UUID(uuidString: entry.lastPathComponent),
               let data = try? Data(contentsOf: entry.appendingPathComponent(Self.taskFileName)),
               let task = try? Self.decoder.decode(SharedTask.self, from: data), task.id == id {
                created = task.createdAt
            } else {
                created = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            }
            if let created, created < cutoff { try? fileManager.removeItem(at: entry) }
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
