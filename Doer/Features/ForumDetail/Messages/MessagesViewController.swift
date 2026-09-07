import UIKit

final class MessagesViewController: ObservableViewController {
    private let api: DiscourseAPI
    private let viewModel: MessagesViewModel
    private weak var authGate: AuthGating?

    private let segmentedControl: UISegmentedControl = {
        let control = UISegmentedControl(items: PrivateMessageFilter.allCases.map(\.title))
        control.selectedSegmentIndex = PrivateMessageFilter.inbox.rawValue
        control.translatesAutoresizingMaskIntoConstraints = false
        return control
    }()

    private lazy var tableView: UITableView = {
        let table = UITableView(frame: .zero, style: .plain)
        table.translatesAutoresizingMaskIntoConstraints = false
        table.backgroundColor = .systemGroupedBackground
        table.separatorStyle = .none
        table.showsVerticalScrollIndicator = false
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = TopicCell.estimatedHeight
        table.register(TopicCell.self, forCellReuseIdentifier: TopicCell.reuseIdentifier)
        table.dataSource = self
        table.delegate = self
        return table
    }()

    private let stateStackView: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private let stateIconView: UIImageView = {
        let imageView = UIImageView(image: UIImage(systemName: "envelope.fill"))
        imageView.tintColor = .tertiaryLabel
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        return imageView
    }()

    private let stateLabel: UILabel = {
        let label = UILabel()
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.font = .systemFont(ofSize: 15)
        return label
    }()

    private let stateButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.cornerStyle = .medium
        let button = UIButton(configuration: config)
        button.isHidden = true
        return button
    }()

    private let loadingIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.hidesWhenStopped = true
        indicator.translatesAutoresizingMaskIntoConstraints = false
        return indicator
    }()

    private lazy var refreshControl: UIRefreshControl = {
        let control = UIRefreshControl()
        control.addTarget(self, action: #selector(refreshPulled), for: .valueChanged)
        return control
    }()

    init(api: DiscourseAPI, authGate: AuthGating? = nil) {
        self.api = api
        self.viewModel = MessagesViewModel(api: api)
        self.authGate = authGate
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observe(viewModel)
        title = String(localized: "messages.title")
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "square.and.pencil"),
            style: .plain,
            target: self,
            action: #selector(composeTapped)
        )
        navigationItem.rightBarButtonItem?.accessibilityLabel = String(
            localized: "messages.compose",
            defaultValue: "新建私信"
        )

        setupUI()
        loadMessages()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if authGate?.isAuthenticated() == true {
            loadMessages()
        }
    }

    @objc private func composeTapped() {
        let presentComposer = { [weak self] in
            guard let self else { return }
            let composer = PrivateMessageComposerViewController(api: self.api, recipient: "")
            composer.onMessageSent = { [weak self] _ in
                self?.loadMessages()
            }
            self.present(UINavigationController(rootViewController: composer), animated: true)
        }
        if authGate?.isAuthenticated() == true {
            presentComposer()
        } else {
            authGate?.requireAuth(then: presentComposer)
        }
    }

    override func updateUI() {
        segmentedControl.selectedSegmentIndex = viewModel.selectedFilter.rawValue

        if viewModel.isLoading && viewModel.messages.isEmpty {
            loadingIndicator.startAnimating()
        } else {
            loadingIndicator.stopAnimating()
        }
        refreshControl.endRefreshing()

        tableView.reloadData()
        updateState()
    }

    private func setupUI() {
        tableView.refreshControl = refreshControl
        segmentedControl.addTarget(self, action: #selector(filterChanged), for: .valueChanged)
        stateButton.addTarget(self, action: #selector(stateButtonTapped), for: .touchUpInside)

        stateStackView.addArrangedSubview(stateIconView)
        stateStackView.addArrangedSubview(stateLabel)
        stateStackView.addArrangedSubview(stateButton)

        view.addSubview(segmentedControl)
        view.addSubview(tableView)
        view.addSubview(stateStackView)
        view.addSubview(loadingIndicator)

        NSLayoutConstraint.activate([
            segmentedControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            segmentedControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            segmentedControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            tableView.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: 12),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stateStackView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stateStackView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stateStackView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            stateStackView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),

            stateIconView.widthAnchor.constraint(equalToConstant: 48),
            stateIconView.heightAnchor.constraint(equalToConstant: 48),

            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    private func updateState() {
        let hasMessages = !viewModel.messages.isEmpty
        tableView.isHidden = !hasMessages
        stateStackView.isHidden = hasMessages || viewModel.isLoading

        if viewModel.requiresLogin {
            stateIconView.image = UIImage(systemName: "person.crop.circle.badge.exclamationmark")
            stateLabel.text = viewModel.errorMessage ?? String(localized: "login.required.message")
            stateButton.isHidden = false
            stateButton.configuration?.title = String(localized: "me.login")
            return
        }

        if let error = viewModel.errorMessage {
            stateIconView.image = UIImage(systemName: "exclamationmark.triangle.fill")
            stateLabel.text = error
            stateButton.isHidden = false
            stateButton.configuration?.title = String(localized: "action.retry")
            return
        }

        stateIconView.image = UIImage(systemName: "envelope.open.fill")
        stateLabel.text = String(localized: "messages.empty")
        stateButton.isHidden = true
    }

    private func loadMessages(filter: PrivateMessageFilter? = nil) {
        guard let username = authGate?.currentUsername(), authGate?.isAuthenticated() == true else {
            viewModel.requiresLogin = true
            viewModel.errorMessage = String(localized: "login.required.message")
            updateUI()
            return
        }
        Task {
            await viewModel.loadMessages(username: username, filter: filter)
        }
    }

    @objc private func filterChanged() {
        guard let filter = PrivateMessageFilter(rawValue: segmentedControl.selectedSegmentIndex) else { return }
        loadMessages(filter: filter)
    }

    @objc private func refreshPulled() {
        loadMessages()
    }

    @objc private func stateButtonTapped() {
        if viewModel.requiresLogin {
            authGate?.requireAuth { [weak self] in
                self?.loadMessages()
            }
        } else {
            loadMessages()
        }
    }
}

extension MessagesViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        viewModel.messages.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: TopicCell.reuseIdentifier, for: indexPath) as? TopicCell else {
            return UITableViewCell()
        }
        let topic = viewModel.messages[indexPath.row]
        cell.configure(
            with: topic,
            avatarURL: viewModel.avatarURL(for: topic, baseURL: api.baseURL),
            categoryName: nil,
            categoryColor: nil,
            tags: [String(localized: "messages.private_tag")]
        )
        return cell
    }
}

extension MessagesViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let topic = viewModel.messages[indexPath.row]
        let detail = TopicDetailFactory.make(api: api, topicId: topic.id)
        navigationController?.pushViewController(detail, animated: true)
    }
}
