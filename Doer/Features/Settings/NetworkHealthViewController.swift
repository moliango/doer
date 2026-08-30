import UIKit

final class NetworkHealthViewController: UIViewController {
    private let snapshot: NetworkHealthSnapshot

    private let scrollView: UIScrollView = {
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        return scroll
    }()

    private let stack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 12
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 18, leading: 18, bottom: 32, trailing: 18)
        return stack
    }()

    init(snapshot: NetworkHealthSnapshot) {
        self.snapshot = snapshot
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "network.health.title", defaultValue: "网络健康")
        view.backgroundColor = DataManagementPalette.screenBackground
        view.addSubview(scrollView)
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])

        let note = UILabel()
        note.numberOfLines = 0
        note.font = .preferredFont(forTextStyle: .footnote)
        note.textColor = .secondaryLabel
        note.text = String(
            localized: "network.health.readonly",
            defaultValue: "只读快照，不会改 Cookie 登录或自动修复通道。"
        )
        stack.addArrangedSubview(note)
        stack.addArrangedSubview(makeRow(title: snapshot.engineTitle, detail: snapshot.engineDetail, symbol: "lock.shield"))
        stack.addArrangedSubview(makeRow(title: snapshot.shieldTitle, detail: snapshot.shieldDetail, symbol: "checkmark.shield"))
        stack.addArrangedSubview(makeRow(title: snapshot.csrfTitle, detail: snapshot.csrfDetail, symbol: "key"))
        stack.addArrangedSubview(makeRow(title: snapshot.concurrencyTitle, detail: snapshot.concurrencyDetail, symbol: "square.stack.3d.up"))
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        enableSettingsInteractiveBackSwipe()
    }

    private func makeRow(title: String, detail: String, symbol: String) -> DataManagementActionRowView {
        let row = DataManagementActionRowView()
        row.configure(
            title: title,
            subtitle: detail,
            symbolName: symbol,
            tintColor: AppSettings.shared.themeStyle.accentColor,
            backgroundColor: AppSettings.shared.themeStyle.topicCardBackgroundColor
        )
        row.isUserInteractionEnabled = false
        return row
    }
}
