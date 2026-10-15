import BanditoDesign
import BanditoL10n
import UIKit

/// What the chat says in the place of the list while it has nothing to draw: a spinner while the history is read, and
/// when it could not be read, what happened with "Try again". Never an empty screen.
@MainActor
final class ChatStateOverlay: UIView {
    enum Mode: Equatable {
        case none
        case loading
        case failed(name: String)
    }

    private(set) var mode: Mode = .none
    var onRetry: (() -> Void)?

    private let spinner = UIActivityIndicatorView(style: .medium)
    private let icon = UIImageView()
    private let title = UILabel()
    private let message = UILabel()
    private let retry = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        spinner.color = UIColor.Bandito.text3
        spinner.hidesWhenStopped = true
        spinner.accessibilityIdentifier = "chat.loading"
        spinner.accessibilityLabel = L10n.Ios.Chat.loading
        icon.image = UIImage(
            systemName: "wifi.exclamationmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 30, weight: .regular))
        icon.tintColor = UIColor.Bandito.text3
        icon.contentMode = .scaleAspectFit
        title.font = BanditoFont.uiDisplay(size: 17, weight: 600)
        title.textColor = UIColor.Bandito.text
        title.textAlignment = .center
        title.numberOfLines = 0
        title.adjustsFontForContentSizeCategory = true
        message.font = BanditoFont.uiText(size: 14, weight: 400)
        message.textColor = UIColor.Bandito.text2
        message.textAlignment = .center
        message.numberOfLines = 0
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = UIColor.Bandito.signal
        configuration.baseForegroundColor = UIColor.Bandito.onSignal
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 20)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { container in
            var container = container
            container.font = BanditoFont.uiText(size: 15, weight: 600)
            return container
        }
        retry.configuration = configuration
        retry.setTitle(L10n.Ios.Chat.retry, for: .normal)
        retry.accessibilityIdentifier = "chat.retryLoad"
        retry.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .touchUpInside)
        title.accessibilityIdentifier = "chat.loadFailed"
        for view in [spinner, icon, title, message, retry] as [UIView] { addSubview(view) }
        set(.none)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func set(_ new: Mode) {
        mode = new
        let failed: Bool
        switch new {
        case .none:
            spinner.stopAnimating()
            failed = false
        case .loading:
            spinner.startAnimating()
            failed = false
        case .failed(let name):
            spinner.stopAnimating()
            title.text = L10n.Ios.Chat.LoadFailed.title
            message.text = L10n.Ios.Chat.LoadFailed.message(name: name)
            failed = true
        }
        for view in [icon, title, message, retry] as [UIView] { view.isHidden = !failed }
        isHidden = new == .none
        // The spinner lets touches through (the box and the list stay usable); the failure takes its button's.
        isUserInteractionEnabled = failed
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = min(bounds.width - 2 * BanditoSpace.s6, 320)
        let midX = bounds.midX
        guard mode != .none else { return }
        if mode == .loading {
            spinner.center = CGPoint(x: midX, y: bounds.midY)
            return
        }
        let titleSize = title.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let messageSize = message.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let buttonSize = retry.sizeThatFits(CGSize(width: width, height: 60))
        let gap = BanditoSpace.s3
        let iconHeight: CGFloat = 36
        let total = iconHeight + gap + titleSize.height + 6 + messageSize.height + gap + buttonSize.height
        var y = max(BanditoSpace.s4, (bounds.height - total) / 2)
        icon.frame = CGRect(x: midX - 20, y: y, width: 40, height: iconHeight)
        y += iconHeight + gap
        title.frame = CGRect(x: midX - width / 2, y: y, width: width, height: titleSize.height)
        y += titleSize.height + 6
        message.frame = CGRect(x: midX - width / 2, y: y, width: width, height: messageSize.height)
        y += messageSize.height + gap
        retry.frame = CGRect(x: midX - buttonSize.width / 2, y: y, width: buttonSize.width, height: buttonSize.height)
    }
}
