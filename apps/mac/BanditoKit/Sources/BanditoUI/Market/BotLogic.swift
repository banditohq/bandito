import BanditoKit
import BanditoL10n
import Foundation

/// The rules of the Bots page: the categories, the filter and the search, the services a bot needs, and what the
/// create sheet collects. Pure, so each rule is easy to test.
enum BotLogic {
    /// The order of the sidebar. A category the daemon adds later comes after these.
    static let categoryOrder = ["dev", "ops", "research", "writing", "business", "personal"]

    static func categories(in templates: [BotTemplate]) -> [String] {
        let used = Set(templates.map(\.category))
        return categoryOrder.filter { used.contains($0) } + used.subtracting(categoryOrder).sorted()
    }

    /// The templates the filter keeps, then the ones the search keeps. The search reads the name in the app's language
    /// and in English, and the description in the app's language; it ignores case and spaces at the ends.
    static func visible(
        _ templates: [BotTemplate], filter: MarketFilter, query: String, languageCode: String
    ) -> [BotTemplate] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return templates.filter { template in
            switch filter {
            case .all, .connected, .installed: true
            case .myBots: false
            case .category(let name): template.category == name
            }
        }.filter { template in
            needle.isEmpty
                || template.searchNames(languageCode: languageCode).contains { $0.localizedCaseInsensitiveContains(needle) }
                || template.description(languageCode: languageCode).localizedCaseInsensitiveContains(needle)
        }
    }

    // MARK: my bots

    /// A bot of the owner's: an agent made from a template. `template` is the catalog's entry, nil when the catalog
    /// does not list it any more.
    struct MyBot: Identifiable, Equatable {
        let agent: Agent
        let template: BotTemplate?
        var id: String { agent.id }
    }

    /// The agents made from a template, in the order the server lists them (agents made by hand are left out). The
    /// search keeps the bots whose agent name or template name contains it, ignoring case and spaces at the ends.
    static func myBots(
        agents: [Agent], templates: [BotTemplate], query: String, languageCode: String
    ) -> [MyBot] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return agents.compactMap { agent -> MyBot? in
            guard let templateId = agent.templateId else { return nil }
            let template = templates.first { $0.id == templateId }
            guard !needle.isEmpty else { return MyBot(agent: agent, template: template) }
            let templateName = template?.name(languageCode: languageCode) ?? ""
            let matches = agent.name.localizedCaseInsensitiveContains(needle)
                || templateName.localizedCaseInsensitiveContains(needle)
            return matches ? MyBot(agent: agent, template: template) : nil
        }
    }

    // MARK: services

    /// How a service of a template stands on this server.
    enum ServiceState: Equatable {
        /// An enabled integration matches it.
        case connected
        /// An integration matches it but is turned off: the agents do not see it.
        case off
        case missing
    }

    struct Service: Identifiable, Equatable {
        let id: String
        let name: String
        let required: Bool
        let state: ServiceState
        /// The catalog entry, to connect it from. Nil for an id the catalog does not know.
        let entry: IntegrationCatalogEntry?
    }

    /// The services of a template, in its order. The match is the daemon's own (`missing_integrations`): an
    /// integration named like the service, or one with the catalog address of the service.
    static func services(
        of template: BotTemplate, catalog: [IntegrationCatalogEntry], integrations: [Integration]
    ) -> [Service] {
        services(needs: template.integrations, catalog: catalog, integrations: integrations)
    }

    /// The same match for any list of needs: a bot's own, or the union of a bundle's (`BundleLogic.services`).
    static func services(
        needs: [BotIntegration], catalog: [IntegrationCatalogEntry], integrations: [Integration]
    ) -> [Service] {
        needs.map { need in
            let entry = catalog.first { $0.id == need.id }
            let matches = integrations.filter { integration in
                integration.name == need.id || (entry?.url != nil && integration.url == entry?.url)
            }
            let state: ServiceState
            if matches.contains(where: \.enabled) {
                state = .connected
            } else {
                state = matches.isEmpty ? .missing : .off
            }
            return Service(id: need.id, name: entry?.name ?? need.id, required: need.required, state: state, entry: entry)
        }
    }

    /// The services the bot cannot do its job without that are not connected.
    static func missingRequired(_ services: [Service]) -> [Service] {
        services.filter { $0.required && $0.state != .connected }
    }

    static func missingOptional(_ services: [Service]) -> [Service] {
        services.filter { !$0.required && $0.state != .connected }
    }

    // MARK: runtimes

    /// The runtimes a bot can run on here: installed, and not known to be signed out.
    static func availableRuntimes(_ statuses: [RuntimeStatus]) -> [RuntimeKind] {
        RuntimeKind.pickable.filter { kind in
            statuses.contains { $0.kind == kind && $0.installed && $0.loggedIn != false }
        }
    }

    // MARK: create

    static let maxNameLength = 32

    /// What the create sheet collects: the name, the runtime and the schedules to turn on.
    struct Draft: Equatable {
        var name: String
        var runtime: RuntimeKind?
        var schedules: Set<Int>

        /// The template's name in the app's language, made valid for an agent (and free on this server), the
        /// template's runtime when it is available, and the schedules the template turns on by default.
        init(template: BotTemplate, languageCode: String, existingNames: [String], available: [RuntimeKind]) {
            name = Self.suggestedName(template: template, languageCode: languageCode, existing: existingNames)
            runtime = Self.chosenRuntime(preferred: template.runtimeKind, available: available)
            schedules = Set(template.schedules.indices.filter { template.schedules[$0].enabledByDefault })
        }

        /// The runtime can change while the server's answer is still coming: keep a choice that is still possible,
        /// otherwise take the template's, otherwise the first available one.
        mutating func syncRuntime(preferred: RuntimeKind?, available: [RuntimeKind]) {
            if let runtime, available.contains(runtime) { return }
            runtime = Self.chosenRuntime(preferred: preferred, available: available)
        }

        private static func chosenRuntime(preferred: RuntimeKind?, available: [RuntimeKind]) -> RuntimeKind? {
            AgentRuntimeChoice.pick(preferred: preferred ?? .claude, signedIn: available)
        }

        /// Letters, digits, spaces, dashes and underscores only, at most 32 characters; "Name 2" if taken.
        static func suggestedName(template: BotTemplate, languageCode: String, existing: [String]) -> String {
            var base = clean(template.name(languageCode: languageCode))
            if base.isEmpty { base = clean(template.nameEn) }
            if base.isEmpty { base = "Bot" }
            var candidate = base
            var number = 2
            while existing.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
                let suffix = " \(number)"
                candidate = String(base.prefix(BotLogic.maxNameLength - suffix.count)).trimmingCharacters(in: .whitespaces) + suffix
                number += 1
            }
            return candidate
        }

        private static func clean(_ raw: String) -> String {
            let kept = raw.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" }
            let collapsed = kept.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            return String(collapsed.prefix(BotLogic.maxNameLength)).trimmingCharacters(in: .whitespaces)
        }

        /// Why the name cannot be used, or nil. The limit is the daemon's 32 characters.
        func nameProblem(existing: [String]) -> AgentNameRule.Problem? {
            AgentNameRule.problem(for: name, existing: existing, maxLength: BotLogic.maxNameLength)
        }

        func canCreate(existing: [String]) -> Bool {
            runtime != nil && nameProblem(existing: existing) == nil
        }

        /// The request for the daemon: the trimmed name, the runtime, the app's language as the daemon keys it, and
        /// exactly the ticked schedules (an empty list when none is ticked: the daemon then adds none).
        func request(template: BotTemplate, languageCode: String) -> NewBot? {
            guard let runtime else { return nil }
            return NewBot(
                templateId: template.id,
                name: name.trimmingCharacters(in: .whitespaces),
                runtime: runtime.rawValue,
                language: CatalogLanguage.requestCode(languageCode),
                schedules: schedules.sorted())
        }
    }

    // MARK: after creating

    /// What the person is told once the bot exists: the steps that failed, in the app's words. Empty when all went
    /// well. The daemon's messages are English and short; they are shown as they are.
    static func problems(of creation: BotCreation) -> [String] {
        creation.errors.map { error in
            switch error.step {
            case "skill":
                L10n.Market.Bot.Error.skill(id: error.id ?? "", message: error.message)
            case "schedule":
                L10n.Market.Bot.Error.schedule(number: String((error.index ?? 0) + 1), message: error.message)
            default:
                error.message
            }
        }
    }
}

/// A cron expression of a template in the person's words: "Weekdays at 8:00 AM". An expression it does not read
/// (steps, ranges of hours, a day of the month) is left as it is, in monospace by the view.
enum BotScheduleWords {
    enum Days: Equatable {
        case every
        case weekdays
        /// Cron weekday numbers, 0 is Sunday.
        case list([Int])
    }

    struct Reading: Equatable {
        var days: Days
        /// Minutes since midnight, in the order of the expression.
        var times: [Int]
    }

    /// The days and the times of `cron`, or nil when it is not of the plain kind the templates use: one minute, a list
    /// of hours, any day of the month and of the year, and every day, the weekdays or a list of weekdays.
    static func reading(_ cron: String) -> Reading? {
        let fields = cron.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count == 5, fields[2] == "*", fields[3] == "*",
            let minute = Int(fields[0]), (0...59).contains(minute)
        else { return nil }
        let hours = fields[1].split(separator: ",", omittingEmptySubsequences: false).map { Int($0) }
        guard !hours.isEmpty, hours.allSatisfy({ $0.map { (0...23).contains($0) } ?? false }) else { return nil }
        let times = hours.compactMap { $0 }.map { $0 * 60 + minute }
        let days: Days
        switch fields[4] {
        case "*": days = .every
        case "1-5": days = .weekdays
        default:
            let parts = fields[4].split(separator: ",", omittingEmptySubsequences: false).map { Int($0) }
            guard !parts.isEmpty, parts.allSatisfy({ $0.map { (0...7).contains($0) } ?? false }) else { return nil }
            let numbers = parts.compactMap { $0 }.map { $0 == 7 ? 0 : $0 }
            days = .list(Array(Set(numbers)).sorted())
        }
        return Reading(days: days, times: times)
    }

    /// The words for `cron` in `languageCode`, or nil when the expression is not read.
    static func words(cron: String, languageCode: String) -> String? {
        guard let reading = reading(cron) else { return nil }
        let locale = Locale(identifier: languageCode)
        let clock = DateFormatter()
        clock.locale = locale
        clock.timeZone = TimeZone(identifier: "UTC")
        clock.dateStyle = .none
        clock.timeStyle = .short
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let times = reading.times.compactMap { total -> String? in
            var parts = DateComponents(year: 2024, month: 1, day: 1, hour: total / 60, minute: total % 60)
            parts.timeZone = calendar.timeZone
            return calendar.date(from: parts).map { clock.string(from: $0) }
        }.joined(separator: ", ")
        switch reading.days {
        case .every:
            return L10n.Market.Bot.When.daily(time: times)
        case .weekdays:
            return L10n.Market.Bot.When.weekdays(time: times)
        case .list(let numbers):
            let names = DateFormatter()
            names.locale = locale
            let symbols = names.shortWeekdaySymbols ?? []
            let list = numbers.compactMap { symbols.indices.contains($0) ? symbols[$0] : nil }.joined(separator: ", ")
            return L10n.Market.Bot.When.days(days: list, time: times)
        }
    }
}
