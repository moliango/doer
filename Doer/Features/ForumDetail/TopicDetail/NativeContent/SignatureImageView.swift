import SDWebImage
import UIKit

/// FluxDo-aligned signature image:
/// - no gray 9:16 placeholder while loading
/// - collapse to zero height on failure
/// - only tappable after a real image loads (avoids gallery crash on non-image URLs)
final class SignatureImageView: UIView {
    weak var delegate: PostCellDelegate?

    private let imageView: SDAnimatedImageView = {
        let view = SDAnimatedImageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        view.backgroundColor = .clear
        return view
    }()

    private var heightConstraint: NSLayoutConstraint!
    private var widthConstraint: NSLayoutConstraint!
    private let maxHeight: CGFloat
    private let containerWidth: CGFloat
    private let imageURL: URL
    private var didLoadSuccessfully = false
    private let refererBaseURL: String?

    init(url: URL, containerWidth: CGFloat, maxHeight: CGFloat = 150, refererBaseURL: String? = nil) {
        self.imageURL = url
        self.containerWidth = max(containerWidth, 1)
        self.maxHeight = max(maxHeight, 1)
        self.refererBaseURL = refererBaseURL
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setup()
        load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func cancelImageLoad() {
        imageView.sd_cancelCurrentImageLoad()
    }

    private func setup() {
        addSubview(imageView)
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        heightConstraint.priority = .required
        widthConstraint = imageView.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthConstraint,
            heightConstraint,
            trailingAnchor.constraint(greaterThanOrEqualTo: imageView.trailingAnchor),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)
        isUserInteractionEnabled = true
    }

    private func load() {
        // Browser / FluxDo: no placeholder while loading; only occupy space after success.
        heightConstraint.constant = 0
        widthConstraint.constant = 0
        didLoadSuccessfully = false
        imageView.image = nil

        ForumImageLoader.setImage(
            on: imageView,
            url: imageURL,
            cloudflareBaseURL: refererBaseURL
        ) { [weak self] image, _, _, _ in
            guard let self else { return }
            self.applyLoadedImage(image)
        }
    }

    private func applyLoadedImage(_ image: UIImage?) {
        guard let image, image.size.width > 0, image.size.height > 0 else {
            didLoadSuccessfully = false
            imageView.image = nil
            heightConstraint.constant = 0
            widthConstraint.constant = 0
            invalidateIntrinsicContentSize()
            notifyTableViewHeightChange()
            return
        }

        didLoadSuccessfully = true
        imageView.image = image

        let aspect = image.size.height / image.size.width
        var displayWidth = min(containerWidth, image.size.width)
        var displayHeight = displayWidth * aspect
        if displayHeight > maxHeight {
            displayHeight = maxHeight
            displayWidth = displayHeight / aspect
        }
        widthConstraint.constant = max(displayWidth, 1)
        heightConstraint.constant = max(displayHeight, 1)
        invalidateIntrinsicContentSize()
        notifyTableViewHeightChange()
    }

    private func notifyTableViewHeightChange() {
        var view: UIView? = superview
        while let current = view {
            if let cell = current as? PostNativeCell {
                cell.requestHeightReconciliation()
                return
            }
            if let cell = current as? WeChatChatPostCell {
                cell.requestHeightReconciliation()
                return
            }
            if let tableView = current as? UITableView {
                tableView.doer_invalidateSelfSizingRows()
                return
            }
            view = current.superview
        }
    }

    @objc private func handleTap() {
        guard didLoadSuccessfully else { return }
        delegate?.postCell(didTapImageURL: imageURL, imageURLs: [imageURL], sourceView: imageView)
    }
}
