import UIKit

extension HomeViewController {
    var usesSplitDetail: Bool {
        traitCollection.horizontalSizeClass == .regular && traitCollection.userInterfaceIdiom == .pad
    }

    func setupSplitDetailIfNeeded() {
        if splitDetailContainer == nil {
            let container = UIView()
            container.translatesAutoresizingMaskIntoConstraints = false
            container.isHidden = true
            view.addSubview(container)
            splitDetailContainer = container
            splitDetailLeadingConstraint = container.leadingAnchor.constraint(
                equalTo: tableView.trailingAnchor
            )
            NSLayoutConstraint.activate([
                container.topAnchor.constraint(equalTo: view.topAnchor),
                container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                container.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.58),
            ])
            splitDetailLeadingConstraint?.isActive = false
            showSplitPlaceholder()
        }
        applySplitLayout()
    }

    func applySplitLayout() {
        guard let container = splitDetailContainer else { return }
        let split = usesSplitDetail
        container.isHidden = !split
        tableTrailingToSuperviewConstraint?.isActive = !split
        splitDetailLeadingConstraint?.isActive = split
        if split {
            if splitDetailNavigation == nil {
                showSplitPlaceholder()
            }
        } else if let detail = splitDetailNavigation?.viewControllers.last,
                  !(detail is SplitTopicPlaceholderViewController) {
            let hosted = detail
            splitDetailNavigation?.setViewControllers([SplitTopicPlaceholderViewController()], animated: false)
            if navigationController?.topViewController === self {
                navigationController?.pushViewController(hosted, animated: false)
            }
        }
        view.layoutIfNeeded()
    }

    func showTopicInSplit(_ viewController: UIViewController) {
        let navigation = splitDetailNavigation ?? UINavigationController()
        if splitDetailNavigation == nil {
            splitDetailNavigation = navigation
            addChild(navigation)
            splitDetailContainer?.addSubview(navigation.view)
            navigation.view.translatesAutoresizingMaskIntoConstraints = false
            if let container = splitDetailContainer {
                NSLayoutConstraint.activate([
                    navigation.view.topAnchor.constraint(equalTo: container.topAnchor),
                    navigation.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    navigation.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                    navigation.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                ])
            }
            navigation.didMove(toParent: self)
        }
        navigation.setViewControllers([viewController], animated: false)
    }

    func showSplitPlaceholder() {
        showTopicInSplit(SplitTopicPlaceholderViewController())
    }
}

final class SplitTopicPlaceholderViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AppSettings.shared.themeStyle.topicListBackgroundColor
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = String(localized: "home.split.placeholder", defaultValue: "选择一个话题")
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .title3)
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}
