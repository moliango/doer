import UIKit

final class UserPostsViewController: ObservableViewController {
    private let api: DiscourseAPI
    private let viewModel: UserPostsViewModel

    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .plain)
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.register(SearchResultCell.self, forCellReuseIdentifier: SearchResultCell.reuseIdentifier)
        tv.delegate = self
        tv.dataSource = self
        return tv
    }()

    private let activityIndicator: UIActivityIndicatorView = {
        let ai = UIActivityIndicatorView(style: .medium)
        ai.hidesWhenStopped = true
        ai.translatesAutoresizingMaskIntoConstraints = false
        return ai
    }()

    private let emptyLabel: UILabel = {
        let label = UILabel()
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true
        return label
    }()

    init(api: DiscourseAPI, username: String, filter: UserPostsViewModel.Filter) {
        self.api = api
        self.viewModel = UserPostsViewModel(api: api, username: username, filter: filter)
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true

        switch filter {
        case .topics:
            title = String(localized: "user.topics_title")
            emptyLabel.text = String(localized: "search.no_results")
        case .posts:
            title = String(localized: "user.posts_title")
            emptyLabel.text = String(localized: "search.no_results")
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observe(viewModel)
        view.backgroundColor = .systemBackground

        view.addSubview(tableView)
        view.addSubview(activityIndicator)
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            emptyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])

        Task {
            await viewModel.load()
        }
    }

    override func updateUI() {
        if viewModel.isLoading, viewModel.searchResults.isEmpty {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }

        if !viewModel.isLoading, viewModel.searchResults.isEmpty {
            emptyLabel.isHidden = false
        } else {
            emptyLabel.isHidden = true
        }

        tableView.reloadData()
    }
}

// MARK: - UITableViewDataSource

extension UserPostsViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        viewModel.searchResults.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: SearchResultCell.reuseIdentifier, for: indexPath) as? SearchResultCell else {
            return UITableViewCell()
        }
        let post = viewModel.searchResults[indexPath.row]
        cell.configure(with: post, baseURL: api.baseURL)
        cell.accessoryType = .disclosureIndicator
        return cell
    }
}

// MARK: - UITableViewDelegate

extension UserPostsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let post = viewModel.searchResults[indexPath.row]
        let detailVC = TopicDetailFactory.make(api: api, topicId: post.topicId)
        navigationController?.pushViewController(detailVC, animated: true)
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        let totalRows = tableView.doer_numberOfRows(inSection: 0)
        if indexPath.row >= totalRows - 5 {
            Task {
                await viewModel.loadMore()
            }
        }
    }
}
