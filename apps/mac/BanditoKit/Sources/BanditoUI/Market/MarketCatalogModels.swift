import BanditoKit
import Foundation
import Observation
import os

/// The bot templates of the server in front. Read once per server; `reset()` forgets them when the server changes.
@MainActor
@Observable
final class BotsMarketModel {
    private static let log = Logger(subsystem: "dev.bandito", category: "bundles")

    private(set) var templates: [BotTemplate] = []
    /// The sets of bots (`agents.bundles`); empty on a server without the `agent_bundles` feature, or when they failed.
    private(set) var bundles: [AgentBundle] = []
    /// Why the sets did not load. The bots still show; the page offers a retry.
    private(set) var bundlesFailure: UserFacingMessage?
    private(set) var loaded = false
    private(set) var failure: UserFacingMessage?
    /// Changes with each reset, so an answer for the server that was in front is dropped.
    @ObservationIgnored private var generation = 0

    func reset() {
        generation += 1
        templates = []
        bundles = []
        bundlesFailure = nil
        loaded = false
        failure = nil
    }

    func load(from server: ServerModel, force: Bool = false) async {
        guard server.supports("agent_templates"), force || !loaded else { return }
        let started = generation
        do {
            let list = try await server.botTemplates()
            // The sets are an extra: a failed read is logged and offered again, and the bots still show.
            var sets: [AgentBundle] = []
            var setsFailure: UserFacingMessage?
            if server.supports("agent_bundles") {
                do {
                    sets = try await server.agentBundles()
                } catch {
                    Self.log.error("agents.bundles failed: \(String(describing: error), privacy: .public)")
                    setsFailure = UserFacingError.message(for: error)
                }
            }
            guard !Task.isCancelled, started == generation else { return }
            templates = list
            bundles = sets
            bundlesFailure = setsFailure
            loaded = true
            failure = nil
        } catch {
            guard !Task.isCancelled, started == generation else { return }
            failure = UserFacingError.message(for: error)
        }
    }
}

/// The skills of the server in front, with where each one is installed. Read again whenever the page opens and
/// after every install or remove, so the state shown is the daemon's.
@MainActor
@Observable
final class SkillsMarketModel {
    private(set) var skills: [SkillEntry] = []
    private(set) var loaded = false
    private(set) var failure: UserFacingMessage?
    /// Installs and removes in flight, by `busyKey`: a second press on the same one is ignored.
    private(set) var busy: Set<String> = []
    @ObservationIgnored private var generation = 0

    nonisolated static func busyKey(_ skillID: String, _ target: SkillLogic.Target) -> String {
        switch target {
        case .everyone: "\(skillID)|user"
        case .agent(let id): "\(skillID)|\(id)"
        }
    }

    func reset() {
        generation += 1
        skills = []
        loaded = false
        failure = nil
        busy = []
    }

    func load(from server: ServerModel) async {
        guard server.supports("skills") else { return }
        let started = generation
        do {
            let list = try await server.skillCatalog()
            guard !Task.isCancelled, started == generation else { return }
            skills = list
            loaded = true
            failure = nil
        } catch {
            guard !Task.isCancelled, started == generation else { return }
            failure = UserFacingError.message(for: error)
        }
    }

    /// Installs or removes a skill, then reads the catalog again. Returns nil when it went through, else why not.
    /// A press while the same action is running does nothing.
    func change(_ skillID: String, target: SkillLogic.Target, install: Bool, on server: ServerModel) async -> Error? {
        let key = Self.busyKey(skillID, target)
        guard !busy.contains(key) else { return nil }
        busy.insert(key)
        defer { busy.remove(key) }
        let started = generation
        do {
            if install {
                try await server.installSkill(skillID, scope: target.scope)
            } else {
                try await server.removeSkill(skillID, scope: target.scope)
            }
        } catch {
            // The folder may have changed anyway (a refused install after a partial state): show the truth again.
            if started == generation { await load(from: server) }
            return error
        }
        if started == generation { await load(from: server) }
        return nil
    }
}
