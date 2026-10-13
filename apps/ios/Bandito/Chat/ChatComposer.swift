import BanditoDesign
import BanditoKit
import BanditoL10n
import UIKit

/// A file the person is attaching: being uploaded, ready, or refused.
struct ChatDraftFile: Identifiable {
    enum State {
        case uploading
        case ready(AgentAttachment)
        case failed(String)
    }

    let id = UUID()
    var name: String
    var thumbnail: UIImage?
    var state: State

    var attachment: AgentAttachment? {
        if case .ready(let file) = state { return file }
        return nil
    }
}

/// The message box: a field that grows to six lines, a button for files and pictures, one for dictation, one that sends
/// (and stops a running turn), the agent's quick replies above it and the files being attached. The text is read only
/// here; the screen is told when the box gets or loses its first character, never at each letter.
@MainActor
final class ChatComposerView: UIView, UITextViewDelegate {
    enum Mode: Equatable {
        case send
        case stop
        /// The agent waits on a form: the typed message answers it.
        case replyToForm
    }

    // Callbacks, set by the screen.
    var onSend: ((_ text: String, _ files: [AgentAttachment]) -> Void)?
    var onStop: (() -> Void)?
    var onPickPhoto: (() -> Void)?
    var onTakePhoto: (() -> Void)?
    var onPickFile: (() -> Void)?
    var onMic: (() -> Void)?
    var onQuickReply: ((QuickRepliesRules.Shown) -> Void)?
    var onQuickLink: ((URL) -> Void)?
    /// The box went from empty to something, or back.
    var onHasContentChange: ((Bool) -> Void)?

    private let field = UITextView()
    private let placeholder = UILabel()
    private let box = UIView()
    private let attachButton = UIButton(type: .system)
    private let micButton = UIButton(type: .system)
    private let sendButton = UIButton(type: .system)
    private let quickBar = ChatQuickRepliesBar()
    private let tray = ChatAttachmentTray()
    private let hairline = UIView()
    private var heightConstraint: NSLayoutConstraint!
    private(set) var hasText = false
    private var running = false
    private var waitsOnForm = false
    private(set) var files: [ChatDraftFile] = []
    private let lineLimit = 6

    var textField: UITextView { field }

    var mode: Mode {
        let content = hasText || !readyFiles.isEmpty
        if content { return waitsOnForm && running ? .replyToForm : .send }
        return running ? .stop : .send
    }

    var text: String {
        get { field.text ?? "" }
        set {
            field.text = newValue
            textChanged()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ChatComposerView, _) in
            view.updateColors()
            view.updateButtons()
        }
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: build

    private func build() {
        backgroundColor = UIColor.Bandito.bg
        hairline.backgroundColor = UIColor.Bandito.line
        hairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hairline)

        box.backgroundColor = UIColor.Bandito.surface1
        box.layer.cornerRadius = 20
        box.layer.cornerCurve = .continuous
        box.layer.borderWidth = 1

        field.backgroundColor = .clear
        field.font = BanditoFont.uiText(size: 16, weight: 400)
        field.textColor = UIColor.Bandito.text
        field.tintColor = UIColor.Bandito.signal
        field.textContainerInset = UIEdgeInsets(top: 9, left: 12, bottom: 9, right: 0)
        field.textContainer.lineFragmentPadding = 0
        field.delegate = self
        field.isScrollEnabled = false
        field.keyboardDismissMode = .interactive
        field.autocorrectionType = .default
        field.accessibilityIdentifier = "chat.composer.field"
        field.accessibilityLabel = L10n.Thread.placeholder
        field.translatesAutoresizingMaskIntoConstraints = false

        placeholder.text = L10n.Thread.placeholder
        placeholder.font = field.font
        placeholder.textColor = UIColor.Bandito.text3
        placeholder.numberOfLines = 1
        placeholder.isUserInteractionEnabled = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        style(attachButton, symbol: "plus", pointSize: 17, weight: .semibold, tint: UIColor.Bandito.text2)
        attachButton.menu = UIMenu(children: [
            UIAction(title: L10n.Ios.Chat.Attach.photos, image: UIImage(systemName: "photo.on.rectangle")) { [weak self] _ in
                self?.onPickPhoto?()
            },
            UIAction(title: L10n.Ios.Chat.Attach.camera, image: UIImage(systemName: "camera")) { [weak self] _ in
                self?.onTakePhoto?()
            },
            UIAction(title: L10n.Ios.Chat.Attach.files, image: UIImage(systemName: "doc")) { [weak self] _ in
                self?.onPickFile?()
            },
        ])
        attachButton.showsMenuAsPrimaryAction = true
        attachButton.accessibilityLabel = L10n.Thread.attach
        attachButton.accessibilityIdentifier = "chat.attach"

        style(micButton, symbol: "mic", pointSize: 15, weight: .medium, tint: UIColor.Bandito.text2)
        micButton.addAction(UIAction { [weak self] _ in self?.onMic?() }, for: .touchUpInside)
        micButton.accessibilityLabel = L10n.Thread.dictate
        micButton.accessibilityIdentifier = "chat.mic"

        sendButton.layer.cornerRadius = 18
        sendButton.layer.cornerCurve = .continuous
        sendButton.addAction(UIAction { [weak self] _ in self?.primaryTapped() }, for: .touchUpInside)
        sendButton.accessibilityIdentifier = "chat.send"
        sendButton.translatesAutoresizingMaskIntoConstraints = false

        quickBar.onReply = { [weak self] shown in self?.onQuickReply?(shown) }
        quickBar.onLink = { [weak self] url in self?.onQuickLink?(url) }
        tray.onRemove = { [weak self] id in self?.remove(id) }
        tray.isHidden = true
        quickBar.isHidden = true

        box.addSubview(field)
        box.addSubview(placeholder)
        box.addSubview(micButton)
        micButton.translatesAutoresizingMaskIntoConstraints = false

        let row = UIStackView(arrangedSubviews: [attachButton, box, sendButton])
        row.axis = .horizontal
        row.alignment = .bottom
        row.spacing = 6
        let stack = UIStackView(arrangedSubviews: [quickBar, tray, row])
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        heightConstraint = field.heightAnchor.constraint(equalToConstant: minHeight)
        NSLayoutConstraint.activate([
            hairline.topAnchor.constraint(equalTo: topAnchor),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 0.5),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            attachButton.widthAnchor.constraint(equalToConstant: 34),
            attachButton.heightAnchor.constraint(equalToConstant: 38),
            sendButton.widthAnchor.constraint(equalToConstant: 36),
            sendButton.heightAnchor.constraint(equalToConstant: 36),
            field.topAnchor.constraint(equalTo: box.topAnchor),
            field.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            field.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: micButton.leadingAnchor),
            heightConstraint,
            micButton.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -4),
            micButton.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -3),
            micButton.widthAnchor.constraint(equalToConstant: 34),
            micButton.heightAnchor.constraint(equalToConstant: 34),
            placeholder.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: micButton.leadingAnchor),
            placeholder.topAnchor.constraint(equalTo: box.topAnchor, constant: 9),
        ])
        updateColors()
        updateButtons()
    }

    private var minHeight: CGFloat { ceil((field.font?.lineHeight ?? 20) + 18) }
    private var maxHeight: CGFloat { ceil((field.font?.lineHeight ?? 20) * CGFloat(lineLimit) + 18) }

    private func style(_ button: UIButton, symbol: String, pointSize: CGFloat, weight: UIImage.SymbolWeight, tint: UIColor) {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight))
        configuration.baseForegroundColor = tint
        button.configuration = configuration
    }

    // MARK: state

    /// A turn runs: the primary button can stop it.
    func setRunning(_ running: Bool, waitsOnForm: Bool) {
        guard self.running != running || self.waitsOnForm != waitsOnForm else { return }
        self.running = running
        self.waitsOnForm = waitsOnForm
        updateButtons()
    }

    /// The agent's quick replies, or nothing.
    func setQuickReplies(_ replies: QuickReplies?) {
        quickBar.configure(replies)
        quickBar.isHidden = !quickBar.hasContent
    }

    /// The microphone is listening.
    func setDictating(_ on: Bool) {
        var configuration = micButton.configuration
        configuration?.image = UIImage(
            systemName: on ? "mic.fill" : "mic", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium))
        configuration?.baseForegroundColor = on ? UIColor.Bandito.danger : UIColor.Bandito.text2
        micButton.configuration = configuration
        micButton.accessibilityLabel = on ? L10n.Dictation.stop : L10n.Thread.dictate
    }

    private var readyFiles: [AgentAttachment] { files.compactMap(\.attachment) }
    private var isUploading: Bool {
        files.contains { if case .uploading = $0.state { return true } else { return false } }
    }

    private func updateButtons() {
        let mode = mode
        let canSend = (hasText || !readyFiles.isEmpty) && !isUploading
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = UIColor.Bandito.text
        configuration.baseForegroundColor = UIColor.Bandito.bg
        switch mode {
        case .stop:
            configuration.image = UIImage(systemName: "stop.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold))
            sendButton.accessibilityLabel = L10n.Thread.stop
            sendButton.accessibilityIdentifier = "chat.stop"
            sendButton.isEnabled = true
        case .send, .replyToForm:
            configuration.image = UIImage(systemName: "arrow.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .bold))
            sendButton.accessibilityLabel = L10n.Thread.send
            sendButton.accessibilityIdentifier = "chat.send"
            sendButton.isEnabled = canSend
        }
        sendButton.configuration = configuration
        sendButton.alpha = sendButton.isEnabled ? 1 : 0.35
    }

    // MARK: text

    func textViewDidChange(_ textView: UITextView) {
        textChanged()
    }

    private func textChanged() {
        let nowHasText = !field.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        placeholder.isHidden = !(field.text ?? "").isEmpty
        resize()
        if nowHasText != hasText {
            hasText = nowHasText
            updateButtons()
            onHasContentChange?(hasText || !readyFiles.isEmpty)
        }
    }

    /// The field grows with its text up to six lines, then scrolls.
    private func resize() {
        let width = field.bounds.width > 0 ? field.bounds.width : 240
        let wanted = field.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let height = min(max(wanted, minHeight), maxHeight)
        let scrolls = wanted > maxHeight
        if field.isScrollEnabled != scrolls { field.isScrollEnabled = scrolls }
        if abs(heightConstraint.constant - height) > 0.5 {
            heightConstraint.constant = height
            superview?.setNeedsLayout()
        }
        if scrolls, let range = field.selectedTextRange {
            field.scrollRectToVisible(field.caretRect(for: range.end), animated: false)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateColors()
    }


    private func updateColors() {
        box.layer.borderColor = UIColor.Bandito.line.resolvedColor(with: traitCollection).cgColor
        hairline.backgroundColor = UIColor.Bandito.line
    }

    // MARK: sending

    private func primaryTapped() {
        switch mode {
        case .stop:
            onStop?()
        case .send, .replyToForm:
            send()
        }
    }

    /// Sends what is in the box. The box empties at once; the screen owns the message from here.
    func send() {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = readyFiles
        guard (!typed.isEmpty || !attachments.isEmpty), !isUploading else { return }
        onSend?(typed, attachments)
        clear()
    }

    func clear() {
        field.text = ""
        files = []
        tray.configure(files)
        tray.isHidden = true
        textChanged()
        updateButtons()
    }

    // MARK: files

    /// A file the person picked: shown at once, ready when its upload is.
    @discardableResult
    func addFile(name: String, thumbnail: UIImage?) -> UUID {
        let file = ChatDraftFile(name: name, thumbnail: thumbnail, state: .uploading)
        files.append(file)
        refreshTray()
        return file.id
    }

    func setFile(_ id: UUID, _ state: ChatDraftFile.State) {
        guard let index = files.firstIndex(where: { $0.id == id }) else { return }
        files[index].state = state
        refreshTray()
        onHasContentChange?(hasText || !readyFiles.isEmpty)
    }

    private func remove(_ id: UUID) {
        files.removeAll { $0.id == id }
        refreshTray()
        onHasContentChange?(hasText || !readyFiles.isEmpty)
    }

    private func refreshTray() {
        tray.configure(files)
        tray.isHidden = files.isEmpty
        updateButtons()
    }
}

// MARK: - quick replies

/// The agent's quick replies as chips above the box: the first is the main one, a link button opens a page, and a
/// progress ("2 of 6") stands at the end.
@MainActor
final class ChatQuickRepliesBar: UIView {
    var onReply: ((QuickRepliesRules.Shown) -> Void)?
    var onLink: ((URL) -> Void)?

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private(set) var hasContent = false
    private var pressed: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: 40),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -4),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        isAccessibilityElement = false
        accessibilityLabel = L10n.QuickReplies.group
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ replies: QuickReplies?) {
        let shown = QuickRepliesRules.shown(replies, pressed: pressed)
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard let shown, let replies else {
            hasContent = false
            return
        }
        hasContent = true
        for button in QuickRepliesRules.buttons(shown) {
            stack.addArrangedSubview(chip(title: button.label, primary: button.isPrimary, symbol: nil) { [weak self] in
                self?.pressed = replies.id
                self?.hasContent = false
                self?.isHidden = true
                self?.onReply?(button)
            })
        }
        if let link = QuickRepliesRules.link(replies) {
            stack.addArrangedSubview(chip(title: QuickRepliesRules.caption(label: link.label, host: QuickRepliesRules.shownHost(link.host)), primary: false, symbol: "arrow.up.right") { [weak self] in
                self?.onLink?(link.url)
            })
        }
        if let progress = QuickRepliesRules.progressText(replies.progress) {
            let label = UILabel()
            label.text = progress
            label.font = BanditoFont.uiText(size: 12.5, weight: 500)
            label.textColor = UIColor.Bandito.text3
            stack.addArrangedSubview(label)
        }
        scroll.setContentOffset(.zero, animated: false)
    }

    private func chip(title: String, primary: Bool, symbol: String?, action: @escaping () -> Void) -> UIButton {
        var configuration = primary ? UIButton.Configuration.filled() : UIButton.Configuration.tinted()
        configuration.cornerStyle = .capsule
        configuration.title = title
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.baseBackgroundColor = primary ? UIColor.Bandito.text : UIColor.Bandito.surface2
        configuration.baseForegroundColor = primary ? UIColor.Bandito.bg : UIColor.Bandito.text
        if let symbol {
            configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
            configuration.imagePlacement = .trailing
            configuration.imagePadding = 5
        }
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { container in
            var container = container
            container.font = BanditoFont.uiText(size: 14, weight: 600)
            return container
        }
        let button = UIButton(configuration: configuration)
        button.layer.borderWidth = primary ? 0 : 1
        button.layer.borderColor = UIColor.Bandito.text.withAlphaComponent(0.14).cgColor
        button.layer.cornerRadius = 18
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        button.accessibilityIdentifier = "chat.quick"
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }
}

// MARK: - attachments

/// The files being attached, as small tiles above the box.
@MainActor
final class ChatAttachmentTray: UIView {
    var onRemove: ((UUID) -> Void)?

    private let scroll = UIScrollView()
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: 64),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -4),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ files: [ChatDraftFile]) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for file in files { stack.addArrangedSubview(tile(file)) }
    }

    private func tile(_ file: ChatDraftFile) -> UIView {
        let tile = UIView()
        tile.layer.cornerRadius = 12
        tile.layer.cornerCurve = .continuous
        tile.clipsToBounds = true
        tile.backgroundColor = UIColor.Bandito.surface2
        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.widthAnchor.constraint(equalToConstant: 64).isActive = true
        if let image = file.thumbnail {
            let view = UIImageView(image: image)
            view.contentMode = .scaleAspectFill
            view.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
            tile.addSubview(view)
        } else {
            let icon = UIImageView(image: UIImage(systemName: "doc"))
            icon.tintColor = UIColor.Bandito.text3
            icon.contentMode = .center
            icon.frame = CGRect(x: 0, y: 8, width: 64, height: 28)
            tile.addSubview(icon)
            let label = UILabel(frame: CGRect(x: 4, y: 38, width: 56, height: 20))
            label.text = file.name
            label.font = BanditoFont.uiText(size: 10, weight: 500)
            label.textColor = UIColor.Bandito.text2
            label.textAlignment = .center
            label.lineBreakMode = .byTruncatingMiddle
            tile.addSubview(label)
        }
        switch file.state {
        case .uploading:
            let veil = UIView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
            veil.backgroundColor = UIColor.Bandito.bg.withAlphaComponent(0.55)
            tile.addSubview(veil)
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.center = CGPoint(x: 32, y: 32)
            spinner.startAnimating()
            tile.addSubview(spinner)
            tile.accessibilityLabel = file.name + ", " + L10n.Composer.Attach.uploading
            tile.isAccessibilityElement = false
        case .failed:
            let veil = UIView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
            veil.backgroundColor = UIColor.Bandito.danger.withAlphaComponent(0.35)
            tile.addSubview(veil)
            let mark = UIImageView(image: UIImage(systemName: "exclamationmark.triangle.fill"))
            mark.tintColor = UIColor.Bandito.text
            mark.contentMode = .center
            mark.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
            tile.addSubview(mark)
            tile.accessibilityLabel = file.name + ", " + L10n.Composer.Attach.failed
        case .ready:
            tile.accessibilityLabel = file.name
        }
        let remove = UIButton(type: .system)
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = UIColor.black.withAlphaComponent(0.6)
        configuration.baseForegroundColor = .white
        configuration.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
        remove.configuration = configuration
        remove.frame = CGRect(x: 40, y: 2, width: 22, height: 22)
        let id = file.id
        remove.addAction(UIAction { [weak self] _ in self?.onRemove?(id) }, for: .touchUpInside)
        remove.accessibilityLabel = L10n.Composer.Attach.remove
        tile.addSubview(remove)
        tile.isUserInteractionEnabled = true
        return tile
    }
}
