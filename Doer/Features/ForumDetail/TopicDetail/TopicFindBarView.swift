import UIKit

/// In-topic find chrome: query, result count, previous/next, close.
final class TopicFindBarView: UIView, UITextFieldDelegate {
    enum Status: Equatable {
        case idle
        case searching
        case empty
        case failed(String)
        case hits(current: Int, total: Int)
    }

    var onSearch: ((String) -> Void)?
    var onClose: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?

    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    private let field = UITextField()
    private let countLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let previousButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private let hairline = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        setup()
        applyTheme()
        configure(status: .idle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var query: String {
        field.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func focusField() {
        field.becomeFirstResponder()
    }

    func configure(status: Status) {
        spinner.stopAnimating()
        previousButton.isEnabled = false
        nextButton.isEnabled = false
        countLabel.textColor = .secondaryLabel

        switch status {
        case .idle:
            countLabel.text = nil
        case .searching:
            countLabel.text = nil
            spinner.startAnimating()
        case .empty:
            countLabel.text = String(localized: "topic.search.empty", defaultValue: "没有找到匹配内容")
        case .failed(let message):
            countLabel.text = message
            countLabel.textColor = .systemRed
        case .hits(let current, let total):
            countLabel.text = "\(current)/\(total)"
            previousButton.isEnabled = total > 0
            nextButton.isEnabled = total > 0
        }
    }

    private func setup() {
        clipsToBounds = true

        blurView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blurView)

        field.translatesAutoresizingMaskIntoConstraints = false
        field.placeholder = String(localized: "topic.search.placeholder", defaultValue: "输入关键词")
        field.returnKeyType = .search
        field.clearButtonMode = .whileEditing
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.borderStyle = .none
        field.delegate = self
        field.accessibilityLabel = String(localized: "topic.find", defaultValue: "帖内查找")

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = .preferredFont(forTextStyle: .footnote)
        countLabel.textAlignment = .right
        countLabel.lineBreakMode = .byTruncatingTail
        countLabel.adjustsFontSizeToFitWidth = true
        countLabel.minimumScaleFactor = 0.75
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        countLabel.setContentHuggingPriority(.required, for: .horizontal)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true

        configureChromeButton(
            previousButton,
            symbolName: "chevron.up",
            action: #selector(previousTapped),
            label: String(localized: "topic.find.previous", defaultValue: "上一条")
        )
        configureChromeButton(
            nextButton,
            symbolName: "chevron.down",
            action: #selector(nextTapped),
            label: String(localized: "topic.find.next", defaultValue: "下一条")
        )
        configureChromeButton(
            closeButton,
            symbolName: "xmark",
            action: #selector(closeTapped),
            label: String(localized: "topic.find.close", defaultValue: "关闭查找")
        )

        let navStack = UIStackView(arrangedSubviews: [previousButton, nextButton, closeButton])
        navStack.axis = .horizontal
        navStack.spacing = 2
        navStack.translatesAutoresizingMaskIntoConstraints = false

        hairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hairline)
        addSubview(field)
        addSubview(countLabel)
        addSubview(spinner)
        addSubview(navStack)

        NSLayoutConstraint.activate([
            blurView.topAnchor.constraint(equalTo: topAnchor),
            blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
            blurView.bottomAnchor.constraint(equalTo: bottomAnchor),

            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.trailingAnchor.constraint(equalTo: countLabel.leadingAnchor, constant: -8),

            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: spinner.leadingAnchor, constant: -6),
            countLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 180),

            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: navStack.leadingAnchor, constant: -4),
            spinner.widthAnchor.constraint(equalToConstant: 20),

            navStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            navStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),

            previousButton.widthAnchor.constraint(equalToConstant: 36),
            previousButton.heightAnchor.constraint(equalToConstant: 36),
            nextButton.widthAnchor.constraint(equalToConstant: 36),
            nextButton.heightAnchor.constraint(equalToConstant: 36),
            closeButton.widthAnchor.constraint(equalToConstant: 36),
            closeButton.heightAnchor.constraint(equalToConstant: 36),

            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),
        ])
    }

    private func configureChromeButton(
        _ button: UIButton,
        symbolName: String,
        action: Selector,
        label: String
    ) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(UIImage(systemName: symbolName), for: .normal)
        button.accessibilityLabel = label
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    func applyTheme() {
        let accent = AppSettings.shared.themeStyle.accentColor
        field.font = AppSettings.shared.appInterfaceFont(
            ofSize: 16,
            weight: .regular,
            fallback: .systemFont(ofSize: 16)
        )
        field.textColor = .label
        field.tintColor = accent
        previousButton.tintColor = accent
        nextButton.tintColor = accent
        closeButton.tintColor = .secondaryLabel
        hairline.backgroundColor = UIColor.separator.withAlphaComponent(0.45)
        backgroundColor = .clear
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let term = query
        guard !term.isEmpty else { return true }
        textField.resignFirstResponder()
        onSearch?(term)
        return true
    }

    @objc private func previousTapped() {
        onPrevious?()
    }

    @objc private func nextTapped() {
        onNext?()
    }

    @objc private func closeTapped() {
        field.resignFirstResponder()
        onClose?()
    }
}

@MainActor
final class TopicFindBarController {
    let bar = TopicFindBarView()
    private(set) var isVisible = false
    private var hits: [TopicFindHit] = []
    private var index = 0
    private var searchTask: Task<Void, Never>?
    private var heightConstraint: NSLayoutConstraint?
    private var searchProvider: ((String) async throws -> [TopicFindHit])?
    var onJump: ((TopicFindHit) -> Void)?
    var onVisibilityChange: ((Bool) -> Void)?

    init() {
        bar.isHidden = true
        bar.clipsToBounds = true
        bar.onClose = { [weak self] in
            self?.hide()
        }
        bar.onPrevious = { [weak self] in
            self?.step(delta: -1)
        }
        bar.onNext = { [weak self] in
            self?.step(delta: 1)
        }
        bar.onSearch = { [weak self] query in
            self?.search(query: query)
        }
    }

    func install(
        in hostView: UIView,
        topAnchor: NSLayoutYAxisAnchor,
        onJump: @escaping (TopicFindHit) -> Void,
        search: @escaping (String) async throws -> [TopicFindHit]
    ) {
        self.onJump = onJump
        self.searchProvider = search
        hostView.addSubview(bar)
        let height = bar.heightAnchor.constraint(equalToConstant: 0)
        heightConstraint = height
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            height,
        ])
    }

    func show() {
        isVisible = true
        bar.isHidden = false
        heightConstraint?.constant = 48
        bar.applyTheme()
        if hits.isEmpty {
            bar.configure(status: .idle)
        } else {
            bar.configure(status: .hits(current: index + 1, total: hits.count))
        }
        onVisibilityChange?(true)
        bar.focusField()
    }

    func hide() {
        isVisible = false
        searchTask?.cancel()
        searchTask = nil
        hits = []
        index = 0
        bar.configure(status: .idle)
        heightConstraint?.constant = 0
        bar.isHidden = true
        onVisibilityChange?(false)
    }

    func search(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        guard !trimmed.isEmpty else {
            hits = []
            index = 0
            bar.configure(status: .idle)
            return
        }
        guard let searchProvider else { return }
        bar.configure(status: .searching)
        searchTask = Task { [weak self] in
            do {
                let results = try await searchProvider(trimmed)
                guard !Task.isCancelled, let self else { return }
                self.hits = results
                if results.isEmpty {
                    self.index = 0
                    self.bar.configure(status: .empty)
                    return
                }
                self.index = 0
                self.bar.configure(status: .hits(current: 1, total: results.count))
                self.onJump?(results[0])
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.hits = []
                self.index = 0
                self.bar.configure(status: .failed(error.localizedDescription))
            }
        }
    }

    private func step(delta: Int) {
        guard let next = delta >= 0
            ? TopicFindNavigation.nextIndex(current: index, count: hits.count)
            : TopicFindNavigation.previousIndex(current: index, count: hits.count)
        else { return }
        index = next
        bar.configure(status: .hits(current: index + 1, total: hits.count))
        onJump?(hits[index])
    }
}
