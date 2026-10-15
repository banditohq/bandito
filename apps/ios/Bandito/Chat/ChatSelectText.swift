import BanditoDesign
import BanditoL10n
import UIKit

/// A message's words in a sheet where any part can be selected and copied (a message in the list is a drawn picture of
/// text, not a text view). The text cannot be edited.
@MainActor
final class ChatSelectTextController: UIViewController {
    private let text: String
    let textView = UITextView()
    private let header = UILabel()
    private let done = UIButton(type: .system)

    init(text: String) {
        self.text = text
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.Bandito.bg
        header.text = L10n.Message.selectText
        header.font = BanditoFont.uiDisplay(size: 17, weight: 600)
        header.textColor = UIColor.Bandito.text
        header.adjustsFontForContentSizeCategory = true
        header.accessibilityTraits = .header
        var configuration = UIButton.Configuration.plain()
        configuration.baseForegroundColor = UIColor.Bandito.signal
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { container in
            var container = container
            container.font = BanditoFont.uiText(size: 16, weight: 600)
            return container
        }
        done.configuration = configuration
        done.setTitle(L10n.Ios.Chat.SelectText.done, for: .normal)
        done.accessibilityIdentifier = "chat.selectText.done"
        done.addAction(UIAction { [weak self] _ in self?.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) }, for: .touchUpInside)
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.font = BanditoFont.uiText(size: 17, weight: 400)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = UIColor.Bandito.text
        textView.tintColor = UIColor.Bandito.signal
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 16, bottom: 16, right: 16)
        textView.text = text
        textView.accessibilityIdentifier = "chat.selectText.text"
        for item in [header, done, textView] as [UIView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(lessThanOrEqualTo: done.leadingAnchor, constant: -8),
            done.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            done.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            textView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}
