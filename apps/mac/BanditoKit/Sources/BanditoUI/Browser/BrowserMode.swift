import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Browser mode: the server's browser, its page, and the previews of ports agents opened.
/// Waits for the server's info, says so when the server is too old to have a browser, and shows the
/// example page for a server without one.
struct BrowserMode: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router

    var body: some View {
        if let server = app.currentServer {
            BrowserContent(server: server)
                .id(server.id)
        } else {
            ModePlaceholder(mode: .browser)
        }
    }
}

private struct BrowserContent: View {
    let server: ServerModel
    @Environment(Router.self) private var router
    @Environment(Keymap.self) private var keymap

    var body: some View {
        let model = BrowserStore.shared.model(for: server)
        BrowserMainArea(model: model)
            // ⌘⇧C takes the browser from the agent, or gives it back when the user holds it.
            .keymapShortcut("browser.takeControl", keymap: keymap) {
                Task {
                    if model.status?.controller == .user {
                        await model.giveBack()
                    } else {
                        await model.takeControl()
                    }
                }
            }
            .keymapShortcut("browser.newTab", keymap: keymap) { Task { await model.newTab() } }
            .task(id: server.id) {
                model.attach()
            }
            .onDisappear {
                model.detach()
            }
            .task(id: router.pendingPreviewPort) {
                if let port = router.takePreviewPort() {
                    model.openPreview(port: port)
                }
            }
    }
}

/// The main area: toolbar, the control banner, and the page (or the preview, or an empty state).
private struct BrowserMainArea: View {
    @Bindable var model: BrowserModel
    @Environment(Router.self) private var router

    var body: some View {
        Group {
            if model.server.info == nil {
                EmptyNote(text: L10n.Browser.connecting)
            } else if !model.isSupported {
                BrowserUnsupported()
            } else {
                VStack(spacing: 0) {
                    BrowserToolbar(model: model)
                    if model.status?.running == true {
                        ControlBanner(model: model)
                    }
                    content
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Bandito.bg)
    }

    @ViewBuilder
    private var content: some View {
        switch model.selection {
        case .preview(let port)?:
            PreviewPane(model: model, port: port)
        case .page?, nil:
            if model.status?.running == true {
                PageSurface(model: model)
            } else {
                BrowserStopped(model: model)
            }
        }
    }
}

// MARK: Toolbar

private struct BrowserToolbar: View {
    @Bindable var model: BrowserModel
    @FocusState private var addressFocused: Bool
    @Environment(Keymap.self) private var keymap

    var body: some View {
        HStack(spacing: 6) {
            Button {
                Task { await model.goBack() }
            } label: {
                Image(systemName: "chevron.left")
            }
            .banditoButton(.icon(size: 30, label: L10n.Browser.back))
            .focusable(false)
            .disabled(!model.canGoBack)
            .help(L10n.Browser.back)

            Button {
                Task { await model.goForward() }
            } label: {
                Image(systemName: "chevron.right")
            }
            .banditoButton(.icon(size: 30, label: L10n.Browser.forward))
            .focusable(false)
            .disabled(!model.canGoForward)
            .help(L10n.Browser.forward)

            Button {
                Task { await model.reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .banditoButton(.icon(size: 30, label: L10n.Browser.reload))
            .focusable(false)
            .help(L10n.Browser.reload)

            addressBar

            if let external = model.externalURL {
                Button {
                    ExternalLinks.open(external)
                } label: {
                    Text(L10n.Browser.openOnMac)
                }
                .banditoButton(.quiet())
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(Color.Bandito.bg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.Bandito.text.opacity(0.05)).frame(height: 1)
        }
        // The shortcuts come from the keymap, so Settings → Keys can change them: ⌘L address, ⌘R reload.
        .keymapShortcut("browser.address", keymap: keymap) { addressFocused = true }
        .keymapShortcut("browser.reload", keymap: keymap) { Task { await model.reload() } }
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock")
                .font(.system(size: 11))
                .foregroundStyle(Color.Bandito.ok)
            TextField(L10n.Browser.address, text: $model.addressText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color.Bandito.text)
                .focused($addressFocused)
                .onSubmit {
                    Task { await model.navigate(to: model.addressText) }
                }
            Text(L10n.Browser.onServer)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.Bandito.text3)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        .background(Color.Bandito.surface2, in: RoundedRectangle(cornerRadius: BanditoRadius.md))
        .overlay(alignment: .bottomLeading) {
            if model.isLoading {
                LoadingBar()
            }
        }
    }
}

#if os(macOS)
/// Sends a key press to the page. ⌘A/C/X/Z go as edit commands, ⌘V as the Mac's text, the rest as keys.
@MainActor
enum BrowserKeyRouting {
    static func forward(_ type: CDPKeyType, _ descriptor: CDPKeyDescriptor, _ modifiers: KeyModifiers, to model: BrowserModel) async {
        let shortcut = BrowserEdit.shortcut(
            key: descriptor.key, command: modifiers.contains(.meta), shift: modifiers.contains(.shift))
        if shortcut == .paste {
            // Only the first press pastes. A held ⌘V sends repeats (rawKeyDown, from isARepeat) that must not
            // paste again, nor reach the page as a key.
            guard type == .keyDown else { return }
            // Chrome's paste reads its own clipboard, so the Mac's text is typed in instead.
            if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
                await model.send(.insertText(text))
            }
            return
        }
        let edit = type == .keyDown ? shortcut : nil
        switch edit {
        case let edit?:
            await model.send(.editing(edit, key: descriptor, modifiers: modifiers))
        case nil:
            await model.send(.key(type: type, key: descriptor, modifiers: modifiers))
        }
    }
}
#endif

/// Shown when Chrome is not on the server. Installs it with `setup.install`, the same job as the server's
/// capabilities card, then starts the browser.
private struct ChromeInstallCard: View {
    @Bindable var model: BrowserModel
    @State private var setup = SetupModel()

    var body: some View {
        VStack(spacing: 12) {
            Text(L10n.Browser.needsChrome)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.Bandito.text)
            Text(L10n.Browser.needsChromeHint)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.Bandito.text2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if setup.isRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.Browser.installing)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.Bandito.text2)
                }
            }
            if let command = setup.passwordCommand {
                Text(command)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.Bandito.text2)
                    .textSelection(.enabled)
            }
            if setup.job?.state == .failed {
                Text(L10n.Browser.installFailed)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.Bandito.danger)
            } else if let error = setup.error ?? model.errorText {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.Bandito.danger)
                    .multilineTextAlignment(.center)
            }
            Button(L10n.Browser.install) {
                Task {
                    await setup.install(["browser"], server: model.server)
                    await model.start()
                }
            }
            .banditoButton(.signal())
            .disabled(setup.isRunning)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A thin orange sweep under the address bar while a page loads.
private struct LoadingBar: View {
    @State private var phase: CGFloat = -0.3
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(MotionLevel.storageKey) private var motionLevel = MotionLevel.full.rawValue

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(LinearGradient(colors: [.clear, Color.Bandito.signal, .clear], startPoint: .leading, endPoint: .trailing))
                .frame(width: geo.size.width * 0.25, height: 2)
                .offset(x: geo.size.width * phase)
                .onAppear {
                    // Still motion: a steady segment in the middle instead of a sweep.
                    if reduceMotion || !MotionLevel(stored: motionLevel).allowsRepeatingMotion {
                        phase = 0.375
                        return
                    }
                    withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                        phase = 1
                    }
                }
        }
        .frame(height: 2)
        .clipped()
    }
}

// MARK: Control banner

/// "Forge управляет браузером" while an agent holds the browser, with Pause and Take control.
/// When the person holds it, a quiet strip offers to give it back. Also used for "Take control to click here?".
private struct ControlBanner: View {
    @Bindable var model: BrowserModel

    var body: some View {
        let holder = model.status?.controller ?? .none
        HStack(spacing: 10) {
            if holder == .agent {
                AgentDots()
                Text(L10n.Browser.banner)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.Bandito.text)
                Spacer(minLength: 8)
                Button(L10n.Browser.bannerPause) {
                    Task { await model.pause() }
                }
                .banditoButton(.quiet())
                Button(L10n.Browser.bannerTake) {
                    Task { await model.takeControl() }
                }
                .banditoButton(.lightPill())
            } else if model.asksToTakeControl {
                Text(L10n.Browser.askTakeControl)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.Bandito.text)
                Spacer(minLength: 8)
                Button(L10n.Browser.bannerTake) {
                    Task { await model.takeControl() }
                }
                .banditoButton(.lightPill())
            } else {
                Text(holder == .user ? L10n.Browser.controlUser : L10n.Browser.controlNone)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.Bandito.text2)
                Spacer(minLength: 8)
                Button(holder == .user ? L10n.Browser.bannerGive : L10n.Browser.bannerTake) {
                    Task {
                        if holder == .user {
                            await model.giveBack()
                        } else {
                            await model.takeControl()
                        }
                    }
                }
                .banditoButton(.quiet())
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(
            holder == .agent
                ? AnyShapeStyle(Color.Bandito.signal.opacity(0.12))
                : AnyShapeStyle(Color.Bandito.surface2.opacity(0.6)),
            in: RoundedRectangle(cornerRadius: BanditoRadius.md)
        )
        .overlay {
            RoundedRectangle(cornerRadius: BanditoRadius.md)
                .strokeBorder(holder == .agent ? Color.Bandito.signal.opacity(0.3) : Color.Bandito.line)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }
}

/// Three dots that pulse one after another while the agent works.
private struct AgentDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.2)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.Bandito.signal)
                        .frame(width: 4, height: 4)
                        .opacity(0.25 + 0.75 * max(0, sin((t * 2.5) - Double(i) * 0.6)))
                }
            }
        }
        .frame(width: 22)
    }
}

// MARK: Page

/// The picture of the page, with the input that goes to it.
private struct PageSurface: View {
    @Bindable var model: BrowserModel

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Color.Bandito.surface1
                if let frame = model.frame {
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .accessibilityHidden(true)
                } else {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(L10n.Browser.connecting)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.Bandito.text3)
                    }
                }
                #if os(macOS)
                PageInput(
                    onPointer: { pointer in
                        Task { @MainActor in
                            guard let page = model.pagePoint(pointer.point, viewSize: size) else { return }
                            await model.send(
                                .mouse(
                                    type: pointer.type, x: Double(page.x), y: Double(page.y), button: pointer.button,
                                    clickCount: pointer.clickCount, deltaX: pointer.deltaX, deltaY: pointer.deltaY,
                                    modifiers: pointer.modifiers))
                        }
                    },
                    onKey: { key in
                        Task { @MainActor in
                            switch key {
                            case .key(let type, let descriptor, let modifiers):
                                await BrowserKeyRouting.forward(type, descriptor, modifiers, to: model)
                            case .text(let text):
                                await model.send(.insertText(text))
                            }
                        }
                    }
                )
                #endif
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: BanditoRadius.md))
        .padding(14)
    }
}

/// A preview of a port an agent opened, in a web view (see `PreviewWebView`).
private struct PreviewPane: View {
    @Bindable var model: BrowserModel
    let port: Int

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            if let url = model.previewURL(port: port) {
                PreviewWebView(url: url, server: model.server)
                    .id(port)
                    .clipShape(RoundedRectangle(cornerRadius: BanditoRadius.md))
                    .padding(14)
            } else {
                EmptyNote(text: L10n.Browser.previewError)
            }
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The browser is off on the server: a button to start it.
private struct BrowserStopped: View {
    @Bindable var model: BrowserModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "globe")
                .font(.system(size: 34))
                .foregroundStyle(Color.Bandito.text3)
            Text(L10n.Browser.stopped)
                .font(.system(size: 13))
                .foregroundStyle(Color.Bandito.text2)
            if model.needsChrome {
                ChromeInstallCard(model: model)
            } else {
                if let text = model.errorText {
                    Text(text)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.Bandito.danger)
                        .multilineTextAlignment(.center)
                }
                Button(L10n.Browser.start) {
                    Task { await model.start() }
                }
                .banditoButton(.signal())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A server without the browser feature (older daemon), or a Chrome that is not installed.
private struct BrowserUnsupported: View {
    @Environment(Router.self) private var router

    var body: some View {
        VStack(spacing: 14) {
            ExampleChip()
            Text(L10n.Browser.unsupported)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.Bandito.text)
            Text(L10n.Browser.missingChrome)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.Bandito.text2)
            Button(L10n.Browser.openServer) {
                router.select(mode: .server)
            }
            .banditoButton(.quiet())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptyNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Color.Bandito.text3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Sidebar

/// Browser sidebar: the server's tabs (with who controls the browser), the ports agents started, and a note.
struct BrowserSidebar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let server = app.currentServer, server.supports("browser") {
            BrowserSidebarContent(model: BrowserStore.shared.model(for: server))
        } else {
            SidebarPlaceholder(mode: .browser)
        }
    }
}

private struct BrowserSidebarContent: View {
    @Bindable var model: BrowserModel
    @State private var ports: [ListeningPort] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                SectionLabel(L10n.Browser.tabs)
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 6)
                ForEach(model.tabs) { tab in
                    tabRow(tab)
                }
                ForEach(model.previewPorts, id: \.self) { port in
                    previewRow(port)
                }

                SectionLabel(L10n.Browser.agentsOpened)
                    .padding(.horizontal, 18)
                    .padding(.top, 16)
                    .padding(.bottom, 6)
                ForEach(ports, id: \.self) { port in
                    portRow(port)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.never)
        .safeAreaInset(edge: .bottom) {
            Text(L10n.Browser.hint)
                .font(.system(size: 12))
                .lineSpacing(2)
                .foregroundStyle(Color.Bandito.text2)
                .padding(12)
                .background(Color.Bandito.info.opacity(0.07), in: RoundedRectangle(cornerRadius: BanditoRadius.md))
                .overlay {
                    RoundedRectangle(cornerRadius: BanditoRadius.md).strokeBorder(Color.Bandito.info.opacity(0.18))
                }
                .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Bandito.surface1)
        .task(id: model.server.id) {
            while !Task.isCancelled {
                await loadPorts()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func tabRow(_ tab: BrowserTab) -> some View {
        let selected = model.selection == .page(tab.id)
        return Button {
            Task { await model.selectPage(tab.id) }
        } label: {
            HStack(spacing: 10) {
                Text(String(tab.title.prefix(1)).uppercased())
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.Bandito.onSignal)
                    .frame(width: 26, height: 26)
                    .background(Color.Bandito.text2.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text(tab.title.isEmpty ? tab.url : tab.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(1)
                    Text(selected ? controllerText : tab.url)
                        .font(.system(size: 11.5))
                        .foregroundStyle(selected && model.isAgentControlling ? Color.Bandito.signal : Color.Bandito.text3)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                selected ? Color.Bandito.signal.opacity(0.1) : Color.clear,
                in: RoundedRectangle(cornerRadius: 11))
            .contentShape(Rectangle())
        }
        .banditoButton(.row(cornerRadius: 11))
    }

    private func previewRow(_ port: Int) -> some View {
        let selected = model.selection == .preview(port)
        return Button {
            model.selection = .preview(port)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "eye")
                    .font(.system(size: 12))
                    .frame(width: 26, height: 26)
                    .foregroundStyle(Color.Bandito.info)
                    .background(Color.Bandito.info.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                Text("\(L10n.Browser.previewTitle) :\(port)")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.Bandito.text)
                Spacer(minLength: 0)
                Button {
                    model.closePreview(port: port)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.Bandito.text3)
                }
                .banditoButton(.row(cornerRadius: 6, hoverOpacity: 0.08))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(selected ? Color.Bandito.info.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 11))
            .contentShape(Rectangle())
        }
        .banditoButton(.row(cornerRadius: 11))
    }

    private func portRow(_ port: ListeningPort) -> some View {
        HStack(spacing: 10) {
            Text(":\(port.port)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.Bandito.ok)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.Bandito.ok.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            Text(port.process ?? "")
                .font(.system(size: 13))
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(L10n.Browser.openPreview) {
                model.openPreview(port: port.port)
            }
            .banditoButton(.quiet())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var controllerText: String {
        switch model.status?.controller ?? .none {
        case .agent: L10n.Browser.controlAgent
        case .user: L10n.Browser.controlUser
        case .none: L10n.Browser.controlNone
        }
    }

    /// Ports listening on the server that an agent started.
    private func loadPorts() async {
        guard let all = try? await model.server.hostPorts(), all.supported else { return }
        ports = all.ports.filter { $0.owner?.kind == .agent }
    }
}
