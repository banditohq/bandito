import BanditoKit
import Foundation
import Observation

/// What happened to one item.
struct ImportLine: Identifiable, Equatable {
    enum Outcome: Equatable {
        case created
        case skipped(Reason)
        case failed(UserFacingMessage)
    }

    /// Why an item was left.
    enum Reason: Equatable {
        /// The person chose to leave it.
        case byYou
        /// The server already has one by that name, and Bandito never replaces it.
        case exists
        /// The file or folder was not taken when it was read.
        case notRead(ImportSkipReason)
    }

    var id: String
    var kind: ImportKind
    var name: String
    var outcome: Outcome
}

/// Makes what the person chose, one thing after the other: an agent with `agents.create`, a command or a skill with
/// `commands.install` into the server user's home. Nothing is replaced (`overwrite` stays off) and nothing on the Mac is
/// touched. The report keeps every item's end, so the screen can say what was made and what was not, and why.
@MainActor
@Observable
final class ImportRunner {
    private(set) var running = false
    private(set) var finished = false
    private(set) var lines: [ImportLine] = []
    /// How many of the steps are done, for the button.
    private(set) var done = 0

    @ObservationIgnored private var task: Task<Void, Never>?

    /// Starts the import. A second call while it runs, or after it ran, does nothing.
    func start(plan: ImportPlan, scanSkips: [ImportSkip], server: ServerModel, runtime: RuntimeKind) {
        guard !running, !finished else { return }
        running = true
        let steps = plan.steps
        var report: [ImportLine] = plan.skippedByYou.map {
            ImportLine(id: $0.id, kind: $0.kind, name: $0.name, outcome: .skipped(.byYou))
        }
        report += scanSkips.map {
            ImportLine(id: "scan|\($0.path)", kind: .command, name: $0.path, outcome: .skipped(.notRead($0.reason)))
        }
        lines = report
        task = Task { [weak self] in
            for step in steps {
                if Task.isCancelled { break }
                let outcome = await Self.make(step, server: server, runtime: runtime)
                guard let self else { return }
                self.lines.append(ImportLine(id: step.id, kind: step.item.kind, name: step.name, outcome: outcome))
                self.done += 1
            }
            self?.running = false
            self?.finished = true
        }
    }

    /// Stops after the thing being made; what was made stays.
    func cancel() {
        task?.cancel()
    }

    private static func make(_ step: ImportPlan.Step, server: ServerModel, runtime: RuntimeKind) async -> ImportLine.Outcome {
        do {
            switch step.item.payload {
            case .agent(let agent):
                _ = try await server.createAgent(request(agent, name: step.name, runtime: runtime, lists: server.runtimeModels))
            case .command(let command):
                try await server.installCommand(installRequest(command, kind: step.item.kind, name: step.name))
            }
            return .created
        } catch {
            if case .reason("exists") = FailureKind.classify(error) { return .skipped(.exists) }
            return .failed(UserFacingError.message(for: error))
        }
    }

    /// The agent as `agents.create` takes it. The agent works in its own folder (the server gives it one when `cwd` is
    /// empty), the model is sent only when the runtime offers it, and the capabilities follow the file's tools.
    nonisolated static func request(
        _ agent: ImportedAgent, name: String, runtime: RuntimeKind, lists: [String: RuntimeModelList]
    ) -> NewAgent {
        NewAgent(
            name: name, role: agent.role, runtime: runtime,
            model: ImportAgentParser.model(agent.model, runtime: runtime, lists: lists), cwd: "",
            systemPrompt: agent.instructions, capabilities: agent.capabilities)
    }

    /// The install request of a command or a skill, without `overwrite`. A skill goes as its folder; a command is the one
    /// file, named for the last part of its name.
    nonisolated static func installRequest(_ command: MacCommand, kind: ImportKind, name: String) -> CommandInstallRequest {
        let files: [CommandFile]
        if kind == .command, let only = command.files.first {
            let leaf = name.split(separator: ":").last.map(String.init) ?? name
            files = [CommandFile(path: leaf + ".md", content: only.data.base64EncodedString())]
        } else {
            files = command.files.map { CommandFile(path: $0.path, content: $0.data.base64EncodedString()) }
        }
        return CommandInstallRequest(
            scope: "user", kind: kind == .skill ? .skill : .command, name: name, files: files, overwrite: false)
    }
}
