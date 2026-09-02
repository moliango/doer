import SDWebImage
import UIKit

final class UserSocialListViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    enum Mode: Equatable {
        case followers
        case following

        var title: String {
            switch self {
            case .followers: return String(localized: "user.profile.followers")
            case .following: return String(localized: "user.profile.following")
            }
        }
    }

    private let api: DiscourseAPI
    private let username: String
    private let mode: Mode
    private var users: [DiscourseFollowUser] = []
    private var isLoading = false
    private var errorMessage: String?

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let stateLabel = UILabel()
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)
    private let refreshControl = UIRefreshControl()

    init(api: DiscourseAPI, username: String, mode: Mode) {
        self.api = api
        self.username = username
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
        title = mode.title
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AppSettings.shared.themeStyle.contentBackgroundColor
        setupUI()
        load()
    }

    private func setupUI() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.refreshControl = refreshControl
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        tableView.register(SocialUserCell.self, forCellReuseIdentifier: SocialUserCell.reuseIdentifier)
        refreshControl.addTarget(self, action: #selector(refreshPulled), for: .valueChanged)

        stateLabel.translatesAutoresizingMaskIntoConstraints = false
        stateLabel.textAlignment = .center
        stateLabel.textColor = .secondaryLabel
        stateLabel.numberOfLines = 0

        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(tableView)
        view.addSubview(stateLabel)
        view.addSubview(loadingIndicator)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stateLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stateLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 30),
            stateLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -30),
            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    private func load() {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        updateState()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                switch mode {
                case .followers:
                    users = try await api.fetchFollowers(username: username)
                case .following:
                    users = try await api.fetchFollowing(username: username)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
            refreshControl.endRefreshing()
            tableView.reloadData()
            prefetchAvatars()
            updateState()
        }
    }

    private func prefetchAvatars() {
        let limit = AppSettings.shared.avatarLoadingProfile.homeAvatarPrefetchLimit
        let urls = users.prefix(limit).compactMap { user in
            AvatarImageLoader.url(
                from: user.avatarTemplate,
                baseURL: api.baseURL,
                size: AvatarImageLoader.primaryAvatarPixelSize
            )
        }
        AvatarImageLoader.prefetch(urls: urls, cloudflareBaseURL: api.baseURL)
    }

    private func updateState() {
        isLoading ? loadingIndicator.startAnimating() : loadingIndicator.stopAnimating()
        tableView.isHidden = users.isEmpty
        stateLabel.isHidden = !users.isEmpty || isLoading
        stateLabel.text = errorMessage ?? String(localized: "search.no_results")
    }

    @objc private func refreshPulled() {
        load()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        users.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: SocialUserCell.reuseIdentifier, for: indexPath)
        guard let socialCell = cell as? SocialUserCell, users.indices.contains(indexPath.row) else {
            return cell
        }
        socialCell.configure(user: users[indexPath.row], baseURL: api.baseURL)
        return socialCell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard users.indices.contains(indexPath.row) else { return }
        let user = users[indexPath.row]
        navigationController?.pushViewController(
            UserProfileViewController(api: api, username: user.username),
            animated: true
        )
    }
}

private final class SocialUserCell: UITableViewCell {
    static let reuseIdentifier = "SocialUserCell"

    private enum Metrics {
        static let avatarSize: CGFloat = 40
        static let horizontalInset: CGFloat = 16
        static let verticalInset: CGFloat = 10
        static let textSpacing: CGFloat = 10
    }

    private let avatarView: UIImageView = {
        let view = UIImageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.layer.cornerRadius = Metrics.avatarSize / 2
        view.layer.cornerCurve = .continuous
        return view
    }()

    private let nameLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textColor = .label
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private let handleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.textColor = .secondaryLabel
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private let textStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 2
        return stack
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        accessoryType = .disclosureIndicator
        contentView.addSubview(avatarView)
        textStack.addArrangedSubview(nameLabel)
        textStack.addArrangedSubview(handleLabel)
        contentView.addSubview(textStack)

        NSLayoutConstraint.activate([
            avatarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Metrics.horizontalInset),
            avatarView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: Metrics.avatarSize),
            avatarView.heightAnchor.constraint(equalToConstant: Metrics.avatarSize),
            avatarView.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: Metrics.verticalInset),
            contentView.bottomAnchor.constraint(greaterThanOrEqualTo: avatarView.bottomAnchor, constant: Metrics.verticalInset),

            textStack.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: Metrics.textSpacing),
            textStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            textStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            textStack.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: Metrics.verticalInset),
            contentView.bottomAnchor.constraint(greaterThanOrEqualTo: textStack.bottomAnchor, constant: Metrics.verticalInset),
        ])
        separatorInset = UIEdgeInsets(top: 0, left: Metrics.horizontalInset + Metrics.avatarSize + Metrics.textSpacing, bottom: 0, right: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        avatarView.sd_cancelCurrentImageLoad()
        avatarView.image = nil
        nameLabel.text = nil
        handleLabel.text = nil
    }

    func configure(user: DiscourseFollowUser, baseURL: String) {
        let trimmedName = user.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        nameLabel.text = trimmedName.isEmpty ? user.username : trimmedName
        handleLabel.text = "@\(user.username)"
        avatarView.backgroundColor = AppSettings.shared.themeStyle.topicChipBackgroundColor
        // Same pixel size as home / bookmarks so URL and user-id caches are shared.
        AvatarImageLoader.setImage(
            on: avatarView,
            template: user.avatarTemplate,
            baseURL: baseURL,
            userId: user.id,
            size: AvatarImageLoader.primaryAvatarPixelSize
        )
    }
}
