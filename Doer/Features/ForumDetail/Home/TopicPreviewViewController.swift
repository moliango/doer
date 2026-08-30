import CookedHTML
import UIKit

/// FluxDo-style topic long-press preview: title, author, excerpt / first-post body, stats.
final class TopicPreviewViewController: UIViewController {
    private let api: DiscourseAPI
    private let topic: DiscourseTopicList.Topic
    private let categoryName: String?

    private let scrollView: UIScrollView = {
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        return scroll
    }()

    private let stack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 18, weight: .semibold)
        label.numberOfLines = 3
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let metaLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabel
        label.numberOfLines = 2
        return label
    }()

    private let bodyLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 15)
        label.textColor = .label
        label.numberOfLines = 12
        return label
    }()

    private let spinner: UIActivityIndicatorView = {
        let view = UIActivityIndicatorView(style: .medium)
        view.hidesWhenStopped = true
        return view
    }()

    private let statsLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 12)
        label.textColor = .tertiaryLabel
        return label
    }()

    init(api: DiscourseAPI, topic: DiscourseTopicList.Topic, categoryName: String?) {
        self.api = api
        self.topic = topic
        self.categoryName = categoryName
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = CGSize(width: 320, height: 380)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let theme = AppSettings.shared.themeStyle
        view.backgroundColor = theme.topicCardBackgroundColor
        view.layer.cornerRadius = 16
        view.layer.cornerCurve = .continuous
        view.clipsToBounds = true

        view.addSubview(scrollView)
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -16),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -32),
        ])

        TitleEmojiRenderer.apply(
            TitleEmojiRenderer.plainTitle(fancyTitle: topic.fancyTitle, title: topic.title),
            to: titleLabel,
            font: titleLabel.font ?? .systemFont(ofSize: 18, weight: .semibold),
            textColor: .label,
            baseURL: api.baseURL
        )
        var metaParts: [String] = []
        if let categoryName, !categoryName.isEmpty { metaParts.append(categoryName) }
        if let tags = topic.tags, !tags.isEmpty {
            metaParts.append(tags.prefix(3).map { "#\($0)" }.joined(separator: " "))
        }
        metaParts.append(TopicCell.formatDate(topic.createdAt))
        metaLabel.text = metaParts.joined(separator: " · ")

        let excerpt = strippedExcerpt(topic.excerpt)
        bodyLabel.text = excerpt.isEmpty
            ? String(localized: "topic.preview.loading", defaultValue: "加载预览…")
            : excerpt

        let replies = max(topic.postsCount - 1, 0)
        statsLabel.text = String(
            format: String(localized: "topic.preview.stats", defaultValue: "%d 回复 · %d 浏览"),
            replies,
            topic.views
        )

        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(metaLabel)
        stack.addArrangedSubview(bodyLabel)
        stack.addArrangedSubview(spinner)
        stack.addArrangedSubview(statsLabel)

        Task { await loadFirstPost() }
    }

    private func loadFirstPost() async {
        spinner.startAnimating()
        do {
            let cooked = try await api.fetchTopicFirstPostCooked(id: topic.id)
            let plain = CookedTextExporter.plainText(fromHTML: cooked ?? "", baseURL: api.baseURL)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            await MainActor.run {
                spinner.stopAnimating()
                if !plain.isEmpty {
                    bodyLabel.text = plain
                } else if (bodyLabel.text ?? "").isEmpty {
                    bodyLabel.text = String(localized: "topic.preview.empty", defaultValue: "暂无预览内容")
                }
            }
        } catch {
            await MainActor.run {
                spinner.stopAnimating()
                if strippedExcerpt(topic.excerpt).isEmpty {
                    bodyLabel.text = String(localized: "topic.preview.empty", defaultValue: "暂无预览内容")
                }
            }
        }
    }

    private func strippedExcerpt(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        return raw
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&hellip;", with: "…")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

protocol TopicPreviewTargetProviding: AnyObject {
    var topicPreviewTargetView: UIView { get }
}

/// Xiaohongshu dual-card hit-test: left/right by mid-X, and row identifier → unpinned pair.
enum XiaohongshuPreviewSelection {
    enum Side: Equatable {
        case left
        case right
    }

    static func side(at point: CGPoint, in bounds: CGRect) -> Side? {
        guard bounds.width > 0 else { return nil }
        if point.x < bounds.minX || point.x > bounds.maxX { return nil }
        return point.x < bounds.midX ? .left : .right
    }

    static func unpinnedTopicIndex(rowIndex: Int, side: Side) -> Int {
        rowIndex * 2 + (side == .right ? 1 : 0)
    }

    static func topic<T>(
        in unpinnedTopics: [T],
        rowIdentifier: Int,
        side: Side
    ) -> T? {
        guard let rowIndex = XiaohongshuHomeTopicListLayout.rowIndex(from: rowIdentifier) else {
            return nil
        }
        let index = unpinnedTopicIndex(rowIndex: rowIndex, side: side)
        guard unpinnedTopics.indices.contains(index) else { return nil }
        return unpinnedTopics[index]
    }
}

enum TopicPreviewMenu {
    private static let previewTargets = NSMapTable<UIContextMenuConfiguration, UIView>(
        keyOptions: [.weakMemory, .objectPointerPersonality],
        valueOptions: .weakMemory
    )

    static func configuration(
        topic: DiscourseTopicList.Topic,
        api: DiscourseAPI,
        categoryName: String?,
        actions: [UIMenuElement],
        previewTargetView: UIView? = nil
    ) -> UIContextMenuConfiguration {
        let configuration = UIContextMenuConfiguration(
            identifier: NSNumber(value: topic.id),
            previewProvider: {
                TopicPreviewViewController(api: api, topic: topic, categoryName: categoryName)
            },
            actionProvider: { _ in
                UIMenu(children: actions)
            }
        )
        if let previewTargetView {
            previewTargets.setObject(previewTargetView, forKey: configuration)
        }
        return configuration
    }

    static func targetView(in cell: UITableViewCell) -> UIView {
        if let providing = cell as? TopicPreviewTargetProviding {
            return providing.topicPreviewTargetView
        }
        return cell.contentView
    }

    static func targetedPreview(for configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        guard let view = previewTargets.object(forKey: configuration) else { return nil }
        return makeTargetedPreview(for: view)
    }

    static func makeTargetedPreview(for view: UIView) -> UITargetedPreview {
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        let radius = view.layer.cornerRadius
        if radius > 0, !view.bounds.isEmpty {
            parameters.visiblePath = UIBezierPath(roundedRect: view.bounds, cornerRadius: radius)
        }
        return UITargetedPreview(view: view, parameters: parameters)
    }

    /// Grow the preview into the pushed topic. Reduce Motion keeps the system default.
    static func applyCommitPopIfAllowed(to animator: UIContextMenuInteractionCommitAnimating) {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        animator.preferredCommitStyle = .pop
    }
}
