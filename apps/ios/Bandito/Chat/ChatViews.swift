import BanditoDesign
import BanditoKit
import BanditoL10n
import ImageIO
import UIKit

// The small views the chat's cells are made of. They draw what the layout engine measured and keep no layout of their
// own: a frame and an attributed string are all they get.

/// Draws an attributed string in its bounds. No text system object lives between draws: the string was measured with
/// the same options off the main thread. A link under a point is found with a text layout made at that moment.
final class ChatTextView: UIView {
    var string: NSAttributedString? {
        didSet {
            guard string !== oldValue else { return }
            hitTesting = nil
            setNeedsDisplay()
        }
    }

    private var hitTesting: (storage: NSTextStorage, layout: NSLayoutManager, container: NSTextContainer)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ rect: CGRect) {
        string?.draw(with: bounds, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    }

    /// The web link under `point` (in this view's coordinates), when there is one.
    func link(at point: CGPoint) -> URL? {
        guard let string, string.length > 0, bounds.insetBy(dx: -6, dy: -6).contains(point) else { return nil }
        if hitTesting == nil {
            let storage = NSTextStorage(attributedString: string)
            let layout = NSLayoutManager()
            let container = NSTextContainer(size: CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            storage.addLayoutManager(layout)
            layout.ensureLayout(for: container)
            hitTesting = (storage, layout, container)
        }
        guard let hitTesting else { return nil }
        let glyph = hitTesting.layout.glyphIndex(for: point, in: hitTesting.container)
        let rect = hitTesting.layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: hitTesting.container)
        guard rect.insetBy(dx: -8, dy: -6).contains(point) else { return nil }
        let index = hitTesting.layout.characterIndexForGlyph(at: glyph)
        guard index < string.length else { return nil }
        return string.attribute(.chatLink, at: index, effectiveRange: nil) as? URL
    }
}

/// The bubble behind a message: 16 pt corners and a 6 pt tail corner on the speaker's side, as the Mac draws it. One
/// shape layer: a fill and an edge, no shadow.
final class ChatBubbleView: UIView {
    private let fill = CAShapeLayer()
    private let tint = CAShapeLayer()
    private let edge = CAShapeLayer()
    private var isMine = false
    private var hasTail = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ChatBubbleView, _) in
            view.updateColors()
        }
        layer.addSublayer(fill)
        layer.addSublayer(tint)
        layer.addSublayer(edge)
        edge.fillColor = nil
        edge.lineWidth = 1
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(mine: Bool, tail: Bool) {
        isMine = mine
        hasTail = tail
        updatePath()
        updateColors()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updatePath()
    }


    private func updatePath() {
        let r = bounds
        let big: CGFloat = 16
        let small: CGFloat = hasTail ? 6 : 16
        let bl = isMine ? big : small
        let br = isMine ? small : big
        let path = UIBezierPath()
        path.move(to: CGPoint(x: r.minX + big, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - big, y: r.minY))
        path.addArc(withCenter: CGPoint(x: r.maxX - big, y: r.minY + big), radius: big, startAngle: -.pi / 2, endAngle: 0, clockwise: true)
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - br))
        path.addArc(withCenter: CGPoint(x: r.maxX - br, y: r.maxY - br), radius: br, startAngle: 0, endAngle: .pi / 2, clockwise: true)
        path.addLine(to: CGPoint(x: r.minX + bl, y: r.maxY))
        path.addArc(withCenter: CGPoint(x: r.minX + bl, y: r.maxY - bl), radius: bl, startAngle: .pi / 2, endAngle: .pi, clockwise: true)
        path.addLine(to: CGPoint(x: r.minX, y: r.minY + big))
        path.addArc(withCenter: CGPoint(x: r.minX + big, y: r.minY + big), radius: big, startAngle: .pi, endAngle: -.pi / 2, clockwise: true)
        path.close()
        let cg = path.cgPath
        for shape in [fill, tint, edge] {
            shape.frame = bounds
            shape.path = cg
        }
    }

    private func updateColors() {
        let traits = traitCollection
        if isMine {
            fill.fillColor = UIColor.Bandito.surface2.resolvedColor(with: traits).cgColor
            tint.fillColor = UIColor.Bandito.text.withAlphaComponent(0.13).resolvedColor(with: traits).cgColor
            edge.strokeColor = UIColor.Bandito.text.withAlphaComponent(0.08).resolvedColor(with: traits).cgColor
        } else {
            fill.fillColor = UIColor.Bandito.surface1.resolvedColor(with: traits).cgColor
            tint.fillColor = nil
            edge.strokeColor = UIColor.Bandito.text.withAlphaComponent(0.06).resolvedColor(with: traits).cgColor
        }
    }
}

/// A fenced code block: the language and a Copy button on top, the code under them, scrolling sideways when a line is
/// wider than the block.
final class ChatCodeBlockView: UIView {
    var onCopy: ((String) -> Void)?

    private let language = UILabel()
    private let copyButton = UIButton(type: .system)
    private let scroll = UIScrollView()
    private let codeText = ChatTextView()
    private var item: ChatCodeItem?
    private var resetTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ChatCodeBlockView, _) in
            view.updateColors()
        }
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        clipsToBounds = true
        language.font = BanditoFont.uiMono(size: 11, weight: 500)
        language.textColor = UIColor.Bandito.text3
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceHorizontal = false
        scroll.alwaysBounceVertical = false
        scroll.delaysContentTouches = false
        scroll.contentInsetAdjustmentBehavior = .never
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "doc.on.doc", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        configuration.imagePadding = 5
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        configuration.baseForegroundColor = UIColor.Bandito.text2
        copyButton.configuration = configuration
        copyButton.titleLabel?.font = BanditoFont.uiText(size: 11.5, weight: 500)
        copyButton.setTitle(L10n.Thread.copy, for: .normal)
        copyButton.addAction(UIAction { [weak self] _ in self?.copy() }, for: .touchUpInside)
        copyButton.accessibilityLabel = L10n.Thread.copy
        addSubview(language)
        addSubview(copyButton)
        addSubview(scroll)
        scroll.addSubview(codeText)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ item: ChatCodeItem) {
        self.item = item
        language.text = item.language
        codeText.string = item.display
        resetCopy()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let item else { return }
        let header = item.header
        language.frame = CGRect(x: 12, y: 0, width: max(0, bounds.width - 110), height: header)
        let size = copyButton.sizeThatFits(CGSize(width: 140, height: header))
        copyButton.frame = CGRect(x: bounds.width - size.width - 4, y: (header - 26) / 2, width: size.width, height: 26)
        scroll.frame = CGRect(x: 0, y: header + 2, width: bounds.width, height: bounds.height - header - 2)
        let content = CGSize(width: item.contentSize.width + 24, height: item.contentSize.height)
        codeText.frame = CGRect(x: 12, y: 0, width: item.contentSize.width, height: item.contentSize.height)
        scroll.contentSize = CGSize(width: item.scrolls ? content.width : bounds.width, height: scroll.bounds.height)
        scroll.isScrollEnabled = item.scrolls
    }


    private func updateColors() {
        backgroundColor = UIColor.Bandito.bg
        layer.borderColor = UIColor.Bandito.line.resolvedColor(with: traitCollection).cgColor
    }

    private func copy() {
        guard let item else { return }
        onCopy?(item.code)
        var configuration = copyButton.configuration
        configuration?.image = UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        configuration?.baseForegroundColor = UIColor.Bandito.ok
        copyButton.configuration = configuration
        copyButton.setTitle(L10n.Message.copied, for: .normal)
        resetTask?.cancel()
        resetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { self?.resetCopy() }
        }
    }

    private func resetCopy() {
        resetTask?.cancel()
        var configuration = copyButton.configuration
        configuration?.image = UIImage(systemName: "doc.on.doc", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        configuration?.baseForegroundColor = UIColor.Bandito.text2
        copyButton.configuration = configuration
        copyButton.setTitle(L10n.Thread.copy, for: .normal)
    }
}

/// A picture of a message, or a stand-in until it is known. Only pictures this phone sent have bytes here: the server's
/// file route is not reachable over the direct connection yet (`ChatPictures`).
final class ChatPictureView: UIView {
    private let imageView = UIImageView()
    private let symbol = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ChatPictureView, _) in
            view.updateColors()
        }
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        symbol.contentMode = .center
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 26, weight: .regular)
        symbol.image = UIImage(systemName: "photo")
        symbol.tintColor = UIColor.Bandito.text3
        addSubview(symbol)
        addSubview(imageView)
        isAccessibilityElement = true
        accessibilityTraits = .image
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ file: AgentAttachment, image: UIImage?) {
        imageView.image = image
        imageView.isHidden = image == nil
        accessibilityLabel = file.name
        accessibilityHint = image == nil ? L10n.Ios.Chat.Attach.noPreview : nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        symbol.frame = bounds
    }


    private func updateColors() {
        backgroundColor = UIColor.Bandito.surface2
    }
}

/// A file of a message that is not a picture: a chip with an icon, the name and the size.
final class ChatFileChipView: UIView {
    private let icon = UIImageView()
    private let label = UILabel()
    private let size = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ChatFileChipView, _) in
            view.updateColors()
        }
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.5
        icon.image = UIImage(systemName: "doc")
        icon.tintColor = UIColor.Bandito.text3
        icon.contentMode = .scaleAspectFit
        label.font = BanditoFont.uiText(size: 12.5, weight: 500)
        label.textColor = UIColor.Bandito.text2
        label.lineBreakMode = .byTruncatingMiddle
        size.font = BanditoFont.uiText(size: 11.5, weight: 400)
        size.textColor = UIColor.Bandito.text3
        size.textAlignment = .right
        addSubview(icon)
        addSubview(label)
        addSubview(size)
        isAccessibilityElement = true
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ file: AgentAttachment) {
        label.text = file.name
        size.text = ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
        accessibilityLabel = file.name + ", " + (size.text ?? "")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        icon.frame = CGRect(x: 10, y: (bounds.height - 16) / 2, width: 16, height: 16)
        let sizeWidth: CGFloat = 54
        size.frame = CGRect(x: bounds.width - sizeWidth - 10, y: 0, width: sizeWidth, height: bounds.height)
        label.frame = CGRect(x: 32, y: 0, width: max(0, bounds.width - 32 - sizeWidth - 14), height: bounds.height)
    }


    private func updateColors() {
        layer.borderColor = UIColor.Bandito.line.resolvedColor(with: traitCollection).cgColor
        backgroundColor = UIColor.Bandito.surface1
    }
}

/// The pictures this phone sent, by the path the server saved them under: the bytes are here, so the thread shows them
/// where the server cannot be asked. Bounded.
@MainActor
enum ChatPictures {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 120
        return cache
    }()

    static func store(_ image: UIImage, path: String) {
        cache.setObject(image, forKey: path as NSString)
    }

    static func image(path: String) -> UIImage? {
        cache.object(forKey: path as NSString)
    }

    /// A picture reduced to `maxPixel` on its longest side, decoded off the main thread by ImageIO.
    nonisolated static func miniature(_ data: Data, maxPixel: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
    }
}
