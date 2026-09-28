import UIKit

/// Native author / flag / delete popover shown when a Boost chip is tapped.
/// Behavior from FluxDo `boost_author_popover`; UI is UIKit card chrome.
final class BoostAuthorPopoverViewController: UIViewController {
    enum Action {
        case profile(String)
        case flag(DiscourseTopicDetail.Boost)
        case delete(DiscourseTopicDetail.Boost)
    }

    var onAction: ((Action) -> Void)?

    private let boosts: [DiscourseTopicDetail.Boost]
    private let currentUsername: String?
    private let baseURL: String
    private let accent = AppSettings.shared.themeStyle.accentColor

    init(
        boosts: [DiscourseTopicDetail.Boost],
        currentUsername: String?,
        baseURL: String
    ) {
        self.boosts = boosts
        self.currentUsername = currentUsername
        self.baseURL = baseURL
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .popover
        preferredContentSize = CGSize(width: 260, height: 120)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemGroupedBackground
        if boosts.count == 1 {
            layoutSingle(boosts[0])
        } else {
            layoutGroup()
        }
    }

    private func layoutSingle(_ boost: DiscourseTopicDetail.Boost) {
        let card = makeAuthorCard(boost: boost, showsActions: true)
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: view.topAnchor),
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        preferredContentSize = CGSize(width: 260, height: card.systemLayoutSizeFitting(
            CGSize(width: 260, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height)
    }

    private func layoutGroup() {
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        view.addSubview(scroll)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])

        for (index, boost) in boosts.enumerated() {
            stack.addArrangedSubview(makeAuthorCard(boost: boost, showsActions: true))
            if index < boosts.count - 1 {
                let line = UIView()
                line.backgroundColor = UIColor.separator.withAlphaComponent(0.45)
                line.translatesAutoresizingMaskIntoConstraints = false
                line.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale).isActive = true
                stack.addArrangedSubview(line)
            }
        }

        let fitted = stack.systemLayoutSizeFitting(
            CGSize(width: 280, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        preferredContentSize = CGSize(width: 280, height: min(fitted, 360))
    }

    private func makeAuthorCard(boost: DiscourseTopicDetail.Boost, showsActions: Bool) -> UIView {
        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false

        let avatar = UIImageView()
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.contentMode = .scaleAspectFill
        avatar.clipsToBounds = true
        avatar.layer.cornerRadius = 18
        avatar.backgroundColor = .tertiarySystemFill
        AvatarImageLoader.setImage(
            on: avatar,
            url: AvatarImageLoader.url(from: boost.user.avatarTemplate, baseURL: baseURL, size: AvatarImageLoader.primaryAvatarPixelSize),
            placeholder: UIImage(systemName: "person.crop.circle.fill")
        )

        let displayName = (boost.user.name?.isEmpty == false ? boost.user.name! : boost.user.username)
        let nameLabel = UILabel()
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        nameLabel.textColor = .label
        nameLabel.text = displayName
        nameLabel.numberOfLines = 1

        let handleLabel = UILabel()
        handleLabel.translatesAutoresizingMaskIntoConstraints = false
        handleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        handleLabel.textColor = .secondaryLabel
        handleLabel.text = "@\(boost.user.username)"
        handleLabel.numberOfLines = 1

        let identity = UIControl()
        identity.translatesAutoresizingMaskIntoConstraints = false
        identity.addSubview(avatar)
        identity.addSubview(nameLabel)
        identity.addSubview(handleLabel)
        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: identity.leadingAnchor),
            avatar.topAnchor.constraint(equalTo: identity.topAnchor),
            avatar.bottomAnchor.constraint(lessThanOrEqualTo: identity.bottomAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 36),
            avatar.heightAnchor.constraint(equalToConstant: 36),

            nameLabel.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 10),
            nameLabel.trailingAnchor.constraint(equalTo: identity.trailingAnchor),
            nameLabel.topAnchor.constraint(equalTo: identity.topAnchor),

            handleLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            handleLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            handleLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            handleLabel.bottomAnchor.constraint(equalTo: identity.bottomAnchor),
        ])
        let username = boost.user.username
        if BoostActionPolicy.canViewAuthor(boost: boost) {
            identity.addAction(UIAction { [weak self] _ in
                self?.emit(.profile(username))
            }, for: .touchUpInside)
        }

        let stack = UIStackView(arrangedSubviews: [identity])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
        ])

        guard showsActions else { return card }

        let actions = UIStackView()
        actions.axis = .horizontal
        actions.spacing = 6
        actions.distribution = .fillEqually
        actions.translatesAutoresizingMaskIntoConstraints = false

        if BoostActionPolicy.canViewAuthor(boost: boost) {
            actions.addArrangedSubview(
                makeActionButton(
                    symbol: "person.crop.circle",
                    title: String(localized: "boost.author.profile", defaultValue: "主页"),
                    color: accent
                ) { [weak self] in
                    self?.emit(.profile(username))
                }
            )
        }
        if BoostActionPolicy.canFlag(boost: boost, currentUsername: currentUsername) {
            actions.addArrangedSubview(makeFlagButton(for: boost))
        }
        if BoostActionPolicy.canDelete(boost: boost, currentUsername: currentUsername) {
            actions.addArrangedSubview(
                makeActionButton(
                    symbol: "trash",
                    title: String(localized: "common.delete", defaultValue: "删除"),
                    color: .systemRed
                ) { [weak self] in
                    self?.emit(.delete(boost))
                }
            )
        }

        if !actions.arrangedSubviews.isEmpty {
            let divider = UIView()
            divider.backgroundColor = UIColor.separator.withAlphaComponent(0.45)
            divider.translatesAutoresizingMaskIntoConstraints = false
            divider.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale).isActive = true
            stack.addArrangedSubview(divider)
            stack.addArrangedSubview(actions)
        }
        return card
    }

    /// Compact red flag control matching Discourse / FluxDo boost tap affordance.
    private func makeFlagButton(for boost: DiscourseTopicDetail.Boost) -> UIControl {
        let control = UIControl()
        control.translatesAutoresizingMaskIntoConstraints = false
        control.accessibilityLabel = String(localized: "boost.flag", defaultValue: "举报")
        control.backgroundColor = UIColor.systemRed.withAlphaComponent(0.12)
        control.layer.cornerRadius = 10
        control.layer.cornerCurve = .continuous

        let icon = UIImageView(
            image: UIImage(systemName: "flag.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        )
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.tintColor = .systemRed
        icon.isUserInteractionEnabled = false

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = String(localized: "boost.flag", defaultValue: "举报")
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .systemRed
        label.isUserInteractionEnabled = false

        let row = UIStackView(arrangedSubviews: [icon, label])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 4
        row.isUserInteractionEnabled = false
        control.addSubview(row)
        NSLayoutConstraint.activate([
            control.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
            row.centerXAnchor.constraint(equalTo: control.centerXAnchor),
            row.centerYAnchor.constraint(equalTo: control.centerYAnchor),
            row.leadingAnchor.constraint(greaterThanOrEqualTo: control.leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(lessThanOrEqualTo: control.trailingAnchor, constant: -6),
        ])
        control.addAction(UIAction { [weak self] _ in
            self?.emit(.flag(boost))
        }, for: .touchUpInside)
        return control
    }

    private func makeActionButton(
        symbol: String,
        title: String,
        color: UIColor,
        handler: @escaping () -> Void
    ) -> UIControl {
        let control = UIControl()
        control.translatesAutoresizingMaskIntoConstraints = false
        control.layer.cornerRadius = 10
        control.layer.cornerCurve = .continuous
        control.backgroundColor = UIColor.tertiarySystemFill.withAlphaComponent(0.5)

        let icon = UIImageView(
            image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        )
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.tintColor = color
        icon.isUserInteractionEnabled = false

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = title
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = color
        label.isUserInteractionEnabled = false

        let row = UIStackView(arrangedSubviews: [icon, label])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 4
        row.isUserInteractionEnabled = false
        control.addSubview(row)
        NSLayoutConstraint.activate([
            control.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
            row.centerXAnchor.constraint(equalTo: control.centerXAnchor),
            row.centerYAnchor.constraint(equalTo: control.centerYAnchor),
        ])
        control.addAction(UIAction { _ in handler() }, for: .touchUpInside)
        return control
    }

    private func emit(_ action: Action) {
        dismiss(animated: true) { [weak self] in
            self?.onAction?(action)
        }
    }
}

extension BoostAuthorPopoverViewController: UIPopoverPresentationControllerDelegate {
    func adaptivePresentationStyle(
        for controller: UIPresentationController,
        traitCollection: UITraitCollection
    ) -> UIModalPresentationStyle {
        .none
    }
}

/// Native Boost flag form (FluxDo `BoostFlagSheet` behavior, UIKit card).
final class BoostFlagSheetViewController: UIViewController, UITextViewDelegate {
    var onSubmit: ((Int, String?) async throws -> Void)?
    var onFinished: (() -> Void)?

    private let boost: DiscourseTopicDetail.Boost
    private let flagTypes: [DiscourseFlagType]
    private var selectedType: DiscourseFlagType?
    private var isSubmitting = false
    private let accent = AppSettings.shared.themeStyle.accentColor

    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private let messageView = UITextView()
    private let submitButton = UIButton(type: .system)

    init(boost: DiscourseTopicDetail.Boost, flagTypes: [DiscourseFlagType]) {
        self.boost = boost
        self.flagTypes = flagTypes
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        title = String(localized: "boost.flag.title", defaultValue: "举报 Boost")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        if let sheet = sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 16
        }

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: String(localized: "common.cancel", defaultValue: "取消"),
            style: .plain,
            target: self,
            action: #selector(cancelTapped)
        )

        table.translatesAutoresizingMaskIntoConstraints = false
        table.dataSource = self
        table.delegate = self
        table.register(UITableViewCell.self, forCellReuseIdentifier: "flag")
        table.backgroundColor = .systemGroupedBackground
        view.addSubview(table)

        messageView.translatesAutoresizingMaskIntoConstraints = false
        messageView.font = .systemFont(ofSize: 15)
        messageView.layer.cornerRadius = 12
        messageView.layer.cornerCurve = .continuous
        messageView.backgroundColor = .secondarySystemGroupedBackground
        messageView.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        messageView.delegate = self
        messageView.isHidden = true
        messageView.accessibilityLabel = String(localized: "post.flag.description_hint", defaultValue: "补充说明")
        view.addSubview(messageView)

        var config = UIButton.Configuration.filled()
        config.cornerStyle = .large
        config.baseBackgroundColor = accent
        config.baseForegroundColor = .white
        config.title = String(localized: "post.submit_flag", defaultValue: "提交举报")
        submitButton.configuration = config
        submitButton.translatesAutoresizingMaskIntoConstraints = false
        submitButton.addTarget(self, action: #selector(submitTapped), for: .touchUpInside)
        submitButton.isEnabled = false
        view.addSubview(submitButton)

        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            messageView.topAnchor.constraint(equalTo: table.bottomAnchor, constant: 8),
            messageView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            messageView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            messageView.heightAnchor.constraint(equalToConstant: 88),

            submitButton.topAnchor.constraint(equalTo: messageView.bottomAnchor, constant: 12),
            submitButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            submitButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            submitButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            submitButton.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    func textViewDidChange(_ textView: UITextView) {
        updateSubmitEnabled()
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func submitTapped() {
        guard let selectedType, !isSubmitting else { return }
        let message = messageView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if selectedType.requireMessage && message.isEmpty { return }
        isSubmitting = true
        submitButton.isEnabled = false
        Task {
            do {
                try await onSubmit?(selectedType.id, message.isEmpty ? nil : message)
                dismiss(animated: true) { [weak self] in
                    self?.onFinished?()
                }
            } catch {
                isSubmitting = false
                updateSubmitEnabled()
                let alert = UIAlertController(
                    title: String(localized: "post.action.failed", defaultValue: "操作失败"),
                    message: error.localizedDescription,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
        }
    }

    private func updateSubmitEnabled() {
        let message = messageView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let needsMessage = selectedType?.requireMessage == true
        submitButton.isEnabled = selectedType != nil && !isSubmitting && (!needsMessage || !message.isEmpty)
        messageView.isHidden = !(selectedType?.requireMessage == true)
    }
}

extension BoostFlagSheetViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        flagTypes.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        String(localized: "post.flag.notify_moderators", defaultValue: "通知版主")
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "flag", for: indexPath)
        let type = flagTypes[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = type.name.isEmpty ? type.nameKey : type.name
        content.secondaryText = type.description
            .replacingOccurrences(of: "%{username}", with: boost.user.username)
            .replacingOccurrences(of: "@%{username}", with: "@\(boost.user.username)")
        content.textProperties.font = .systemFont(ofSize: 16, weight: .semibold)
        content.secondaryTextProperties.font = .systemFont(ofSize: 13)
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        cell.accessoryType = selectedType?.id == type.id ? .checkmark : .none
        cell.tintColor = accent
        cell.backgroundColor = .secondarySystemGroupedBackground
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        selectedType = flagTypes[indexPath.row]
        tableView.reloadData()
        updateSubmitEnabled()
    }
}
