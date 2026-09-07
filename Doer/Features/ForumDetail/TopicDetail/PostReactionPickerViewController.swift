import UIKit

/// Compact horizontal reaction strip shared by classic posts and chat bubbles.
final class PostReactionPickerViewController: UIViewController, UIPopoverPresentationControllerDelegate {
    var onSelect: ((String) -> Void)?

    private let reactionIds: [String]

    init(reactionIds: [String]) {
        self.reactionIds = reactionIds
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .popover
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor.secondarySystemGroupedBackground
                : UIColor.systemBackground
        }

        let emojiSize: CGFloat = 28
        let hitSize: CGFloat = 36
        let hPad: CGFloat = 10
        let vPad: CGFloat = 8
        let spacing: CGFloat = 6

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = reactionIds.count > 8
        scroll.clipsToBounds = true
        view.addSubview(scroll)

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = spacing
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: vPad),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -vPad),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: hPad),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -hPad),
            stack.heightAnchor.constraint(equalToConstant: hitSize),
        ])

        for reactionId in reactionIds {
            stack.addArrangedSubview(makeReactionButton(id: reactionId, hitSize: hitSize, emojiSize: emojiSize))
        }

        let count = max(reactionIds.count, 1)
        let contentWidth = CGFloat(count) * hitSize + CGFloat(max(count - 1, 0)) * spacing + hPad * 2
        let screenCap = min(UIScreen.main.bounds.width - 48, 320)
        preferredContentSize = CGSize(
            width: min(contentWidth, screenCap),
            height: hitSize + vPad * 2
        )
    }

    static func present(
        reactionIds: [String],
        from sourceView: UIView,
        onSelect: @escaping (String) -> Void
    ) {
        guard !reactionIds.isEmpty, let host = presentingViewController(from: sourceView) else { return }
        let picker = PostReactionPickerViewController(reactionIds: reactionIds)
        picker.onSelect = onSelect
        if let popover = picker.popoverPresentationController {
            popover.sourceView = sourceView
            popover.sourceRect = sourceView.bounds.insetBy(dx: 4, dy: 4)
            popover.permittedArrowDirections = [.up, .down]
            popover.delegate = picker
            if #available(iOS 15.0, *) {
                popover.backgroundColor = picker.view.backgroundColor
            }
        }

        if host.presentedViewController != nil {
            host.dismiss(animated: false) {
                host.present(picker, animated: true)
            }
        } else {
            host.present(picker, animated: true)
        }
    }

    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle {
        .none
    }

    private func makeReactionButton(id reactionId: String, hitSize: CGFloat, emojiSize: CGFloat) -> UIButton {
        let button = UIButton(type: .custom)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = reactionId
        button.layer.cornerRadius = hitSize / 2
        button.clipsToBounds = true
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: hitSize),
            button.heightAnchor.constraint(equalToConstant: hitSize),
        ])

        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.isUserInteractionEnabled = false
        button.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: emojiSize),
            imageView.heightAnchor.constraint(equalToConstant: emojiSize),
        ])

        if let urlString = EmojiStore.url(for: reactionId) ?? EmojiStore.lookup(for: reactionId),
           let url = URL(string: urlString) {
            ForumImageLoader.setImage(on: imageView, url: url)
        } else if reactionId == "heart" {
            let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
            imageView.image = UIImage(systemName: "heart.fill", withConfiguration: config)
            imageView.tintColor = .systemPink
        } else {
            let label = UILabel()
            label.text = String(reactionId.prefix(1)).uppercased()
            label.font = .systemFont(ofSize: 14, weight: .bold)
            label.textAlignment = .center
            label.textColor = .secondaryLabel
            label.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            ])
        }

        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let selected = reactionId
            self.dismiss(animated: true) {
                self.onSelect?(selected)
            }
        }, for: .touchUpInside)
        return button
    }

    private static func presentingViewController(from view: UIView) -> UIViewController? {
        var responder: UIResponder? = view
        while let current = responder {
            if let viewController = current as? UIViewController {
                return viewController
            }
            responder = current.next
        }
        return nil
    }
}
