import Foundation

// The agents and schedules of the demo daemon: the create, edit and delete flows (`agents.create`, `agents.update`,
// `agents.delete`, `agents.create_bundle`, `schedules.*`). Kept in wire form (snake_case), as the daemon answers them,
// so the app decodes the same objects it gets from a real server. Nothing is written anywhere else.

extension DemoDaemonTransport {
    /// Puts an agent the app installs into the daemon's list, so `agents.list`, `agents.update` and `agents.delete`
    /// know it. A later call with the same id replaces it.
    public func remember(_ agent: Agent) {
        guard let wire = DemoWire.object(agent) else { return }
        demoAgents.removeAll { ($0["id"] as? String) == agent.id }
        demoAgents.append(wire)
    }

    /// Puts a schedule into the daemon's list (`schedules.list` answers it for its agent).
    public func rememberSchedule(
        id: String, agentID: String, cron: String, tz: String, prompt: String, title: String?, enabled: Bool
    ) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        demoSchedules.append([
            "id": id, "agent_id": agentID, "cron": cron, "tz": tz, "prompt": prompt, "enabled": enabled,
            "created_at": now, "next_run_at": NSNull(), "last_run_at": NSNull(), "title": DemoWire.nullable(title),
        ])
    }

    /// Answers the agent and schedule methods; nil when `method` is not one of them.
    func answerAgents(_ method: String, _ params: [String: Any], now: Int64) -> Result<String, RPCError>? {
        switch method {
        case "agents.list":
            return .success(DemoJSON.text(demoAgents))
        case "agents.create":
            guard let agent = addAgent(params, now: now) else { return .failure(DemoDaemonTransport.badParams("name is required")) }
            return .success(DemoJSON.text(agent))
        case "agents.update":
            return updateAgent(params, now: now)
        case "agents.delete":
            guard let id = params["id"] as? String else { return .failure(DemoDaemonTransport.badParams("id is required")) }
            demoAgents.removeAll { ($0["id"] as? String) == id }
            return .success("null")
        case "agents.create_bundle":
            return createBundle(params, now: now)
        case "schedules.list":
            let agentID = params["agent_id"] as? String
            let list = demoSchedules.filter { agentID == nil || ($0["agent_id"] as? String) == agentID }
            return .success(DemoJSON.text(list))
        case "schedules.create":
            guard let agentID = params["agent_id"] as? String, let cron = params["cron"] as? String else {
                return .failure(DemoDaemonTransport.badParams("agent_id and cron are required"))
            }
            let schedule: [String: Any] = [
                "id": UUID().uuidString.lowercased(), "agent_id": agentID, "cron": cron,
                "tz": params["tz"] as? String ?? "UTC", "prompt": params["prompt"] as? String ?? "",
                "enabled": true, "created_at": now, "next_run_at": NSNull(), "last_run_at": NSNull(),
                "title": DemoWire.nullable(params["title"] as? String),
            ]
            demoSchedules.append(schedule)
            return .success(DemoJSON.text(schedule))
        case "schedules.update":
            guard let id = params["id"] as? String, let index = demoSchedules.firstIndex(where: { ($0["id"] as? String) == id })
            else { return .failure(DemoDaemonTransport.missing("no schedule with that id")) }
            var changes = params
            changes["id"] = nil
            DemoDaemonTransport.merge(changes, into: &demoSchedules[index])
            return .success(DemoJSON.text(demoSchedules[index]))
        case "schedules.delete":
            guard let id = params["id"] as? String else { return .failure(DemoDaemonTransport.badParams("id is required")) }
            demoSchedules.removeAll { ($0["id"] as? String) == id }
            return .success("null")
        case "schedules.run_now":
            return .success("null")
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
            "avatar", "capabilities", "integrations"]
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
        else { return .failure(DemoDaemonTransport.missing("no agent with that id")) }
        // The fields of the patch sit beside `id` in the request (`AgentPatch` encodes them flat).
        var changes = params
        changes["id"] = nil
        DemoDaemonTransport.merge(changes, into: &demoAgents[index])
        demoAgents[index]["updated_at"] = now
        // The answer is the agent itself, with the warnings beside its fields (`AgentUpdate` reads it so).
        var reply = demoAgents[index]
        reply["warnings"] = [String]()
        return .success(DemoJSON.text(reply))
    }

    /// Makes the agents of a bundle as `agents.create_bundle` does: one entry per template, the agents named in the
    /// language asked for, and the schedules of the list switched on (every schedule is made, the rest are off).
    private func createBundle(_ params: [String: Any], now: Int64) -> Result<String, RPCError> {
        guard let bundleID = params["bundle_id"] as? String,
            let bundle = DemoDaemonTransport.objects(DemoCatalogs.shared.bundles).first(where: { ($0["id"] as? String) == bundleID })
        else { return .failure(DemoDaemonTransport.missing("no bundle with that id")) }
        let templates = DemoDaemonTransport.objects(DemoCatalogs.shared.templates)
        let isRussian = (params["language"] as? String ?? "en").lowercased().hasPrefix("ru")
        let members = bundle["templates"] as? [String] ?? []
        let wanted = params["templates"] as? [String] ?? members
        let switchedOn = params["schedules"] as? [String]
        var entries: [[String: Any]] = []
        for templateID in members where wanted.contains(templateID) {
            guard let template = templates.first(where: { ($0["id"] as? String) == templateID }) else { continue }
            let name = (isRussian ? template["name_ru"] : template["name_en"]) as? String ?? templateID
            let role = (isRussian ? template["role_ru"] : template["role_en"]) as? String ?? ""
            var fields: [String: Any] = [
                "name": name, "role": role, "runtime": params["runtime"] as? String ?? template["runtime"] as? String ?? "claude",
                "cwd": params["cwd"] as? String ?? DemoDaemonFiles.projects + "/" + name,
                "capabilities": template["capabilities"] as? [String] ?? [],
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
                let title = name
                addSchedule(agentID: agentID, cron: schedule["cron"] as? String ?? "", prompt: prompt, title: title,
                    enabled: enabled, now: now)
            }
            entries.append(["template_id": templateID, "agent": agent])
        }
        return .success(DemoJSON.text(["agents": entries, "missing_integrations": [[String: Any]]()]))
    }

    private func addSchedule(agentID: String, cron: String, prompt: String, title: String, enabled: Bool, now: Int64) {
        demoSchedules.append([
            "id": UUID().uuidString.lowercased(), "agent_id": agentID, "cron": cron, "tz": "UTC", "prompt": prompt,
            "enabled": enabled, "created_at": now, "next_run_at": NSNull(), "last_run_at": NSNull(), "title": title,
        ])
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

    static func badParams(_ message: String) -> RPCError {
        RPCError(code: -32602, message: message)
    }

    static func missing(_ message: String) -> RPCError {
        RPCError(code: -32004, message: message)
    }
}

/// Wire forms of the app's models, for the demo daemon's store.
enum DemoWire {
    /// The value, or JSON `null` when there is none.
    static func nullable(_ value: String?) -> Any {
        value.map { $0 as Any } ?? NSNull()
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
