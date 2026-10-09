import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Server → Workplaces (docs/design/Workspaces.dc.html). With the `workspaces` feature the cards are the server's
/// real workplaces: the shared server first, then the containers. Without the feature the sample data of the design
/// shows under the "Example" chip, and only while examples are on.
struct WorkspacesView: View {
    @Environment(DemoStore.self) private var demo
    @Environment(AppModel.self) private var app

    @State private var model: WorkspacesModel?
    @State private var setup = SetupModel()
    @State private var creating = false
    /// Demo only: agent name → workplace name, for the drags made on the sample cards.
    @State private var moved: [String: String] = [:]

    private var server: ServerModel? { app.currentServer }

    var body: some View {
        ServerPage(title: L10n.Server.Workspaces.title) {
            Text(L10n.Server.Workspaces.intro)
                .font(.system(size: 13.5))
                .foregroundStyle(Color.Bandito.text2)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 680, alignment: .leading)
            if let server, server.supports("workspaces") {
                if let model, model.server.id == server.id {
                    realContent(model)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            } else if demo.enabled {
                demoContent
            } else {
                ServerCard {
                    Text(L10n.Server.Workspaces.demoOff)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.Bandito.text2)
                }
            }
        }
        .task(id: server?.id) {
            guard let server, server.supports("workspaces") else { return }
            let loaded = WorkspacesModel(server: server)
            model = loaded
            await loaded.load()
        }
        .sheet(isPresented: $creating) {
            if let model {
                WorkspaceCreateSheet(model: model) { creating = false }
            }
        }
    }

    // MARK: Real workplaces

    private func realContent(_ model: WorkspacesModel) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let error = model.errorText {
                UserFacingErrorView(message: error)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 680, alignment: .leading)
            }
            if !model.loading && !model.dockerReady {
                DockerCard(model: model, setup: setup)
            }
            HStack {
                Spacer(minLength: 0)
                Button(L10n.Workspace.Action.create) { creating = true }
                    .banditoButton(.signal())
                    .disabled(!model.dockerReady)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                ForEach(model.workspaces) { workspace in
                    RealWorkspaceCard(model: model, workspace: workspace, agents: agents(in: workspace, model: model))
                }
            }
            compare
        }
    }

    /// The agents that run in a workplace, from the agent list the server already keeps.
    private func agents(in workspace: Workspace, model: WorkspacesModel) -> [Agent] {
        model.server.agents.filter { $0.workspaceId == workspace.id }
    }

    // MARK: Demo workplaces (no `workspaces` feature)

    private var demoContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(demo.spaces) { space in
                    DemoWorkspaceCard(space: space, agents: demoAgents(in: space)) { name in
                        moved[name] = space.name
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            compare
        }
    }

    /// Agents of a sample workplace: by default the ones the sample data puts there, then the ones dragged here.
    private func demoAgents(in space: DemoSpace) -> [String] {
        let all = demo.spaces.flatMap(\.agents)
        return all.filter { name in
            if let target = moved[name] { return target == space.name }
            return space.agents.contains(name)
        }
    }

    // MARK: Shared

    private var compare: some View {
        ServerCard {
            SectionLabel(L10n.Server.Workspaces.compare)
            HStack(alignment: .top, spacing: 16) {
                CompareItem(
                    kind: .shared, title: L10n.Server.Workspaces.Compare.sharedTitle,
                    text: L10n.Server.Workspaces.Compare.sharedText, note: L10n.Server.Workspaces.Compare.sharedNote)
                CompareItem(
                    kind: .container, title: L10n.Server.Workspaces.Compare.containerTitle,
                    text: L10n.Server.Workspaces.Compare.containerText,
                    note: L10n.Server.Workspaces.Compare.containerNote)
            }
        }
    }
}

// MARK: - Docker

/// Shown while Docker is not ready: installs it when Bandito can, else gives the daemon's hint.
private struct DockerCard: View {
    let model: WorkspacesModel
    @Bindable var setup: SetupModel

    var body: some View {
        ServerCard {
            SectionLabel(L10n.Workspace.Docker.title)
            Text(L10n.Workspace.Docker.body)
                .font(.system(size: 13))
                .foregroundStyle(Color.Bandito.text2)
                .fixedSize(horizontal: false, vertical: true)
            if let docker = model.docker, docker.installable {
                HStack(spacing: 10) {
                    Button(L10n.Workspace.Action.install) {
                        Task { await setup.install(["docker"], server: model.server) }
                    }
                    .banditoButton(.signal())
                    .disabled(setup.isRunning)
                    if setup.isRunning {
                        Text(L10n.Workspace.Docker.installing)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.Bandito.text3)
                    }
                }
            } else {
                Text(model.docker?.hint ?? L10n.Workspace.Docker.manual)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.Bandito.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let command = setup.passwordCommand {
                Text(command)
                    .font(BanditoFont.font(size: 12, weight: 400, mono: true))
                    .foregroundStyle(Color.Bandito.text)
                    .textSelection(.enabled)
            }
            if let error = setup.error {
                UserFacingErrorView(message: error)
            }
        }
        .onChange(of: setup.isRunning) { _, running in
            // The install changed the server: read the state again.
            if !running { Task { await model.load() } }
        }
    }
}

// MARK: - A real workplace

/// One real workplace: its agents, live status (containers), limits, network, folders, and the actions the daemon offers.
private struct RealWorkspaceCard: View {
    let model: WorkspacesModel
    let workspace: Workspace
    let agents: [Agent]

    @State private var pickingFolder = false
    @State private var pickedFolder = ""
    @State private var confirmDelete = false

    private var isShared: Bool { workspace.kind == .shared }
    private var busy: Bool { model.busyID == workspace.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(L10n.Workspace.agents)
                if agents.isEmpty {
                    Text(L10n.Workspace.Agents.none)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.Bandito.text3)
                } else {
                    HStack(spacing: 8) {
                        ForEach(agents) { agent in
                            VStack(spacing: 3) {
                                AgentAvatar(name: agent.name, size: 30)
                                Text(agent.name)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(Color.Bandito.text2)
                                    .lineLimit(1)
                            }
                            .frame(minWidth: 44)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            rows
            if !isShared { folders }
            if !isShared { actions }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .banditoCard()
        .sheet(isPresented: $pickingFolder) {
            FolderPicker(server: model.server, selection: $pickedFolder) {
                pickingFolder = false
                let path = pickedFolder
                pickedFolder = ""
                if !path.isEmpty {
                    Task { await model.addFolder(path, to: workspace) }
                }
            }
        }
        .confirmationDialog(
            L10n.Workspace.Delete.title(name: workspace.name), isPresented: $confirmDelete, titleVisibility: .visible
        ) {
            Button(L10n.Workspace.Delete.confirm, role: .destructive) {
                Task { await model.delete(workspace) }
            }
        } message: {
            Text(L10n.Workspace.Delete.message)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: isShared ? "house" : "shippingbox")
                .font(.system(size: 17))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(isShared ? L10n.Workspace.Shared.title : workspace.name)
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                if isShared {
                    Text(L10n.Workspace.Shared.subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.Bandito.text3)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Chip(text: L10n.Workspace.Kind.container, tone: .info)
                }
            }
            Spacer(minLength: 6)
            if !isShared {
                statusChip
            }
        }
    }

    @ViewBuilder
    private var statusChip: some View {
        if let status = workspace.status, !status.running, status.error != nil {
            Chip(text: L10n.Workspace.Status.dockerError, tone: .danger)
        } else if workspace.isRunning {
            Chip(text: L10n.Workspace.Status.running, tone: .ok)
        } else {
            Chip(text: L10n.Workspace.Status.stopped, tone: .neutral)
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 7) {
            infoRow("cpu", L10n.Workspace.Row.cpu, cpuText)
            infoRow("memorychip", L10n.Workspace.Row.memory, memoryText)
            if !isShared {
            }
            infoRow("network", L10n.Workspace.Row.network, networkText)
        }
    }

    private func infoRow(_ symbol: String, _ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(Color.Bandito.text3)
                .frame(width: 15)
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.Bandito.text3)
                .frame(width: 74, alignment: .leading)
            Text(value)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.Bandito.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var cpuText: String {
        guard let cpus = workspace.cpus, !isShared else { return L10n.Workspace.Value.noLimit }
        return L10n.Workspace.Value.cpu(cpus: NewWorkplaceDraft.formatted(cpus))
    }

    private var memoryText: String {
        guard let memory = workspace.memoryMb, !isShared else { return L10n.Workspace.Value.noLimit }
        return L10n.Workspace.Value.memory(memory: "\(memory) MB")
    }

    private var networkText: String {
        workspace.network == .offline ? L10n.Workspace.Value.offline : L10n.Workspace.Value.internet
    }

    private var folders: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel(L10n.Workspace.Row.folders)
            if workspace.mounts.isEmpty {
                Text(L10n.Workspace.Folders.none)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.Bandito.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(workspace.mounts, id: \.self) { mount in
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.Bandito.text3)
                    Text(mount.host)
                        .font(BanditoFont.font(size: 12, weight: 400, mono: true))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(1)
                        .truncationMode(.head)
                    if mount.readOnly {
                        Chip(text: L10n.Workspace.Folders.readOnly)
                    }
                    Spacer(minLength: 0)
                    Button {
                        Task { await model.removeFolder(mount, from: workspace) }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.Bandito.text3)
                    }
                    .banditoButton(.row(cornerRadius: 6, hoverOpacity: 0.08))
                    .help(L10n.Workspace.Folders.remove)
                    .disabled(busy)
                }
            }
            Button(L10n.Workspace.Folders.add) { pickingFolder = true }
                .banditoButton(.quiet(size: .regular))
                .disabled(busy)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if workspace.isRunning {
                    Button(L10n.Workspace.Action.stop) { Task { await model.stop(workspace) } }
                        .banditoButton(.quiet(size: .regular))
                } else {
                    Button(L10n.Workspace.Action.start) { Task { await model.start(workspace) } }
                        .banditoButton(.signal())
                }
                Spacer(minLength: 0)
                Button(L10n.Workspace.Action.delete) { confirmDelete = true }
                    .banditoButton(.quiet(size: .regular))
                    .disabled(!workspace.canDelete)
            }
            .disabled(busy)
            if !workspace.canDelete {
                // The list of agents says why it cannot go; the daemon would refuse it too.
                Text(L10n.Workspace.Delete.blocked(names: agents.map(\.name).joined(separator: ", ")))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.Bandito.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var tint: Color {
        isShared ? BanditoPalette.peach : Color(hex: 0xA3BDEB)
    }
}

// MARK: - New workplace

/// "New workplace": a name, processor and memory (presets, or no limit), and the network. Internet is the default.
struct WorkspaceCreateSheet: View {
    let model: WorkspacesModel
    var onDone: () -> Void

    @State private var draft = NewWorkplaceDraft()
    @State private var saving = false

    private static let cpuPresets: [Double] = [0.5, 1, 2, 4, 8]
    private static let memoryPresets: [Int] = [512, 1024, 2048, 4096, 8192]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.Workspace.Create.title)
                .font(BanditoFont.font(size: 20, weight: 600))
                .foregroundStyle(Color.Bandito.text)
            field(L10n.Workspace.Create.name) {
                TextField("", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                Text(L10n.Workspace.Create.nameHint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.Bandito.text3)
            }
            HStack(alignment: .top, spacing: 14) {
                field(L10n.Workspace.Create.cpu) {
                    Picker("", selection: $draft.limits.cpus) {
                        Text(L10n.Workspace.Create.unlimited).tag(Double?.none)
                        ForEach(Self.cpuPresets, id: \.self) { cpus in
                            Text("\(NewWorkplaceDraft.formatted(cpus)) CPU").tag(Double?.some(cpus))
                        }
                    }
                    .labelsHidden()
                }
                field(L10n.Workspace.Create.memory) {
                    Picker("", selection: $draft.limits.memoryMb) {
                        Text(L10n.Workspace.Create.unlimited).tag(Int?.none)
                        ForEach(Self.memoryPresets, id: \.self) { mb in
                            Text("\(mb) MB").tag(Int?.some(mb))
                        }
                    }
                    .labelsHidden()
                }
            }
            field(L10n.Workspace.Create.network) {
                SegmentedPicker(
                    selection: $draft.network,
                    options: [
                        (WorkspaceNetwork.internet, L10n.Workspace.Network.internet),
                        (WorkspaceNetwork.offline, L10n.Workspace.Network.offline),
                    ])
                Text(L10n.Workspace.Create.networkHint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.Bandito.text3)
            }
            Text(L10n.Workspace.Choice.isolation)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.Bandito.text2)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.Workspace.Choice.lost)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.Bandito.text2)
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.errorText {
                UserFacingErrorView(message: error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button(L10n.AgentSheet.cancel) { onDone() }
                    .banditoButton(.quiet(size: .regular))
                Button(L10n.Workspace.Create.submit) { save() }
                    .banditoButton(.signal(size: .regular))
                    .disabled(!draft.canCreate || saving)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(Color.Bandito.surface2)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.Bandito.text2)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func save() {
        saving = true
        Task {
            let created = await model.create(draft.makeNewWorkspace())
            saving = false
            if created != nil { onDone() }
        }
    }
}

// MARK: - Sample data (no `workspaces` feature)

extension DemoSpace.Kind {
    var tint: Color {
        switch self {
        case .shared: Color(hex: 0xFFB067)
        case .container: Color(hex: 0xA3BDEB)
        case .user: Color(hex: 0xF2A093)
        }
    }

    var icon: String {
        switch self {
        case .shared: "house"
        case .container: "shippingbox"
        case .user: "person"
        }
    }

    var label: String {
        switch self {
        case .shared: L10n.Server.Workspaces.Kind.shared
        case .container: L10n.Server.Workspaces.Kind.container
        case .user: L10n.Server.Workspaces.Kind.user
        }
    }
}

/// One sample workplace: its agents (draggable onto other cards) and what it can reach.
private struct DemoWorkspaceCard: View {
    let space: DemoSpace
    let agents: [String]
    var onDrop: (String) -> Void

    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: space.kind.icon)
                    .font(.system(size: 17))
                    .foregroundStyle(space.kind.tint)
                    .frame(width: 38, height: 38)
                    .background(space.kind.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(space.name)
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(Color.Bandito.text)
                    Text(space.kind.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(space.kind.tint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(space.kind.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                Spacer(minLength: 6)
                ExampleChip()
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(L10n.Server.Workspaces.agents)
                HStack(spacing: 8) {
                    ForEach(agents, id: \.self) { name in
                        VStack(spacing: 3) {
                            AgentAvatar(name: name, size: 30)
                            Text(name)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Color.Bandito.text2)
                                .lineLimit(1)
                        }
                        .frame(minWidth: 44)
                        .draggable(name)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(targeted ? space.kind.tint.opacity(0.08) : Color.Bandito.text.opacity(0.025)))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            targeted ? space.kind.tint.opacity(0.7) : Color.Bandito.text.opacity(0.1),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .dropDestination(for: String.self) { items, _ in
                    guard let name = items.first else { return false }
                    withAnimation(.easeInOut(duration: 0.2)) { onDrop(name) }
                    return true
                } isTargeted: { targeted = $0 }
            }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(space.rows, id: \.label) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Image(systemName: row.icon)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.Bandito.text3)
                            .frame(width: 15)
                        Text(row.label)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.Bandito.text3)
                            .frame(width: 74, alignment: .leading)
                        Text(row.value)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.Bandito.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !space.meters.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(space.meters, id: \.label) { meter in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(meter.label)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Color.Bandito.text3)
                                Spacer(minLength: 4)
                                Text(meter.value)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Color.Bandito.text)
                            }
                            MeterBar(fraction: meter.fraction, tint: space.kind.tint)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .banditoCard()
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(space.kind.tint.opacity(targeted ? 0.6 : 0), lineWidth: 1.5))
    }
}

private struct CompareItem: View {
    let kind: DemoSpace.Kind
    let title: String
    let text: String
    let note: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(kind.tint)
                .frame(width: 10, height: 10)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.Bandito.text)
                Text(text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.Bandito.text2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: 0xA9C7A2))
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// A thin bar showing how much of a limit is used.
struct MeterBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.Bandito.text.opacity(0.08))
                Capsule().fill(tint).frame(width: proxy.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 5)
    }
}
