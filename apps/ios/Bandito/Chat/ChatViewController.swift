import AVFoundation
import BanditoDesign
import BanditoKit
import BanditoL10n
import Observation
import PhotosUI
import SafariServices
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The chat of one agent: a list of reused cells (a diffable data source over `ChatListLayout`), the message box on the
/// keyboard, the agent's quick replies, and the buttons around them. The list is told what changed by `ChatModel` and
/// sets up only the cells of the rows that changed; it follows the newest message while the person is at the bottom, and
/// keeps what they read in place when older messages come in above.
@MainActor
final class ChatViewController: UIViewController, UICollectionViewDelegate, ChatCellActions, PHPickerViewControllerDelegate,
    UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIDocumentPickerDelegate
{
    let model: ChatModel
    let settings: IOSSettings
    let authenticator: any BiometricAuthenticating

    // Views.
    let collectionView: UICollectionView
    let listLayout = ChatListLayout()
    let composer = ChatComposerView()
    private let jumpButton = UIButton(type: .system)
    private let banner = UILabel()
    private var emptyHost: UIHostingController<ChatEmptyView>?
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!

    // State.
    private var rowsByID: [String: ChatRow] = [:]
    private var order: [String] = []
    private(set) var atBottom = true
    private var sendPinned = false
    private var lastMetrics: ThreadScrollMetrics?
    private var unseen = 0
    private var lastBoundsHeight: CGFloat = 0
    private var distanceFromBottom: CGFloat = 0
    private var applying = false
    private var pending: ChatUpdate?
    /// Whether an update is being applied (tests wait on it).
    var isApplying: Bool { applying }
    private var visible = false
    /// Keeps the draft when the app leaves the screen for the background: a draft that is only saved when the screen
    /// goes away is lost if the system ends the app while it is in the background.
    private var backgroundObserver: NSObjectProtocol?
    private var dictation: ChatDictation?
    private var dictationBase = ""
    private let reduceMotion = { UIAccessibility.isReduceMotionEnabled }
    private var impact = UIImpactFeedbackGenerator(style: .light)
    private let notifications = UINotificationFeedbackGenerator()
    /// Called when the person taps the changes card.
    var onOpenChanges: (() -> Void)?
    /// A row to show at the top once the thread is on the screen (an Activity entry opens the chat at it); nil for the
    /// newest message. Used once.
    var focusRowID: String?

    init(model: ChatModel, settings: IOSSettings, authenticator: any BiometricAuthenticating = DeviceAuthenticator()) {
        self.model = model
        self.settings = settings
        self.authenticator = authenticator
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: listLayout)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: life

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.Bandito.bg
        collectionView.backgroundColor = UIColor.Bandito.bg
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .interactive
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.alwaysBounceVertical = true
        collectionView.accessibilityIdentifier = "chat.list"
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.register(ChatMessageCell.self, forCellWithReuseIdentifier: ChatMessageCell.reuse)
        collectionView.register(ChatLineCell.self, forCellWithReuseIdentifier: ChatLineCell.reuse)
        collectionView.register(ChatToolsCell.self, forCellWithReuseIdentifier: ChatToolsCell.reuse)
        collectionView.register(ChatChangesCell.self, forCellWithReuseIdentifier: ChatChangesCell.reuse)
        collectionView.register(ChatWorkingCell.self, forCellWithReuseIdentifier: ChatWorkingCell.reuse)
        collectionView.register(ChatHostedCell.self, forCellWithReuseIdentifier: ChatHostedCell.reuse)

        composer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        view.addSubview(composer)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: composer.topAnchor),
            composer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        setUpJumpButton()
        setUpBanner()
        setUpComposer()

        dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) { [weak self] collection, indexPath, id in
            guard let self else { return UICollectionViewCell() }
            return self.cell(collection, indexPath, id)
        }
        // A new size category (Dynamic Type) measures every row again.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: ChatViewController, _) in
            controller.model.engine.clear()
            controller.view.setNeedsLayout()
        }
        model.hostedContent = { [weak self] row in self?.hostedContent(row) ?? AnyView(EmptyView()) }
        model.onUpdate = { [weak self] update in self?.receive(update) }
        model.onEmptyChange = { [weak self] _ in self?.updateEmpty() }
        model.start()
        trackFrame()
        restoreDraft()
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveDraft() }
        }
        #if DEBUG
        ChatLaunchHooks.apply(to: self)
        #endif
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        visible = true
        ChatPresence.shared.enter(serverID: model.server.id, agentID: model.agentID)
        markReadIfSeen()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        visible = false
        ChatPresence.shared.leave(serverID: model.server.id, agentID: model.agentID)
        saveDraft()
        stopDictation()
    }

    deinit {
        MainActor.assumeIsolated {
            model.stop()
            if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        }
    }

    // MARK: layout

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = collectionView.bounds.width
        if width > 0 {
            model.setMetrics(ChatMetrics(width: width, category: traitCollection.preferredContentSizeCategory))
        }
        // The list's height changed (the keyboard, the box growing): the bottom keeps its place.
        let height = collectionView.bounds.height
        if lastBoundsHeight > 0, abs(height - lastBoundsHeight) > 0.5 {
            let target = max(0, collectionView.contentSize.height - height - distanceFromBottom)
            collectionView.contentOffset = CGPoint(x: 0, y: target)
        }
        lastBoundsHeight = height
        rememberDistance()
        if let host = emptyHost {
            let area = collectionView.frame
            host.view.frame = area
        }
        layoutOverlay()
    }

    private func rememberDistance() {
        distanceFromBottom = max(0, collectionView.contentSize.height - collectionView.contentOffset.y - collectionView.bounds.height)
    }

    // MARK: cells

    private func cell(_ collection: UICollectionView, _ indexPath: IndexPath, _ id: String) -> UICollectionViewCell {
        ChatCounters.shared.cellConfigured(id)
        guard let row = rowsByID[id], let metrics = model.metrics else {
            return collection.dequeueReusableCell(withReuseIdentifier: ChatLineCell.reuse, for: indexPath)
        }
        switch row.content {
        case .message(let message):
            let cell = collection.dequeueReusableCell(withReuseIdentifier: ChatMessageCell.reuse, for: indexPath) as! ChatMessageCell
            if case .message(let layout) = model.engine.layout(row, metrics).payload {
                cell.configure(row: row, message: message, layout: layout, speaker: speaker(of: message), actions: self)
            }
            return cell
        case .day, .chapter, .line:
            let cell = collection.dequeueReusableCell(withReuseIdentifier: ChatLineCell.reuse, for: indexPath) as! ChatLineCell
            cell.configure(row: row, layout: model.engine.layout(row, metrics), actions: self)
            return cell
        case .tools(let group):
            let cell = collection.dequeueReusableCell(withReuseIdentifier: ChatToolsCell.reuse, for: indexPath) as! ChatToolsCell
            if case .tools(let layout) = model.engine.layout(row, metrics).payload {
                cell.configure(row: row, group: group, layout: layout, actions: self)
            }
            return cell
        case .changes(let summary):
            let cell = collection.dequeueReusableCell(withReuseIdentifier: ChatChangesCell.reuse, for: indexPath) as! ChatChangesCell
            if case .card(let layout) = model.engine.layout(row, metrics).payload {
                cell.configure(summary: summary, layout: layout, actions: self)
            }
            return cell
        case .working(let working):
            let cell = collection.dequeueReusableCell(withReuseIdentifier: ChatWorkingCell.reuse, for: indexPath) as! ChatWorkingCell
            if case .working(let layout) = model.engine.layout(row, metrics).payload {
                cell.configure(working: working, layout: layout, reduceMotion: reduceMotion() || settings.motion.reducesMotion(systemSetting: false))
            }
            return cell
        case .approval, .form, .connect:
            let cell = collection.dequeueReusableCell(withReuseIdentifier: ChatHostedCell.reuse, for: indexPath) as! ChatHostedCell
            cell.configure(row: row, content: hostedContent(row), parent: self)
            return cell
        }
    }

    private func speaker(of message: ChatMessage) -> String {
        switch message.sender {
        case .me: L10n.Reply.you
        case .agent: model.agentName
        case .crew(let from): from ?? model.agentName
        }
    }

    // MARK: updates

    func receive(_ update: ChatUpdate) {
        if applying {
            // Not replaced: what the one waiting had changed must still be set up.
            pending = pending.map { ChatUpdate.merge($0, update) } ?? update
            return
        }
        apply(update)
    }

    private func apply(_ update: ChatUpdate) {
        applying = true
        let previousRows = rowsByID
        rowsByID = Dictionary(update.rows.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let ids = update.rows.map(\.id)
        let oldCount = order.count
        let addedMessages = update.rows.suffix(max(0, ids.count - oldCount)).filter {
            if case .message = $0.content { return true } else { return false }
        }.count

        // What the person reads stays where it is, unless they follow the bottom.
        let following = atBottom || sendPinned || order.isEmpty
        var anchor: ThreadAnchor?
        if !following { anchor = captureAnchor() }

        listLayout.setRows(
            heights: ids.map { update.heights[$0] ?? 0 }, spacings: update.rows.map { CGFloat($0.spacing) })
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids)
        // Only a row that is on the list now and was before can be set up again (a missing one would be a crash).
        let shown = Set(order)
        let present = Set(ids)
        let changed = update.changed.filter { shown.contains($0) && present.contains($0) }
        // A row that became another kind of row (a card answered, now a line) gets a new cell; the rest are set up again.
        let remade = changed.filter { previousRows[$0]?.content.cellKind != rowsByID[$0]?.content.cellKind }
        let reconfigure = changed.filter { !remade.contains($0) }
        if !reconfigure.isEmpty { snapshot.reconfigureItems(reconfigure) }
        if !remade.isEmpty { snapshot.reloadItems(remade) }
        ChatCounters.shared.snapshotApplied(reconfigured: reconfigure.count)
        order = ids
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self else { return }
            self.collectionView.layoutIfNeeded()
            if let focus = self.focusRowID, update.initial, let index = self.order.firstIndex(of: focus), let frame = self.listLayout.frame(at: index) {
                // Opened at an entry: that row is at the top, and the chat is not following the bottom.
                self.focusRowID = nil
                self.atBottom = false
                self.collectionView.contentOffset = CGPoint(x: 0, y: max(0, min(frame.minY - 8, self.collectionView.contentSize.height - self.collectionView.bounds.height)))
            } else if following {
                self.scrollToBottom(animated: false)
            } else if let anchor, let index = self.order.firstIndex(of: anchor.rowID), let frame = self.listLayout.frame(at: index) {
                let target = anchor.offset(rowMinY: Double(frame.minY))
                self.collectionView.contentOffset = CGPoint(x: 0, y: CGFloat(target))
            }
            if !following, addedMessages > 0, !update.initial { self.unseen += addedMessages }
            self.rememberDistance()
            self.updateJump()
            self.updateEmpty()
            self.applying = false
            self.markReadIfSeen()
            if let next = self.pending {
                self.pending = nil
                self.apply(next)
            }
        }
    }

    private func captureAnchor() -> ThreadAnchor? {
        let visibleTop = Double(collectionView.contentOffset.y)
        let rect = CGRect(x: 0, y: collectionView.contentOffset.y, width: 1, height: collectionView.bounds.height)
        let attributes = listLayout.layoutAttributesForElements(in: rect) ?? []
        let rows = attributes.sorted { $0.indexPath.item < $1.indexPath.item }.compactMap { attribute -> (id: String, minY: Double, height: Double)? in
            guard order.indices.contains(attribute.indexPath.item) else { return nil }
            return (order[attribute.indexPath.item], Double(attribute.frame.minY), Double(attribute.frame.height))
        }
        return ThreadAnchor.capture(rows: rows, visibleTop: visibleTop)
    }

    // MARK: scrolling

    /// The row at the top of the screen and how far below the top its beginning is (tests keep a place with it).
    func topVisibleRow() -> (id: String, distance: Double)? {
        captureAnchor().map { ($0.rowID, $0.distanceFromTop) }
    }

    /// How far below the top of the screen the row begins now, nil when it is not in the list.
    func position(of id: String) -> Double? {
        guard let index = order.firstIndex(of: id), let frame = listLayout.frame(at: index) else { return nil }
        return Double(frame.minY - collectionView.contentOffset.y)
    }

    #if DEBUG
    /// Puts the first row whose id holds `part` at the top (the screenshots).
    func scrollToRow(idContaining part: String) {
        guard let index = order.firstIndex(where: { $0.contains(part) }), let frame = listLayout.frame(at: index) else { return }
        collectionView.setContentOffset(CGPoint(x: 0, y: max(0, frame.minY - 8)), animated: false)
    }
    #endif

    func scrollToBottom(animated: Bool) {
        let y = max(0, collectionView.contentSize.height - collectionView.bounds.height)
        collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: animated && !reduceMotion())
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let metrics = ThreadScrollMetrics(
            offset: Double(scrollView.contentOffset.y), contentHeight: Double(scrollView.contentSize.height),
            height: Double(scrollView.bounds.height))
        let flags = ThreadScroll.flags(was: atBottom, old: lastMetrics, new: metrics, pinned: sendPinned)
        if sendPinned, !ThreadFollowRules.holds(
            pinned: true, leavesBottom: lastMetrics.map { ThreadScroll.leavesBottom(old: $0, new: metrics) } ?? false,
            distance: metrics.distance, secondsSinceSend: Date().timeIntervalSince(lastSend))
        {
            sendPinned = false
        }
        lastMetrics = metrics
        #if DEBUG
        scrollView.accessibilityValue = "offset=\(Int(metrics.offset)) distance=\(metrics.distance) pinned=\(sendPinned) atBottom=\(atBottom)"
        #endif
        rememberDistance()
        if flags.atBottom != atBottom {
            atBottom = flags.atBottom
            if atBottom { unseen = 0 }
        }
        updateJump()
        if ThreadScroll.nearTop(offset: Double(scrollView.contentOffset.y)), model.hasOlder, !applying {
            model.loadOlder()
        }
        if atBottom { markReadIfSeen() }
    }

    private var lastSend = Date.distantPast

    private func markReadIfSeen() {
        guard visible, atBottom, UIApplication.shared.applicationState == .active else { return }
        model.summary.markRead()
    }

    // MARK: jump button

    private func setUpJumpButton() {
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = UIColor.Bandito.surface3
        configuration.baseForegroundColor = UIColor.Bandito.text
        configuration.image = UIImage(systemName: "arrow.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold))
        configuration.imagePadding = 6
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 12)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { container in
            var container = container
            container.font = BanditoFont.uiText(size: 13, weight: 600)
            return container
        }
        jumpButton.configuration = configuration
        jumpButton.layer.borderWidth = 1
        jumpButton.layer.cornerRadius = 19
        jumpButton.layer.borderColor = UIColor.Bandito.text.withAlphaComponent(0.12).cgColor
        jumpButton.alpha = 0
        jumpButton.isHidden = true
        jumpButton.accessibilityIdentifier = "chat.jump"
        jumpButton.accessibilityLabel = L10n.Thread.jumpToLatest
        jumpButton.addAction(
            UIAction { [weak self] _ in
                self?.sendPinned = false
                self?.scrollToBottom(animated: true)
            }, for: .touchUpInside)
        view.addSubview(jumpButton)
    }

    private func updateJump() {
        let show = ThreadScroll.showsJump(atBottom: atBottom, distance: lastMetrics?.distance)
        var configuration = jumpButton.configuration
        switch ThreadJumpRules.caption(unseen: ThreadJumpRules.countsAsUnseen(atBottom: atBottom, sendPinned: sendPinned) ? unseen : 0) {
        case .arrowOnly: configuration?.title = nil
        case .count(let count): configuration?.title = L10n.Thread.jumpNew(count: count)
        case .overflow: configuration?.title = L10n.Thread.jumpMany
        }
        jumpButton.configuration = configuration
        guard show != !jumpButton.isHidden || (show && jumpButton.alpha == 0) else { return }
        if show { jumpButton.isHidden = false }
        let animations = { self.jumpButton.alpha = show ? 1 : 0 }
        let finished: (Bool) -> Void = { _ in if !show { self.jumpButton.isHidden = true } }
        if reduceMotion() {
            animations()
            finished(true)
        } else {
            UIView.animate(withDuration: BanditoMotion.base, animations: animations, completion: finished)
        }
    }

    private func layoutOverlay() {
        let size = jumpButton.sizeThatFits(CGSize(width: 220, height: 40))
        let bottom = collectionView.frame.maxY - 12
        jumpButton.frame = CGRect(x: view.bounds.width - size.width - 14, y: bottom - 38, width: size.width, height: 38)
        banner.frame = CGRect(x: 0, y: collectionView.frame.minY, width: view.bounds.width, height: 30)
    }

    // MARK: banner and empty state

    private func setUpBanner() {
        banner.font = BanditoFont.uiText(size: 12.5, weight: 500)
        banner.textColor = UIColor.Bandito.text2
        banner.textAlignment = .center
        banner.backgroundColor = UIColor.Bandito.surface2
        banner.isHidden = true
        banner.accessibilityIdentifier = "chat.banner"
        view.addSubview(banner)
    }

    private func updateBanner() {
        let state = model.server.state
        switch state {
        case .connected, .connecting:
            banner.isHidden = true
        case .reconnecting:
            banner.text = L10n.Ios.Chat.Connection.reconnecting
            banner.isHidden = false
        case .disconnected, .failed:
            banner.text = L10n.Ios.Chat.Connection.offline
            banner.isHidden = false
        }
    }

    private func updateEmpty() {
        let empty = order.isEmpty && !model.isLoading && !model.loadFailed
        if empty, emptyHost == nil {
            let agent = model.server.agents.first { $0.id == model.agentID }
            let suggestions = agent.map(ThreadEmptyRules.suggestions(for:)) ?? []
            let host = UIHostingController(
                rootView: ChatEmptyView(
                    name: model.agentName, look: agent.map(CrewLook.init(agent:)) ?? CrewLook(color: .peach, face: .auto, customHex: nil),
                    suggestions: suggestions,
                    onPick: { [weak self] text in
                        self?.composer.text = text
                        self?.composer.textField.becomeFirstResponder()
                    }))
            host.view.backgroundColor = .clear
            addChild(host)
            view.insertSubview(host.view, aboveSubview: collectionView)
            host.didMove(toParent: self)
            host.view.frame = collectionView.frame
            emptyHost = host
        } else if !empty, let host = emptyHost {
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
            emptyHost = nil
        }
    }

    // MARK: frame state (the box, the banner)

    private func trackFrame() {
        withObservationTracking {
            let summary = model.summary
            _ = summary.turnRunning
            _ = summary.quickReplies
            _ = summary.pendingForms
            _ = model.server.state
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.applyFrame()
                self?.trackFrame()
            }
        }
        applyFrame()
    }

    private func applyFrame() {
        let summary = model.summary
        composer.setRunning(
            summary.turnRunning,
            waitsOnForm: ComposerSendMode.formToAnswer(in: summary.pendingForms, supportsReply: model.server.supports("form_reply")) != nil)
        composer.setQuickReplies(summary.quickReplies)
        updateBanner()
    }

    // MARK: composer

    private func setUpComposer() {
        composer.onSend = { [weak self] text, files in self?.sendFromComposer(text, files) }
        composer.onStop = { [weak self] in
            guard let self else { return }
            self.notifications.notificationOccurred(.warning)
            Task {
                switch await self.model.interrupt() {
                case .sent:
                    return
                case .offline:
                    self.explainStopFailed(L10n.Ios.Chat.stopFailed)
                case .failed:
                    self.explainStopFailed(L10n.Ios.Chat.stopFailedOther)
                }
            }
        }
        composer.onQuickReply = { [weak self] shown in
            guard let self else { return }
            self.impact.impactOccurred()
            self.noteSend()
            self.model.send(shown.reply, viaButton: true)
        }
        composer.onQuickLink = { [weak self] url in self?.openLink(url) }
        composer.onPickPhoto = { [weak self] in self?.pickPhoto() }
        composer.onTakePhoto = { [weak self] in self?.takePhoto() }
        composer.onPickFile = { [weak self] in self?.pickFile() }
        composer.onMic = { [weak self] in self?.toggleDictation() }
    }

    private func noteSend() {
        sendPinned = true
        lastSend = Date()
        unseen = 0
        scrollToBottom(animated: true)
    }

    private func sendFromComposer(_ text: String, _ files: [AgentAttachment]) {
        impact.impactOccurred()
        stopDictation()
        let summary = model.summary
        if composer.mode == .replyToForm, let formID = ComposerSendMode.formToAnswer(in: summary.pendingForms, supportsReply: true),
            files.isEmpty
        {
            Task {
                try? await model.server.answerForm(formID, in: model.agentID, action: .reply, message: text)
            }
        } else {
            model.send(text, attachments: files)
        }
        noteSend()
        clearDraft()
    }

    // MARK: drafts

    private var draftKey: String { "chat.draft.\(model.server.id.uuidString).\(model.agentID)" }

    private func saveDraft() {
        let text = composer.text
        if text.isEmpty { UserDefaults.standard.removeObject(forKey: draftKey) } else { UserDefaults.standard.set(text, forKey: draftKey) }
    }

    private func restoreDraft() {
        if let draft = UserDefaults.standard.string(forKey: draftKey), composer.text.isEmpty { composer.text = draft }
    }

    private func clearDraft() {
        UserDefaults.standard.removeObject(forKey: draftKey)
    }

    // MARK: cards

    func hostedContent(_ row: ChatRow) -> AnyView {
        let agentName = model.agentName
        let rowID = row.id
        let onHeight: (CGFloat) -> Void = { [weak self] height in
            self?.model.hostedHeightChanged(rowID: rowID, to: height)
        }
        switch row.content {
        case .approval(let approval):
            let needsFaceID = settings.riskyNeedsFaceID && ApprovalReason.isRisky(approval.reason)
            return AnyView(
                ChatApprovalCard(
                    row: approval, agentName: agentName, faceIDNeeded: needsFaceID,
                    onAnswer: { [weak self] allow, remember in
                        await self?.answer(approval, allow: allow, remember: remember) ?? .failed
                    }, onHeight: onHeight
                ).id(rowID))
        case .form(let form):
            return AnyView(
                ChatFormCard(
                    row: form, agentName: agentName,
                    onAnswer: { [weak self] action, values in await self?.answer(form, action: action, values: values) ?? false },
                    onHeight: onHeight
                ).id(rowID))
        case .connect(let connect):
            return AnyView(
                ChatConnectCard(
                    row: connect, agentName: agentName,
                    onDecline: { [weak self] in await self?.decline(connect) ?? false }, onHeight: onHeight
                ).id(rowID))
        default:
            return AnyView(EmptyView())
        }
    }

    private func answer(_ approval: ApprovalRow, allow: Bool, remember: Bool) async -> InboxAnswer.Outcome {
        let agent = model.server.agents.first { $0.id == model.agentID }
        let item = InboxItem(
            id: "approval-\(approval.approvalId)", serverID: model.server.id, serverName: model.server.config.name,
            agentID: model.agentID, agentName: model.agentName,
            look: agent.map(CrewLook.init(agent:)) ?? CrewLook(color: .peach, face: .auto, customHex: nil), mood: .idle,
            kind: .approval(approval), ts: approval.ts ?? 0)
        do {
            if allow {
                let outcome = try await InboxAnswer.allow(
                    item, server: model.server, remember: remember, riskyNeedsFaceID: settings.riskyNeedsFaceID,
                    authenticator: authenticator, reason: L10n.Ios.Inbox.faceIDReason)
                if outcome == .sent { notifications.notificationOccurred(.success) }
                return outcome
            }
            try await InboxAnswer.deny(item, server: model.server)
            notifications.notificationOccurred(.warning)
            return .sent
        } catch {
            return .failed
        }
    }

    private func answer(_ form: FormRow, action: FormAction, values: [String: JSONValue]?) async -> Bool {
        do {
            try await model.server.answerForm(form.formId, in: model.agentID, action: action, values: values)
            FormDrafts.shared.clear(formId: form.formId)
            if action == .submit { notifications.notificationOccurred(.success) } else { notifications.notificationOccurred(.warning) }
            return true
        } catch {
            return false
        }
    }

    private func decline(_ connect: ConnectRow) async -> Bool {
        do {
            try await model.server.declineConnect(connect.requestId)
            notifications.notificationOccurred(.warning)
            return true
        } catch {
            return false
        }
    }

    // MARK: cell actions

    func openLink(_ url: URL) {
        guard let web = ChatLinkSafety.webURL(url) else { return }
        let controller = SFSafariViewController(url: web)
        controller.preferredControlTintColor = UIColor.Bandito.signal
        present(controller, animated: !reduceMotion())
    }

    func copy(_ text: String) {
        UIPasteboard.general.string = text
    }

    func toggleFold(_ rowID: String) { model.toggle(rowID) }
    func resend(seq: Int64) { model.resend(seq: seq) }
    func retry(queueID: String) { model.retry(queueID: queueID) }
    func discard(queueID: String) { model.discard(queueID: queueID) }
    func openChanges() { onOpenChanges?() }

    // MARK: files and pictures

    private func pickPhoto() {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 4
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func takePhoto() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
        switch ChatCameraAccess.decision(for: AVCaptureDevice.authorizationStatus(for: .video)) {
        case .open:
            presentCamera()
        case .ask:
            Task { @MainActor [weak self] in
                // The system asks, with the reason from Info.plist.
                if await AVCaptureDevice.requestAccess(for: .video) {
                    self?.presentCamera()
                } else {
                    self?.explainDenied(L10n.Ios.Chat.Camera.denied)
                }
            }
        case .explain:
            explainDenied(L10n.Ios.Chat.Camera.denied)
        }
    }

    private func presentCamera() {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = self
        present(picker, animated: true)
    }

    private func pickFile() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = true
        present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        for result in results {
            let provider = result.itemProvider
            guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { continue }
            let id = composer.addFile(name: Self.photoName(), thumbnail: nil)
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] data, _ in
                Task { @MainActor in
                    guard let self else { return }
                    guard let data else { self.composer.setFile(id, .failed("")); return }
                    await self.attachPhoto(data, id: id)
                }
            }
        }
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        guard let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) else { return }
        let id = composer.addFile(name: Self.photoName(), thumbnail: nil)
        Task { await attachPhoto(data, id: id) }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        for url in urls {
            let name = url.lastPathComponent
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let id = composer.addFile(name: name, thumbnail: nil)
            if AttachmentRules.problem(name: name, size: size) != nil {
                composer.setFile(id, .failed(""))
                ChatTempFiles.remove(url)
                continue
            }
            Task {
                // The picker copied the file into the app's temporary folder: it goes once it is read.
                let data = await Task.detached { ChatTempFiles.readAndRemove(url) }.value
                guard let data else { composer.setFile(id, .failed("")); return }
                await upload(data, name: name, id: id, thumbnail: nil)
            }
        }
    }

    private static func photoName() -> String {
        let stamp = Int(Date().timeIntervalSince1970)
        return "photo-\(stamp).jpg"
    }

    /// A picture is reduced and made a JPEG off the main thread, then uploaded.
    private func attachPhoto(_ data: Data, id: UUID) async {
        let prepared = await Task.detached(priority: .userInitiated) { () -> (Data, UIImage)? in
            guard let image = ChatPictures.miniature(data, maxPixel: 2560), let jpeg = image.jpegData(compressionQuality: 0.85) else { return nil }
            let thumb = ChatPictures.miniature(jpeg, maxPixel: 240) ?? image
            return (jpeg, thumb)
        }.value
        guard let (jpeg, thumb) = prepared else { composer.setFile(id, .failed("")); return }
        let name = composer.files.first { $0.id == id }?.name ?? Self.photoName()
        if AttachmentRules.problem(name: name, size: Int64(jpeg.count)) != nil {
            composer.setFile(id, .failed(""))
            return
        }
        await upload(jpeg, name: name, id: id, thumbnail: thumb)
    }

    private func upload(_ data: Data, name: String, id: UUID, thumbnail: UIImage?) async {
        do {
            let saved = try await model.server.uploadAttachment(data, name: name, agentId: model.agentID)
            if let thumbnail { ChatPictures.store(thumbnail, path: saved.path) }
            composer.setFile(id, .ready(saved))
        } catch {
            composer.setFile(id, .failed(""))
        }
    }

    // MARK: dictation

    private func toggleDictation() {
        if let dictation, dictation.isListening {
            stopDictation()
            return
        }
        let controller = dictation ?? ChatDictation()
        dictation = controller
        guard ChatDictation.hasAsked else {
            let alert = UIAlertController(
                title: L10n.Ios.Chat.Dictation.explainTitle, message: L10n.Ios.Chat.Dictation.explainMessage, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
            alert.addAction(
                UIAlertAction(title: L10n.Composer.NewChapter.continue, style: .default) { [weak self] _ in self?.startDictation() })
            present(alert, animated: !reduceMotion())
            return
        }
        startDictation()
    }

    private func startDictation() {
        guard let dictation else { return }
        dictationBase = composer.text
        composer.setDictating(true)
        Task { @MainActor [weak self] in
            let outcome = await dictation.start(
                onPartial: { [weak self] partial in
                    guard let self else { return }
                    let separator = self.dictationBase.isEmpty || self.dictationBase.hasSuffix(" ") || self.dictationBase.hasSuffix("\n") ? "" : " "
                    self.composer.text = self.dictationBase + separator + partial
                },
                onEnd: { [weak self] in self?.composer.setDictating(false) })
            guard let self else { return }
            composer.setDictating(dictation.isListening)
            switch outcome {
            case .started, .finished: break
            case .deniedMicrophone: explainDenied(L10n.Ios.Chat.Dictation.deniedMicrophone)
            case .deniedSpeech: explainDenied(L10n.Ios.Chat.Dictation.deniedSpeech)
            case .unavailable: explainDenied(L10n.Ios.Chat.Dictation.unavailable, settingsButton: false)
            case .failed: explainDenied(L10n.Dictation.failed, settingsButton: false)
            }
        }
    }

    private func stopDictation() {
        dictation?.stop()
        composer.setDictating(false)
    }

    /// The stop did not reach the agent: a buzz, and the reason in words.
    private func explainStopFailed(_ message: String) {
        notifications.notificationOccurred(.error)
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.Common.close, style: .default))
        present(alert, animated: !reduceMotion())
    }

    private func explainDenied(_ message: String, settingsButton: Bool = true) {
        composer.setDictating(false)
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.Common.close, style: .cancel))
        if settingsButton {
            alert.addAction(
                UIAlertAction(title: L10n.Ios.Chat.openSettings, style: .default) { _ in
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                })
        }
        present(alert, animated: !reduceMotion())
    }
}
