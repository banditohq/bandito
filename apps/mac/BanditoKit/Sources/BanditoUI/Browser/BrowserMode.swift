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
            .keymapShortcut("browser.closeTab", keymap: keymap) { Task { await model.closeCurrentTab() } }
            .task(id: server.id) {
                model.attach()
            }
            // ⌘[ and ⌘] (and the Go menu) walk the page's history while Browser mode is on screen.
            .onAppear {
                router.browserHistory = BrowserHistoryHandle(
                    canBack: { model.canGoBack },
                    canForward: { model.canGoForward },
                    back: { Task { await model.goBack() } },
                    forward: { Task { await model.goForward() } })
            }
            .onDisappear {
                model.detach()
                router.browserHistory = nil
            }
            .task(id: router.pendingPreviewPort) {
                if let port = router.takePreviewPort() {
                    model.openPreview(port: port)
                }
            }
    }
}

/// The main area: toolbar, the control banner, and the page (or the preview, or an empty state).
struct BrowserMainArea: View {
    @Bindable var model: BrowserModel
    /// Set where the browser sits in a panel: a button in the toolbar then opens it in Browser mode.
    var onOpenFullscreen: (() -> Void)?
    @Environment(Router.self) private var router

    var body: some View {
        Group {
            if model.server.info == nil {
                EmptyNote(text: L10n.Browser.connecting)
            } else if !model.isSupported {
                BrowserUnsupported()
            } else {
                VStack(spacing: 0) {
                    BrowserToolbar(model: model, onOpenFullscreen: onOpenFullscreen)
                    if let error = model.addressError {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.Bandito.danger)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.top, 6)
                    }
                    if model.status?.running == true,
                       let note = BrowserControlNote.make(
                        holder: model.status?.controller ?? .none, asksToTake: model.asksToTakeControl) {
                        ControlBanner(note: note, model: model)
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

/// How the toolbar fits its width. Pure, so the threshold is easy to test.
enum BrowserToolbarLayout {
    /// Narrower than this (a browser in a workbench panel), "Open on Mac" is only its icon, so the address field and
    /// the fullscreen button keep their room.
    static let iconOpenBelow: CGFloat = 520

    /// True when "Open on Mac" is only an icon. A width not measured yet (0, or not a number) keeps the text.
    static func opensOnMacAsIcon(width: CGFloat) -> Bool {
        guard width.isFinite, width > 0 else { return false }
        return width < iconOpenBelow
    }
}

/// Carries the toolbar's measured width up from its background.
private struct BrowserToolbarWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct BrowserToolbar: View {
    @Bindable var model: BrowserModel
    var onOpenFullscreen: (() -> Void)?
    @FocusState private var addressFocused: Bool
    @Environment(Keymap.self) private var keymap
    @State private var width: CGFloat = 0

    var body: some View {
        let compact = BrowserToolbarLayout.opensOnMacAsIcon(width: width)
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

            // The address field gives way first: the buttons keep their size and stay on screen.
            addressBar
                .layoutPriority(-1)

            if let external = model.externalURL {
                Button {
                    ExternalLinks.open(external)
                } label: {
                    if compact {
                        Image(systemName: "laptopcomputer")
                    } else {
                        Text(L10n.Browser.openOnMac)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .banditoButton(compact ? .icon(size: 30, label: L10n.Browser.openOnMac) : .quiet())
                .layoutPriority(1)
            }

            if let onOpenFullscreen {
                Button(action: onOpenFullscreen) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .banditoButton(.icon(size: 30, label: L10n.Browser.openFullscreen))
                .focusable(false)
                .help(L10n.Browser.openFullscreen)
                .layoutPriority(1)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .titleBarZoomOnDoubleClick()
        .background(Color.Bandito.bg)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: BrowserToolbarWidthKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(BrowserToolbarWidthKey.self) { width = $0 }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.Bandito.text.opacity(0.05)).frame(height: 1)
        }
        // The shortcuts come from the keymap, so Settings → Keys can change them: ⌘L address (⌘R is Refresh, in the menu).
        .keymapShortcut("browser.address", keymap: keymap) { addressFocused = true }
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock")
                .font(.system(size: 11))
                .foregroundStyle(Color.Bandito.ok)
            TextField(L10n.Browser.addressPlaceholder, text: $model.addressText)
                .textFieldStyle(.plain)
                // Regular text, as in Safari: a monospaced placeholder looked spaced out.
                .font(BanditoFont.font(size: 13, weight: 400))
                .foregroundStyle(Color.Bandito.text)
                .accessibilityLabel(L10n.Browser.address)
                .focused($addressFocused)
                .onSubmit {
                    model.submitAddress()
                    // A refused address keeps the focus, so the person can correct it.
                    if model.addressError == nil { addressFocused = false }
                }
                .onChange(of: addressFocused) { _, focused in
                    model.addressEditingChanged(focused)
                }
                .onChange(of: model.addressText) { _, _ in
                    model.addressTextEdited()
                }
            if model.status?.running == true {
                Text(L10n.Browser.onServer)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .help(L10n.Browser.onServerHelp)
            }
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
                UserFacingErrorView(message: error)
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

/// What the strip above the page says about who drives the browser. Nil when nobody holds it: the page is
/// then interactive at once, and no strip is shown. Pure, so the rules are easy to read and test.
enum BrowserControlNote: Equatable {
    /// An agent drives the browser: the strip says so and offers to take control.
    case agentDriving
    /// The person clicked while an agent drives: the strip asks before taking control.
    case askToTake
    /// The person holds the browser: a quiet strip to give it back.
    case userHolds

    static func make(holder: ControlHolder, asksToTake: Bool) -> BrowserControlNote? {
        switch holder {
        case .agent: asksToTake ? .askToTake : .agentDriving
        case .user: .userHolds
        case .none: nil
        }
    }
}

/// The strip above the page for a `BrowserControlNote`.
private struct ControlBanner: View {
    let note: BrowserControlNote
    @Bindable var model: BrowserModel

    var body: some View {
        HStack(spacing: 10) {
            switch note {
            case .agentDriving:
                AgentDots()
                Text(L10n.Browser.agentDrivingNow)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 8)
                Button(L10n.Browser.bannerPause) {
                    Task { await model.pause() }
                }
                .banditoButton(.quiet())
                Button(L10n.Browser.bannerTake) {
                    Task { await model.takeControl() }
                }
                .banditoButton(.lightPill())
            case .askToTake:
                Text(L10n.Browser.askTakeControl)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 8)
                Button(L10n.Browser.bannerTake) {
                    Task { await model.takeControl() }
                }
                .banditoButton(.lightPill())
            case .userHolds:
                Text(L10n.Browser.userHolds)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.Bandito.text2)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button(L10n.Browser.bannerGive) {
                    Task { await model.giveBack() }
                }
                .banditoButton(.quiet())
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(
            note == .agentDriving || note == .askToTake
                ? AnyShapeStyle(Color.Bandito.signal.opacity(0.12))
                : AnyShapeStyle(Color.Bandito.surface2.opacity(0.6)),
            in: RoundedRectangle(cornerRadius: BanditoRadius.md)
        )
        .overlay {
            RoundedRectangle(cornerRadius: BanditoRadius.md)
                .strokeBorder(note == .userHolds ? Color.Bandito.line : Color.Bandito.signal.opacity(0.3))
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
    /// Device pixels per point of the window the page is in. Read from the window (see `WindowScaleReader`).
    @State private var scale: CGFloat = 2
    /// This picture area's own key in the model: the panel and Browser mode each keep the size they show.
    @State private var areaID = UUID()
    @Environment(GestureSettings.self) private var gestures

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Color.Bandito.surface1
                if model.hasFrame {
                    // The picture goes to a layer without passing through SwiftUI (see `BrowserFrameLayer`).
                    BrowserFrameLayer(store: model.frames)
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
                            if pointer.type == .mouseWheel {
                                model.scroll(
                                    at: page, deltaX: pointer.deltaX, deltaY: pointer.deltaY,
                                    modifiers: pointer.modifiers)
                                return
                            }
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
                    },
                    swipeNavigates: gestures.isEnabled(.twoFingerSwipe),
                    canSwipe: { back in back ? model.canGoBack : model.canGoForward }
                )
                #endif
            }
            // The page is sized to the area the picture is drawn in, so the picture fills it with no bars.
            .onAppear { reportArea(size) }
            .onChange(of: size) { _, area in reportArea(area) }
            .onChange(of: scale) { _, _ in reportArea(size) }
            .onDisappear { model.pageSurfaceDisappeared(id: areaID) }
            .background { scaleReader }
        }
        .clipShape(RoundedRectangle(cornerRadius: BanditoRadius.md))
        .padding(14)
    }

    @ViewBuilder
    private var scaleReader: some View {
        #if os(macOS)
        WindowScaleReader { scale = $0 }
        #else
        Color.clear
        #endif
    }

    private func reportArea(_ area: CGSize) {
        model.pageAreaChanged(id: areaID, width: area.width, height: area.height, scale: Double(scale))
    }
}

#if os(macOS)
/// Reports the backing scale of the window the view is in: at once, and again when the window moves to a screen
/// with another scale.
private struct WindowScaleReader: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScaleView {
        ScaleView(onChange: onChange)
    }

    func updateNSView(_ view: ScaleView, context: Context) {
        view.onChange = onChange
    }

    static func dismantleNSView(_ view: ScaleView, coordinator: ()) {
        view.stopWatching()
    }

    final class ScaleView: NSView {
        var onChange: (CGFloat) -> Void = { _ in }
        private var observer: NSObjectProtocol?

        init(onChange: @escaping (CGFloat) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopWatching()
            guard let window else { return }
            onChange(window.backingScaleFactor)
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeBackingPropertiesNotification, object: window, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let window = self.window else { return }
                    self.onChange(window.backingScaleFactor)
                }
            }
        }

        func stopWatching() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
    }
}
#endif

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
            VStack(spacing: 6) {
                Text(L10n.Browser.stopped)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.Bandito.text2)
                Text(L10n.Browser.stoppedHint)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.Bandito.text3)
                    .multilineTextAlignment(.center)
            }
            if model.needsChrome {
                ChromeInstallCard(model: model)
            } else {
                if let text = model.errorText {
                    UserFacingErrorView(message: text)
                        .frame(maxWidth: 360)
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
    /// The first-visit hint, closed once for good.
    @AppStorage("browser.sidebarHintClosed") private var hintClosed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    SectionLabel(L10n.Browser.tabs)
                    Spacer(minLength: 6)
                    Button {
                        Task { await model.newTab() }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .banditoButton(.icon(size: 22, label: L10n.Browser.newTab))
                    .focusable(false)
                    .help(L10n.Browser.newTabHelp)
                }
                .padding(.horizontal, 10)
                .padding(.top, 14)
                .padding(.bottom, 6)
                ForEach(model.tabs) { tab in
                    tabRow(tab)
                }
                ForEach(model.previewPorts, id: \.self) { port in
                    previewRow(port)
                }

                // Only when an agent has opened something: an empty section says nothing.
                if !ports.isEmpty {
                    SectionLabel(L10n.Browser.agentsOpened)
                        .padding(.horizontal, 10)
                        .padding(.top, 16)
                        .padding(.bottom, 6)
                    ForEach(ports, id: \.self) { port in
                        portRow(port)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.never)
        .safeAreaInset(edge: .bottom) {
            if !hintClosed {
                hintCard
            }
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

    private var hintCard: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(L10n.Browser.hintShort)
                .font(.system(size: 12))
                .lineSpacing(2)
                .foregroundStyle(Color.Bandito.text2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                hintClosed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 20, height: 20)
            }
            .banditoButton(.row(cornerRadius: 6, hoverOpacity: 0.08))
            .foregroundStyle(Color.Bandito.text3)
            .help(L10n.Common.close)
            .accessibilityLabel(L10n.Common.close)
        }
        .padding(12)
        .background(Color.Bandito.info.opacity(0.07), in: RoundedRectangle(cornerRadius: BanditoRadius.md))
        .overlay {
            RoundedRectangle(cornerRadius: BanditoRadius.md).strokeBorder(Color.Bandito.info.opacity(0.18))
        }
        .padding(14)
    }

    private func tabRow(_ tab: BrowserTab) -> some View {
        BrowserTabRow(
            tab: tab,
            selected: model.selection == .page(tab.id),
            // The address of the shown tab is the live one; the others show the last list of tabs.
            url: model.selection == .page(tab.id) ? model.currentURL : tab.url,
            agentDrives: model.selection == .page(tab.id) && model.isAgentControlling,
            onSelect: { Task { await model.selectPage(tab.id) } },
            onReload: {
                Task {
                    await model.selectPage(tab.id)
                    await model.reload()
                }
            },
            onClose: { Task { await model.closeTab(tab.id) } })
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
                Text(verbatim: "\(L10n.Browser.previewTitle) :\(port)")
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
            Text(verbatim: ":\(port.port)")
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

    /// Ports listening on the server that an agent started.
    private func loadPorts() async {
        guard let all = try? await model.server.hostPorts(), all.supported else { return }
        ports = all.ports.filter { $0.owner?.kind == .agent }
    }
}

/// One tab of the server's browser: a letter, its title (or domain), the close button on hover, and a context menu.
private struct BrowserTabRow: View {
    let tab: BrowserTab
    let selected: Bool
    /// The address to show under the title: the live one for the shown tab.
    let url: String
    /// The agent drives the browser now, and this is its tab: a small dot says so.
    let agentDrives: Bool
    let onSelect: () -> Void
    let onReload: () -> Void
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        let label = BrowserTabLabel.make(title: tab.title, url: url, newTabTitle: L10n.Browser.newTab)
        HStack(spacing: 6) {
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    Text(label.initial)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.Bandito.onSignal)
                        .frame(width: 26, height: 26)
                        .background(Color.Bandito.text2.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(label.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.Bandito.text)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            if agentDrives {
                                Circle()
                                    .fill(Color.Bandito.signal)
                                    .frame(width: 5, height: 5)
                                    .help(L10n.Browser.controlAgent)
                                    .accessibilityLabel(L10n.Browser.controlAgent)
                            }
                            Text(label.domain)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Color.Bandito.text3)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .banditoButton(.row(cornerRadius: 11))

            if hovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .banditoButton(.icon(size: 22, label: L10n.Browser.closeTab))
                .foregroundStyle(Color.Bandito.text3)
                .focusable(false)
                .help(L10n.Browser.closeTabHelp)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            selected ? Color.Bandito.signal.opacity(0.1) : Color.clear,
            in: RoundedRectangle(cornerRadius: 11))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button(L10n.Browser.reload, action: onReload)
            Button(L10n.Browser.copyAddress) {
                #if os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
                #endif
            }
            Divider()
            Button(L10n.Browser.closeTab, action: onClose)
        }
    }
}

/// The text of a tab row. A page without a title shows its domain; a blank or new-tab page shows the new-tab name.
/// Pure, so the rules are easy to read and test.
enum BrowserTabLabel {
    struct Parts: Equatable {
        let title: String
        /// The domain shown under the title, without "www.". Empty for a blank page.
        let domain: String
        let initial: String
    }

    static func make(title: String, url: String, newTabTitle: String) -> Parts {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = domain(of: url)
        let blank = isBlank(url)
        let shown: String
        if blank {
            shown = newTabTitle
        } else if trimmed.isEmpty || trimmed == url {
            shown = host.isEmpty ? url : host
        } else {
            shown = trimmed
        }
        return Parts(title: shown, domain: blank ? "" : host, initial: String(shown.prefix(1)).uppercased())
    }

    static func domain(of url: String) -> String {
        guard let host = URL(string: url)?.host, !host.isEmpty else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func isBlank(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.isEmpty || lower == "about:blank" || lower.hasPrefix("chrome://newtab")
            || lower.hasPrefix("chrome://new-tab-page") || lower.hasPrefix("chrome-search://local-ntp")
    }
}
