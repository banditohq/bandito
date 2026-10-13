import Foundation

// The agents and schedules of the demo daemon: the create, edit and delete flows (`agents.create`, `agents.update`,
// `agents.delete`, `agents.create_bundle`, `schedules.*`). Kept in wire form (snake_case), as the daemon answers them,
// so the app decodes the same objects it gets from a real server. Errors carry the daemon's codes (`rpc/mod.rs`).
// Nothing is written anywhere else.

extension DemoDaemonTransport {
    /// Puts an agent the app installs into the daemon's list, so `agents.list`, `agents.update` and `agents.delete`
    /// know it. A later call with the same id replaces it.
    public func remember(_ agent: Agent) {
        guard let wire = DemoWire.object(agent) else { return }
        demoAgents.removeAll { ($0["id"] as? String) == agent.id }
        demoAgents.append(wire)
    }

    /// Puts a schedule into the daemon's list (`schedules.list` answers it for its agent), as `schedules.rs` shapes it.
    public func rememberSchedule(
        id: String, agentID: String, cron: String, tz: String, prompt: String, title: String?, enabled: Bool
    ) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        demoSchedules.append(
            DemoWire.schedule(
                id: id, agentID: agentID, cron: cron, tz: tz, prompt: prompt, title: title, enabled: enabled, now: now))
    }

    /// Makes `agents.create_bundle` answer the template with an `error` and no agent (`true`), or make it again
    /// (`false`). For the tests of a team that is made in two steps.
    public func failBundleEntry(templateID: String, failing: Bool) {
        if failing {
            demoBundleFailures.insert(templateID)
        } else {
            demoBundleFailures.remove(templateID)
        }
    }

    /// Answers the agent and schedule methods; nil when `method` is not one of them.
    func answerAgents(_ method: String, _ params: [String: Any], now: Int64) -> Result<String, RPCError>? {
        switch method {
        case "agents.list":
            return .success(DemoJSON.text(demoAgents))
        case "agents.create":
            guard let agent = addAgent(params, now: now) else { return .failure(Self.badParams("name is required")) }
            return .success(DemoJSON.text(agent))
        case "agents.update":
            return updateAgent(params, now: now)
        case "agents.delete":
            guard let id = params["id"] as? String else { return .failure(Self.badParams("id is required")) }
            let before = demoAgents.count
            demoAgents.removeAll { ($0["id"] as? String) == id }
            return .success(DemoJSON.text(["deleted": demoAgents.count < before]))
        case "agents.create_bundle":
            return createBundle(params, now: now)
        case "schedules.list":
            let agentID = params["agent_id"] as? String
            let list = demoSchedules.filter { agentID == nil || ($0["agent_id"] as? String) == agentID }
            return .success(DemoJSON.text(list))
        case "schedules.create":
            guard let agentID = params["agent_id"] as? String, let cron = params["cron"] as? String else {
                return .failure(Self.badParams("agent_id and cron are required"))
            }
            let schedule = DemoWire.schedule(
                id: UUID().uuidString.lowercased(), agentID: agentID, cron: cron,
                tz: params["tz"] as? String ?? "UTC", prompt: params["prompt"] as? String ?? "",
                title: params["title"] as? String, enabled: true, now: now)
            demoSchedules.append(schedule)
            return .success(DemoJSON.text(schedule))
        case "schedules.update":
            guard let id = params["id"] as? String, let index = demoSchedules.firstIndex(where: { ($0["id"] as? String) == id })
            else { return .failure(Self.missing("no schedule with that id")) }
            var changes = params
            changes["id"] = nil
            Self.merge(changes, into: &demoSchedules[index])
            // The words and the next run follow the cron and the switch, as the daemon computes them.
            let cron = demoSchedules[index]["cron"] as? String ?? ""
            let enabled = demoSchedules[index]["enabled"] as? Bool ?? false
            demoSchedules[index]["human_en"] = DemoWire.words(cron: cron, languageCode: "en")
            demoSchedules[index]["human_ru"] = DemoWire.words(cron: cron, languageCode: "ru")
            demoSchedules[index]["next_run_at"] = (enabled ? now + DemoWire.hour : NSNull()) as Any
            return .success(DemoJSON.text(demoSchedules[index]))
        case "schedules.delete":
            guard let id = params["id"] as? String else { return .failure(Self.badParams("id is required")) }
            demoSchedules.removeAll { ($0["id"] as? String) == id }
            return .success(DemoJSON.text(["deleted": true]))
        case "schedules.run_now":
            return .success("{}")
        default:
            return nil
        }
    }

    /// Makes an agent from the create fields, as `agents.create` does: the defaults of the daemon for what is missing.
    @discardableResult
    func addAgent(_ params: [String: Any], now: Int64) -> [String: Any]? {
        guard let name = params["name"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        var agent: [String: Any] = [
            "id": UUID().uuidString.lowercased(), "name": name,
            "role": params["role"] as? String ?? "", "runtime": params["runtime"] as? String ?? "claude",
            "cwd": params["cwd"] as? String ?? DemoDaemonFiles.projects,
            "approval_mode": params["approval_mode"] as? String ?? "risky",
            "memory_mode": params["memory_mode"] as? String ?? "smart", "workspace_id": "shared",
            "paused": false, "lead": false, "created_at": now, "updated_at": now,
            "context_tokens": 0, "chapter": 1, "pending_approvals": 0, "pending_approval_ids": [String](),
        ]
        for key in ["model", "system_prompt", "effort", "context_budget", "fallback_runtime", "fallback_model",
            "avatar", "capabilities", "integrations", "template_id"]
        {
            if let value = params[key], !(value is NSNull) {
                agent[key] = value
            }
        }
        demoAgents.append(agent)
        return agent
    }

    /// Applies an `agents.update` patch: a key with `null` is removed (the default comes back), any other key is set.
    private func updateAgent(_ params: [String: Any], now: Int64) -> Result<String, RPCError> {
        guard let id = params["id"] as? String, let index = demoAgents.firstIndex(where: { ($0["id"] as? String) == id })
        else { return .failure(Self.missing("no agent with that id")) }
        // The fields of the patch sit beside `id` in the request (`AgentPatch` encodes them flat).
        var changes = params
        changes["id"] = nil
        Self.merge(changes, into: &demoAgents[index])
        demoAgents[index]["updated_at"] = now
        // The answer is the agent itself, with the warnings beside its fields (`AgentUpdate` reads it so).
        var reply = demoAgents[index]
        reply["warnings"] = [String]()
        return .success(DemoJSON.text(reply))
    }

    /// Makes the agents of a bundle as `agents.create_bundle` does: one entry per template, the agents named in the
    /// language asked for, and the schedules of the list switched on (every schedule is made, the rest are off). A
    /// template in `demoBundleFailures` gets an `error` and no agent.
    private func createBundle(_ params: [String: Any], now: Int64) -> Result<String, RPCError> {
        guard let bundleID = params["bundle_id"] as? String,
            let bundle = Self.objects(DemoCatalogs.shared.bundles).first(where: { ($0["id"] as? String) == bundleID })
        else { return .failure(Self.missing("no bundle with that id")) }
        let templates = Self.objects(DemoCatalogs.shared.templates)
        let isRussian = (params["language"] as? String ?? "en").lowercased().hasPrefix("ru")
        let members = bundle["templates"] as? [String] ?? []
        let wanted = params["templates"] as? [String] ?? members
        let switchedOn = params["schedules"] as? [String]
        var entries: [[String: Any]] = []
        for templateID in members where wanted.contains(templateID) {
            guard let template = templates.first(where: { ($0["id"] as? String) == templateID }) else { continue }
            if demoBundleFailures.contains(templateID) {
                entries.append(["template_id": templateID, "error": "the agent could not be made"])
                continue
            }
            let name = (isRussian ? template["name_ru"] : template["name_en"]) as? String ?? templateID
            let role = (isRussian ? template["role_ru"] : template["role_en"]) as? String ?? ""
            var fields: [String: Any] = [
                "name": name, "role": role, "runtime": params["runtime"] as? String ?? template["runtime"] as? String ?? "claude",
                "cwd": params["cwd"] as? String ?? DemoDaemonFiles.projects + "/" + name,
                "capabilities": template["capabilities"] as? [String] ?? [], "template_id": templateID,
            ]
            if let model = params["model"] as? String {
                fields["model"] = model
            }
            guard let agent = addAgent(fields, now: now), let agentID = agent["id"] as? String else { continue }
            let schedules = template["schedules"] as? [[String: Any]] ?? []
            for (index, schedule) in schedules.enumerated() {
                let key = "\(templateID):\(index)"
                let enabled = switchedOn.map { $0.contains(key) } ?? (schedule["enabled_by_default"] as? Bool ?? false)
                let prompt = (isRussian ? schedule["prompt_ru"] : schedule["prompt_en"]) as? String ?? ""
                demoSchedules.append(
                    DemoWire.schedule(
                        id: UUID().uuidString.lowercased(), agentID: agentID, cron: schedule["cron"] as? String ?? "",
                        tz: "UTC", prompt: prompt, title: name, enabled: enabled, now: now))
            }
            entries.append(["template_id": templateID, "agent": agent])
        }
        return .success(DemoJSON.text(["agents": entries, "missing_integrations": [[String: Any]]()]))
    }

    // MARK: helpers

    static func merge(_ patch: [String: Any], into object: inout [String: Any]) {
        for (key, value) in patch {
            if value is NSNull {
                object[key] = nil
            } else {
                object[key] = value
            }
        }
    }

    static func objects(_ text: String) -> [[String: Any]] {
        guard let data = text.data(using: .utf8),
            let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return list
    }

    /// `INVALID_PARAMS`: the request is wrong.
    static func badParams(_ message: String) -> RPCError {
        RPCError(code: -32602, message: message)
    }

    /// `SERVER_ERROR`: the daemon could not do it (no such agent, schedule or bundle), as `schedules.rs` answers.
    static func missing(_ message: String) -> RPCError {
        RPCError(code: -32000, message: message)
    }
}

/// Wire forms of the app's models, for the demo daemon's store.
enum DemoWire {
    /// One hour in milliseconds: the next run of a demo schedule is this far away.
    static let hour: Int64 = 3_600_000

    /// The value, or JSON `null` when there is none.
    static func nullable(_ value: String?) -> Any {
        value.map { $0 as Any } ?? NSNull()
    }

    /// A schedule in wire form: the cron in words in both languages (the cron itself when it does not read), the next
    /// run when it is on, and the empty last run.
    static func schedule(
        id: String, agentID: String, cron: String, tz: String, prompt: String, title: String?, enabled: Bool, now: Int64
    ) -> [String: Any] {
        [
            "id": id, "agent_id": agentID, "cron": cron, "tz": tz, "prompt": prompt, "enabled": enabled,
            "created_at": now, "title": nullable(title), "last_run_at": NSNull(),
            "next_run_at": (enabled ? now + hour : NSNull()) as Any,
            "human_en": words(cron: cron, languageCode: "en"), "human_ru": words(cron: cron, languageCode: "ru"),
        ]
    }

    /// The cron in words for `languageCode`, or the cron itself when it does not read.
    static func words(cron: String, languageCode: String) -> String {
        BotScheduleWords.words(cron: cron, languageCode: languageCode) ?? cron
    }

    static func object<T: Encodable>(_ value: T) -> [String: Any]? {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(value),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }
}
