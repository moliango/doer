import UIKit

/// Boost detail card. Title, preview, floor, profile, and flag match the official sheet.
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
    private let postUsername: String
    private let postNumber: Int
    private let previewCookedHTML: String
    private let previewPlain: String
    private let accent = AppSettings.shared.themeStyle.accentColor

    init(
        boosts: [DiscourseTopicDetail.Boost],
        currentUsername: String?,
        baseURL: String,
        postUsername: String = "",
        postNumber: Int = 0,
        previewCookedHTML: String = "",
        previewPlain: String = ""
    ) {
        self.boosts = boosts
        self.currentUsername = currentUsername
        self.baseURL = baseURL
        self.postUsername = postUsername
        self.postNumber = postNumber
        self.previewCookedHTML = previewCookedHTML
        self.previewPlain = previewPlain
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        preferredContentSize = CGSize(width: 360, height: 280)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        installGlass()
        let card = makeCard()
        card.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = boosts.count > 1
        scroll.backgroundColor = .clear
        view.addSubview(scroll)
        scroll.addSubview(card)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            card.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8),
            card.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -12),
            card.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])
        let height = card.systemLayoutSizeFitting(
            CGSize(width: view.bounds.width > 1 ? view.bounds.width : 360, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height + 28
        preferredContentSize = CGSize(width: 360, height: min(max(height, 240), 520))
    }

    private func installGlass() {
        let effectView: UIVisualEffectView
        if #available(iOS 26.0, *) {
            effectView = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        } else {
            effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
        }
        effectView.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(effectView, at: 0)
        NSLayoutConstraint.activate([
            effectView.topAnchor.constraint(equalTo: view.topAnchor),
            effectView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            effectView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func makeCard() -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 0
        stack.addArrangedSubview(makeHeader(username: boosts.count == 1 ? boosts[0].user.username : ""))
        for boost in boosts {
            stack.addArrangedSubview(makePersonSection(boost))
        }
        return stack
    }

    private func makePersonSection(_ boost: DiscourseTopicDetail.Boost) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 0
        stack.addArrangedSubview(makePreview(for: boost))
        if BoostActionPolicy.canViewAuthor(boost: boost) {
            stack.addArrangedSubview(makeHairline())
            stack.addArrangedSubview(makeMenuRow(
                symbol: "person",
                title: String(localized: "boost.author.view_profile", defaultValue: "查看主页"),
                tint: .label
            ) { [weak self] in
                self?.emit(.profile(boost.user.username))
            })
        }
        if BoostActionPolicy.canFlag(boost: boost, currentUsername: currentUsername) {
            stack.addArrangedSubview(makeHairline())
            stack.addArrangedSubview(makeMenuRow(
                symbol: "flag.fill",
                title: String(localized: "boost.flag.action", defaultValue: "举报 Boost"),
                tint: .systemRed
            ) { [weak self] in
                self?.emit(.flag(boost))
            })
        } else if BoostActionPolicy.boostAlreadyReported(boost: boost, currentUsername: currentUsername) {
            stack.addArrangedSubview(makeHairline())
            stack.addArrangedSubview(makeMenuRow(
                symbol: "flag.fill",
                title: String(localized: "boost.flag.already_reported", defaultValue: "已举报"),
                tint: .tertiaryLabel,
                enabled: false
            ) {})
        }
        if BoostActionPolicy.canDelete(boost: boost, currentUsername: currentUsername) {
            stack.addArrangedSubview(makeHairline())
            stack.addArrangedSubview(makeMenuRow(
                symbol: "trash",
                title: String(localized: "boost.delete.action", defaultValue: "移除这条 Boost"),
                tint: .systemRed
            ) { [weak self] in
                self?.emit(.delete(boost))
            })
        }
        return stack
    }

    private func makeHeader(username: String) -> UIView {
        let header = UIView()
        header.translatesAutoresizingMaskIntoConstraints = false
        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        let name = username
        title.text = name.isEmpty
            ? String(localized: "post.boost", defaultValue: "Boost")
            : "Boost · \(name)"
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .label
        title.textAlignment = .center

        let close = UIButton(type: .system)
        close.translatesAutoresizingMaskIntoConstraints = false
        close.setImage(
            UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)),
            for: .normal
        )
        close.tintColor = .secondaryLabel
        close.accessibilityLabel = String(localized: "common.close", defaultValue: "关闭")
        close.addAction(UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        }, for: .touchUpInside)
        let plate = UIView()
        plate.translatesAutoresizingMaskIntoConstraints = false
        plate.isUserInteractionEnabled = false
        plate.backgroundColor = UIColor.tertiarySystemFill
        plate.layer.cornerRadius = 15
        plate.layer.cornerCurve = .continuous
        close.addSubview(plate)
        close.sendSubviewToBack(plate)

        header.addSubview(title)
        header.addSubview(close)
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: 52),
            title.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            title.leadingAnchor.constraint(greaterThanOrEqualTo: close.trailingAnchor, constant: 8),
            close.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 8),
            close.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 44),
            close.heightAnchor.constraint(equalToConstant: 44),
            plate.centerXAnchor.constraint(equalTo: close.centerXAnchor),
            plate.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            plate.widthAnchor.constraint(equalToConstant: 30),
            plate.heightAnchor.constraint(equalToConstant: 30),
        ])
        return header
    }

    private func makePreview(for boost: DiscourseTopicDetail.Boost) -> UIView {
        let wrap = UIView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        let bubble = UIView()
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.backgroundColor = AppSettings.shared.themeStyle.topicChipBackgroundColor
        bubble.layer.cornerRadius = 16
        bubble.layer.cornerCurve = .continuous

        let content = BoostStripView.makeTitleContentView(
            cookedHTML: boost.cooked.isEmpty ? previewCookedHTML : boost.cooked,
            plainFallback: previewPlain,
            baseURL: baseURL,
            font: .systemFont(ofSize: 16),
            emojiSize: 22,
            textColor: .label,
            numberOfLines: 3
        )
        content.translatesAutoresizingMaskIntoConstraints = false

        let floor = UILabel()
        floor.translatesAutoresizingMaskIntoConstraints = false
        floor.font = .systemFont(ofSize: 14)
        floor.textColor = .secondaryLabel
        let sender = boost.user.username
        if postNumber > 0, !sender.isEmpty {
            floor.text = "@\(sender) · #\(postNumber)"
        } else if !sender.isEmpty {
            floor.text = "@\(sender)"
        } else {
            floor.text = nil
        }

        bubble.addSubview(content)
        wrap.addSubview(bubble)
        wrap.addSubview(floor)
        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 4),
            bubble.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 16),
            bubble.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 12),
            content.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -14),
            content.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -12),
            floor.topAnchor.constraint(equalTo: bubble.bottomAnchor, constant: 10),
            floor.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 4),
            floor.trailingAnchor.constraint(equalTo: bubble.trailingAnchor),
            floor.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -12),
        ])
        return wrap
    }

    private func makeMenuRow(
        symbol: String,
        title: String,
        tint: UIColor,
        enabled: Bool = true,
        handler: @escaping () -> Void
    ) -> UIView {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.contentHorizontalAlignment = .leading
        button.isEnabled = enabled
        button.accessibilityLabel = title

        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        let icon = UIImageView(image: UIImage(systemName: symbol, withConfiguration: symbolConfig))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.isUserInteractionEnabled = false
        icon.tintColor = tint
        icon.contentMode = .scaleAspectFit

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isUserInteractionEnabled = false
        label.text = title
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.textColor = tint

        button.addSubview(icon)
        button.addSubview(label)
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 50),
            icon.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: button.trailingAnchor, constant: -16),
        ])
        if enabled {
            button.addAction(UIAction { _ in handler() }, for: .touchUpInside)
            let highlight = tint.withAlphaComponent(0.08)
            button.configurationUpdateHandler = { btn in
                btn.backgroundColor = btn.isHighlighted ? highlight : .clear
            }
        }
        return button
    }

    private func makeHairline() -> UIView {
        let wrap = UIView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        let line = UIView()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.backgroundColor = UIColor.separator.withAlphaComponent(0.4)
        wrap.addSubview(line)
        NSLayoutConstraint.activate([
            wrap.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),
            line.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 18),
            line.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            line.topAnchor.constraint(equalTo: wrap.topAnchor),
            line.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
        ])
        return wrap
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
