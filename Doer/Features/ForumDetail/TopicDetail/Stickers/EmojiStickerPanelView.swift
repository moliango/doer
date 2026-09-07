import UIKit

/// Dual-tab panel: standard Discourse emoji + sticker packs.
final class EmojiStickerPanelView: UIView {
    var onEmojiSelected: ((String) -> Void)? {
        didSet { emojiPicker.onEmojiSelected = onEmojiSelected }
    }

    var onStickerMarkdownSelected: ((String) -> Void)?
    weak var presentingViewController: UIViewController?

    private enum Mode: Int {
        case emoji = 0
        case sticker = 1
    }

    private var mode: Mode = .emoji {
        didSet { applyMode() }
    }

    private let emojiPicker = EmojiPickerView()
    private let stickerPicker = StickerPickerView()

    private lazy var modeControl: UISegmentedControl = {
        let control = UISegmentedControl(items: [
            String(localized: "sticker.tab.emoji", defaultValue: "表情"),
            String(localized: "sticker.tab.sticker", defaultValue: "表情包"),
        ])
        control.translatesAutoresizingMaskIntoConstraints = false
        control.selectedSegmentIndex = 0
        control.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        return control
    }()

    private lazy var marketButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(UIImage(systemName: "plus.square.on.square"), for: .normal)
        button.accessibilityLabel = String(localized: "sticker.market.title", defaultValue: "表情包市场")
        button.addTarget(self, action: #selector(marketButtonTapped), for: .touchUpInside)
        return button
    }()

    private let modeChrome: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .systemBackground
        return view
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        emojiPicker.translatesAutoresizingMaskIntoConstraints = false
        stickerPicker.translatesAutoresizingMaskIntoConstraints = false
        stickerPicker.onRequestMarket = { [weak self] in
            self?.openMarket()
        }
        stickerPicker.onStickerSelected = { [weak self] item in
            self?.onStickerMarkdownSelected?(item.markdown)
        }

        addSubview(emojiPicker)
        addSubview(stickerPicker)
        addSubview(modeChrome)
        modeChrome.addSubview(modeControl)
        modeChrome.addSubview(marketButton)

        NSLayoutConstraint.activate([
            emojiPicker.topAnchor.constraint(equalTo: topAnchor),
            emojiPicker.leadingAnchor.constraint(equalTo: leadingAnchor),
            emojiPicker.trailingAnchor.constraint(equalTo: trailingAnchor),
            emojiPicker.bottomAnchor.constraint(equalTo: modeChrome.topAnchor),

            stickerPicker.topAnchor.constraint(equalTo: topAnchor),
            stickerPicker.leadingAnchor.constraint(equalTo: leadingAnchor),
            stickerPicker.trailingAnchor.constraint(equalTo: trailingAnchor),
            stickerPicker.bottomAnchor.constraint(equalTo: modeChrome.topAnchor),

            modeChrome.leadingAnchor.constraint(equalTo: leadingAnchor),
            modeChrome.trailingAnchor.constraint(equalTo: trailingAnchor),
            modeChrome.bottomAnchor.constraint(equalTo: bottomAnchor),
            modeChrome.heightAnchor.constraint(equalToConstant: 52),

            modeControl.centerXAnchor.constraint(equalTo: modeChrome.centerXAnchor),
            modeControl.centerYAnchor.constraint(equalTo: modeChrome.centerYAnchor),
            modeControl.widthAnchor.constraint(equalToConstant: 220),

            marketButton.centerYAnchor.constraint(equalTo: modeChrome.centerYAnchor),
            marketButton.trailingAnchor.constraint(equalTo: modeChrome.trailingAnchor, constant: -16),
            marketButton.widthAnchor.constraint(equalToConstant: 36),
            marketButton.heightAnchor.constraint(equalToConstant: 36),
        ])
        applyMode()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showLoading() { emojiPicker.showLoading() }
    func showError() { emojiPicker.showError() }
    func setEmojiGroups(_ groups: [DiscourseEmojiGroup], baseURL: String) {
        emojiPicker.setEmojiGroups(groups, baseURL: baseURL)
    }

    func reloadStickers() {
        stickerPicker.reloadFromStore()
    }

    @objc private func modeChanged() {
        mode = Mode(rawValue: modeControl.selectedSegmentIndex) ?? .emoji
        if mode == .sticker {
            stickerPicker.reloadFromStore()
        }
    }

    private func applyMode() {
        emojiPicker.isHidden = mode != .emoji
        stickerPicker.isHidden = mode != .sticker
        modeControl.selectedSegmentIndex = mode.rawValue
        marketButton.isHidden = mode != .sticker
    }

    @objc private func marketButtonTapped() {
        openMarket()
    }

    private func openMarket() {
        guard let presenter = presentingViewController else { return }
        let market = StickerMarketViewController()
        market.onSubscriptionsChanged = { [weak self] in
            self?.stickerPicker.reloadFromStore()
        }
        let nav = UINavigationController(rootViewController: market)
        presenter.present(nav, animated: true)
    }
}
