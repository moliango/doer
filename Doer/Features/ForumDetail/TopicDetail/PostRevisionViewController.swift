import UIKit
import WebKit

/// Post edit history: browse revisions and inspect the body diff.
///
/// Discourse returns `body_changes` in three shapes — `side_by_side` (HTML), `inline`
/// (HTML) and `side_by_side_markdown` (raw markdown with `<ins>`/`<del>` marks) — so the
/// screen exposes them as a segmented control over a single diff pane, mirrored after the
/// official site's revision modal.
final class PostRevisionViewController: UIViewController {
    private let api: DiscourseAPI
    private let postId: Int

    private var revision: DiscoursePostRevision?
    private var currentMode: DiffMode = .sideBySide
    private var isLoading = false

    private let metaLabel = UILabel()
    private let modeControl = UISegmentedControl(items: DiffMode.allCases.map(\.title))
    private let webView = WKWebView(frame: .zero)
    private let loading = UIActivityIndicatorView(style: .medium)
    private let pagerBar = UIView()
    private let firstButton = UIButton(type: .system)
    private let previousButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let lastButton = UIButton(type: .system)
    private let counterLabel = UILabel()

    private enum DiffMode: Int, CaseIterable {
        case sideBySide
        case inlineDiff
        case raw

        var title: String {
            switch self {
            case .sideBySide: return String(localized: "revision.mode.side_by_side", defaultValue: "并排")
            case .inlineDiff: return String(localized: "revision.mode.inline", defaultValue: "内联")
            case .raw: return String(localized: "revision.mode.raw", defaultValue: "原始")
            }
        }
    }

    private static let diffCSS = """
    ins { background: rgba(46, 160, 67, 0.24); text-decoration: none; }
    del { background: rgba(248, 81, 73, 0.24); text-decoration: none; }
    table { width: 100%; border-collapse: collapse; table-layout: fixed; }
    table td { vertical-align: top; padding: 6px 8px; border: 1px solid rgba(128,128,128,0.28); }
    pre.revision-raw {
        white-space: pre-wrap;
        word-break: break-word;
        font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
        font-size: 12px;
        line-height: 1.45;
    }
    """

    init(api: DiscourseAPI, postId: Int) {
        self.api = api
        self.postId = postId
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "revision.title", defaultValue: "编辑历史")
        view.backgroundColor = AppSettings.shared.themeStyle.contentBackgroundColor
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "common.done", defaultValue: "完成"),
            style: .done,
            target: self,
            action: #selector(close)
        )
        setupUI()
        load(revision: nil)
    }

    // MARK: - UI

    private func setupUI() {
        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.font = .preferredFont(forTextStyle: .footnote)
        metaLabel.textColor = .secondaryLabel
        metaLabel.numberOfLines = 0

        modeControl.translatesAutoresizingMaskIntoConstraints = false
        modeControl.selectedSegmentIndex = currentMode.rawValue
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear

        loading.translatesAutoresizingMaskIntoConstraints = false
        loading.hidesWhenStopped = true

        setupPagerBar()

        view.addSubview(metaLabel)
        view.addSubview(modeControl)
        view.addSubview(webView)
        view.addSubview(pagerBar)
        view.addSubview(loading)

        NSLayoutConstraint.activate([
            metaLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            metaLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            metaLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            modeControl.topAnchor.constraint(equalTo: metaLabel.bottomAnchor, constant: 10),
            modeControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            modeControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            webView.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 10),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: pagerBar.topAnchor),

            pagerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pagerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pagerBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            pagerBar.heightAnchor.constraint(equalToConstant: 52),

            loading.centerXAnchor.constraint(equalTo: webView.centerXAnchor),
            loading.centerYAnchor.constraint(equalTo: webView.centerYAnchor),
        ])
    }

    private func setupPagerBar() {
        pagerBar.translatesAutoresizingMaskIntoConstraints = false
        pagerBar.backgroundColor = AppSettings.shared.themeStyle.contentBackgroundColor

        let hairline = UIView()
        hairline.translatesAutoresizingMaskIntoConstraints = false
        hairline.backgroundColor = UIColor.separator

        let buttons: [(UIButton, String)] = [
            (firstButton, "backward.end.fill"),
            (previousButton, "chevron.left"),
            (nextButton, "chevron.right"),
            (lastButton, "forward.end.fill"),
        ]
        for (button, symbol) in buttons {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setImage(
                UIImage(
                    systemName: symbol,
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
                ),
                for: .normal
            )
            button.tintColor = AppSettings.shared.themeStyle.accentColor
            button.widthAnchor.constraint(equalToConstant: 44).isActive = true
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        }
        firstButton.addAction(UIAction { [weak self] _ in self?.goToFirst() }, for: .touchUpInside)
        previousButton.addAction(UIAction { [weak self] _ in self?.goToPrevious() }, for: .touchUpInside)
        nextButton.addAction(UIAction { [weak self] _ in self?.goToNext() }, for: .touchUpInside)
        lastButton.addAction(UIAction { [weak self] _ in self?.goToLast() }, for: .touchUpInside)
        firstButton.accessibilityLabel = String(localized: "revision.first", defaultValue: "最早版本")
        previousButton.accessibilityLabel = String(localized: "revision.previous", defaultValue: "上一个版本")
        nextButton.accessibilityLabel = String(localized: "revision.next", defaultValue: "下一个版本")
        lastButton.accessibilityLabel = String(localized: "revision.last", defaultValue: "最新版本")

        counterLabel.translatesAutoresizingMaskIntoConstraints = false
        counterLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        counterLabel.textColor = .secondaryLabel
        counterLabel.textAlignment = .center
        counterLabel.setContentHuggingPriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [firstButton, previousButton, counterLabel, nextButton, lastButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.distribution = .equalCentering
        stack.spacing = 8

        pagerBar.addSubview(hairline)
        pagerBar.addSubview(stack)
        NSLayoutConstraint.activate([
            hairline.topAnchor.constraint(equalTo: pagerBar.topAnchor),
            hairline.leadingAnchor.constraint(equalTo: pagerBar.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: pagerBar.trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),

            stack.leadingAnchor.constraint(equalTo: pagerBar.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: pagerBar.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: pagerBar.centerYAnchor),
        ])
    }

    // MARK: - Loading

    @objc private func close() { dismiss(animated: true) }

    @objc private func modeChanged() {
        currentMode = DiffMode(rawValue: modeControl.selectedSegmentIndex) ?? .sideBySide
        renderCurrentMode()
    }

    private func load(revision targetRevision: Int?) {
        guard !isLoading else { return }
        isLoading = true
        loading.startAnimating()
        let target = targetRevision.map(String.init) ?? "latest"
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isLoading = false
                self.loading.stopAnimating()
            }
            do {
                let rev = try await self.api.fetchPostRevision(postId: self.postId, revision: target)
                self.revision = rev
                self.updateChrome()
                self.renderCurrentMode()
            } catch {
                DoerFeedback.presentToast(error.localizedDescription, on: self)
            }
        }
    }

    private func goToFirst() {
        guard let first = revision?.firstRevision else { return }
        load(revision: first)
    }

    private func goToPrevious() {
        guard let previous = revision?.previousRevision else { return }
        load(revision: previous)
    }

    private func goToNext() {
        guard let next = revision?.nextRevision else { return }
        load(revision: next)
    }

    private func goToLast() {
        guard let last = revision?.lastRevision else { return }
        load(revision: last)
    }

    // MARK: - Rendering

    private func updateChrome() {
        guard let revision else { return }
        let username = revision.username.map { "@\($0)" } ?? ""
        let version = revision.currentRevision.map(String.init) ?? "?"
        var parts = [username, "rev \(version)"]
        if let createdAt = revision.createdAt {
            parts.append(UserProfileFormatting.relativeDate(createdAt))
        }
        if revision.previousHidden == true || revision.currentHidden == true {
            parts.append(String(localized: "revision.hidden_marker", defaultValue: "部分内容不可见"))
        }
        metaLabel.text = parts.filter { !$0.isEmpty }.joined(separator: " · ")

        firstButton.isEnabled = revision.previousRevision != nil
        previousButton.isEnabled = revision.previousRevision != nil
        nextButton.isEnabled = revision.nextRevision != nil
        lastButton.isEnabled = revision.nextRevision != nil
        updateCounterLabel()
    }

    private func updateCounterLabel() {
        guard let revision else {
            counterLabel.text = nil
            return
        }
        let total = revision.versionCount ?? revision.currentRevision ?? 1
        let current = revision.currentRevision ?? total
        if let previous = revision.previousRevision {
            counterLabel.text = String(
                format: String(localized: "revision.counter", defaultValue: "%1$lld ↔ %2$lld / %3$lld"),
                Int64(previous),
                Int64(current),
                Int64(total)
            )
        } else {
            counterLabel.text = String(
                format: String(localized: "revision.counter.single", defaultValue: "%1$lld / %2$lld"),
                Int64(current),
                Int64(total)
            )
        }
    }

    private func renderCurrentMode() {
        guard let payload = diffPayload(for: currentMode) else {
            loadDocument(cooked: "<p>\(String(localized: "revision.no_diff", defaultValue: "没有可显示的差异"))</p>")
            return
        }
        let cooked = payload.isRaw ? "<pre class=\"revision-raw\">\(payload.html)</pre>" : payload.html
        loadDocument(cooked: cooked)
    }

    private func loadDocument(cooked: String) {
        let baseURL = api.baseURL
        let document = PostContentRenderer.buildDocument(
            cooked: cooked,
            baseURL: baseURL,
            extraCSS: Self.diffCSS
        )
        webView.loadHTMLString(document, baseURL: URL(string: baseURL))
    }

    /// Discourse ships three diff shapes; fall back to whichever the server sent so a
    /// missing payload never leaves the pane empty.
    private func diffPayload(for mode: DiffMode) -> (html: String, isRaw: Bool)? {
        guard let changes = revision?.bodyChanges else { return nil }
        let ordered: [(String?, Bool)]
        switch mode {
        case .sideBySide:
            ordered = [(changes.sideBySide, false), (changes.inline, false), (changes.sideBySideMarkdown, true)]
        case .inlineDiff:
            ordered = [(changes.inline, false), (changes.sideBySide, false), (changes.sideBySideMarkdown, true)]
        case .raw:
            ordered = [(changes.sideBySideMarkdown, true), (changes.sideBySide, false), (changes.inline, false)]
        }
        for (html, isRaw) in ordered {
            if let html, !html.isEmpty {
                return (html, isRaw)
            }
        }
        return nil
    }
}
