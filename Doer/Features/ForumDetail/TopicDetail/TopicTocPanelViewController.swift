import CookedHTML
import UIKit

/// Compact DiscoTOC sheet: indented tree, active rail, opens on the current heading.
final class TopicTocPanelViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    var onSelect: ((TocEntry) -> Void)?

    private let items: [(entry: TocEntry, depth: Int)]
    private let activeHeadingId: String?
    private let activeAncestorIds: Set<String>
    private let tableView = UITableView(frame: .zero, style: .plain)

    init(data: TocData, activeHeadingId: String?, activeAncestorIds: Set<String>) {
        self.items = Self.flatten(data.tree)
        self.activeHeadingId = activeHeadingId
        self.activeAncestorIds = activeAncestorIds
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            if #available(iOS 16.0, *) {
                sheet.preferredCornerRadius = 20
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let headerBar = UIView()
        headerBar.translatesAutoresizingMaskIntoConstraints = false

        let icon = UIImageView(image: UIImage(systemName: "list.bullet"))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.tintColor = AppSettings.shared.themeStyle.accentColor
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.text = String(localized: "topic.toc", defaultValue: "目录")

        let countLabel = UILabel()
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = .systemFont(ofSize: 13, weight: .medium)
        countLabel.textColor = .tertiaryLabel
        countLabel.text = "\(items.count)"
        countLabel.setContentHuggingPriority(.required, for: .horizontal)

        headerBar.addSubview(icon)
        headerBar.addSubview(titleLabel)
        headerBar.addSubview(countLabel)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 20),
            icon.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            countLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerBar.trailingAnchor, constant: -20),
            countLabel.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            headerBar.heightAnchor.constraint(equalToConstant: 44),
        ])

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.separatorStyle = .none
        tableView.backgroundColor = .systemBackground
        tableView.rowHeight = 40
        tableView.register(TopicTocRowCell.self, forCellReuseIdentifier: TopicTocRowCell.reuseIdentifier)
        tableView.showsVerticalScrollIndicator = !AppSettings.shared.hideScrollIndicators

        view.addSubview(headerBar)
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            headerBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            headerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            tableView.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let index = items.firstIndex(where: { $0.entry.id == activeHeadingId }) {
            tableView.scrollToRow(at: IndexPath(row: index, section: 0), at: .middle, animated: false)
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: TopicTocRowCell.reuseIdentifier,
            for: indexPath
        ) as? TopicTocRowCell else {
            return UITableViewCell()
        }
        let item = items[indexPath.row]
        cell.configure(
            text: item.entry.text,
            depth: item.depth,
            isActive: item.entry.id == activeHeadingId,
            isAncestorActive: activeAncestorIds.contains(item.entry.id)
        )
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let entry = items[indexPath.row].entry
        dismiss(animated: true) { [weak self] in
            self?.onSelect?(entry)
        }
    }

    private static func flatten(_ tree: [TocEntry]) -> [(entry: TocEntry, depth: Int)] {
        var out: [(entry: TocEntry, depth: Int)] = []
        func walk(_ items: [TocEntry], depth: Int) {
            for item in items {
                out.append((item, depth))
                walk(item.children, depth: depth + 1)
            }
        }
        walk(tree, depth: 0)
        return out
    }
}

private final class TopicTocRowCell: UITableViewCell {
    static let reuseIdentifier = "TopicTocRowCell"

    private let rail = UIView()
    private let titleLabel = UILabel()
    private var leadingConstraint: NSLayoutConstraint?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.tag = 42
        card.layer.cornerRadius = 8
        card.layer.cornerCurve = .continuous

        rail.translatesAutoresizingMaskIntoConstraints = false
        rail.layer.cornerRadius = 1.5
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        titleLabel.numberOfLines = 1

        contentView.addSubview(card)
        card.addSubview(rail)
        card.addSubview(titleLabel)

        let leading = card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14)
        leadingConstraint = leading
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -2),
            leading,
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),

            rail.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            rail.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            rail.widthAnchor.constraint(equalToConstant: 3),
            rail.heightAnchor.constraint(equalToConstant: 16),

            titleLabel.leadingAnchor.constraint(equalTo: rail.trailingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, depth: Int, isActive: Bool, isAncestorActive: Bool) {
        titleLabel.text = text
        leadingConstraint?.constant = 8 + CGFloat(depth) * 12
        let accent = AppSettings.shared.themeStyle.accentColor
        let card = contentView.viewWithTag(42)
        if isActive {
            titleLabel.textColor = accent
            titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
            rail.backgroundColor = accent
            card?.backgroundColor = accent.withAlphaComponent(0.10)
        } else if isAncestorActive {
            titleLabel.textColor = accent.withAlphaComponent(0.75)
            titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
            rail.backgroundColor = .clear
            card?.backgroundColor = .clear
        } else {
            titleLabel.textColor = .secondaryLabel
            titleLabel.font = .systemFont(ofSize: 13, weight: .regular)
            rail.backgroundColor = .clear
            card?.backgroundColor = .clear
        }
    }
}
