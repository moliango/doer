import UIKit

final class PrivateMessageParticipantsView: UIView {
    var onInvite: (() -> Void)?
    var onSelectUser: ((DiscourseTopicDetail.AllowedUser) -> Void)?
    var onRemoveUser: ((DiscourseTopicDetail.AllowedUser) -> Void)?
    var onRemoveGroup: ((DiscourseTopicDetail.AllowedGroup) -> Void)?

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.text = String(localized: "pm.participants", defaultValue: "Participants")
        return label
    }()

    private let countLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textAlignment = .center
        return label
    }()

    private let inviteButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(UIImage(systemName: "person.badge.plus"), for: .normal)
        button.accessibilityLabel = String(localized: "pm.invite", defaultValue: "Invite")
        return button
    }()

    private let wrapView = WrappingChipView()
    private var heightConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        backgroundColor = .secondarySystemGroupedBackground
        layer.borderColor = UIColor.separator.withAlphaComponent(0.45).cgColor

        wrapView.translatesAutoresizingMaskIntoConstraints = false
        inviteButton.addTarget(self, action: #selector(inviteTapped), for: .touchUpInside)

        let countWrap = UIView()
        countWrap.translatesAutoresizingMaskIntoConstraints = false
        countWrap.backgroundColor = UIColor.tertiarySystemFill
        countWrap.layer.cornerRadius = 9
        countWrap.addSubview(countLabel)

        addSubview(titleLabel)
        addSubview(countWrap)
        addSubview(inviteButton)
        addSubview(wrapView)

        let height = heightAnchor.constraint(equalToConstant: 0)
        heightConstraint = height
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),

            countWrap.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            countWrap.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            countWrap.heightAnchor.constraint(equalToConstant: 18),

            countLabel.leadingAnchor.constraint(equalTo: countWrap.leadingAnchor, constant: 7),
            countLabel.trailingAnchor.constraint(equalTo: countWrap.trailingAnchor, constant: -7),
            countLabel.centerYAnchor.constraint(equalTo: countWrap.centerYAnchor),

            inviteButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            inviteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            inviteButton.widthAnchor.constraint(equalToConstant: 32),
            inviteButton.heightAnchor.constraint(equalToConstant: 32),
            inviteButton.leadingAnchor.constraint(greaterThanOrEqualTo: countWrap.trailingAnchor, constant: 8),

            wrapView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            wrapView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            wrapView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            wrapView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            height,
        ])
        height.isActive = false
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(
        topic: DiscourseTopicDetail?,
        baseURL: String,
        location: PrivateMessageParticipantsLocation,
        removingUserId: Int?,
        removingGroupName: String?,
        controlsLocked: Bool
    ) {
        let users = topic?.allowedUsers ?? []
        let groups = topic?.allowedGroups ?? []
        let show: Bool
        switch location {
        case .firstPost:
            show = PrivateMessageParticipantsPolicy.shouldShow(
                isPrivateMessage: topic?.isPrivateMessage == true,
                userCount: users.count,
                groupCount: groups.count
            )
        case .bottom:
            show = PrivateMessageParticipantsPolicy.shouldShowAtBottom(
                isPrivateMessage: topic?.isPrivateMessage == true,
                postsCount: topic?.postsCount ?? 0,
                userCount: users.count,
                groupCount: groups.count
            )
        }
        isHidden = !show
        guard show, let topic else { return }

        let accent = AppSettings.shared.themeStyle.accentColor
        layer.borderColor = accent.withAlphaComponent(0.22).cgColor
        countLabel.text = "\(users.count + groups.count)"
        inviteButton.isHidden = !(topic.canInviteTo && onInvite != nil)
        inviteButton.isEnabled = !controlsLocked
        inviteButton.tintColor = accent

        var chips: [UIView] = []
        for group in groups {
            chips.append(
                makeGroupChip(
                    group,
                    canRemove: PrivateMessageParticipantsPolicy.canRemoveGroup(
                        canRemoveAllowedUsers: topic.canRemoveAllowedUsers
                    ) && onRemoveGroup != nil,
                    isRemoving: removingGroupName?.compare(group.name, options: .caseInsensitive) == .orderedSame,
                    locked: controlsLocked
                )
            )
        }
        for user in users {
            let isSelf = PrivateMessageParticipantsPolicy.isSelf(
                userId: user.id,
                canRemoveSelfId: topic.canRemoveSelfId
            )
            chips.append(
                makeUserChip(
                    user,
                    baseURL: baseURL,
                    canRemove: PrivateMessageParticipantsPolicy.canRemoveUser(
                        userId: user.id,
                        canRemoveAllowedUsers: topic.canRemoveAllowedUsers,
                        canRemoveSelfId: topic.canRemoveSelfId
                    ) && onRemoveUser != nil,
                    isSelf: isSelf,
                    isRemoving: removingUserId == user.id,
                    locked: controlsLocked
                )
            )
        }
        wrapView.setChips(chips)
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: CGSize {
        systemLayoutSizeFitting(
            CGSize(width: bounds.width > 0 ? bounds.width : 320, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        if isHidden { return CGSize(width: targetSize.width, height: 0) }
        let innerWidth = max(0, targetSize.width - 24)
        wrapView.bounds.size.width = innerWidth
        wrapView.invalidateIntrinsicContentSize()
        let wrapHeight = wrapView.intrinsicContentSize.height
        return CGSize(width: targetSize.width, height: 12 + 22 + 10 + max(wrapHeight, 32) + 12)
    }

    @objc private func inviteTapped() {
        onInvite?()
    }

    private func makeUserChip(
        _ user: DiscourseTopicDetail.AllowedUser,
        baseURL: String,
        canRemove: Bool,
        isSelf: Bool,
        isRemoving: Bool,
        locked: Bool
    ) -> UIView {
        let avatar = UIImageView()
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.layer.cornerRadius = 14
        avatar.clipsToBounds = true
        avatar.contentMode = .scaleAspectFill
        avatar.backgroundColor = .tertiarySystemFill
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 28),
            avatar.heightAnchor.constraint(equalToConstant: 28),
        ])
        AvatarImageLoader.setImage(
            on: avatar,
            template: user.avatarTemplate,
            baseURL: baseURL,
            userId: user.id,
            size: 56
        )
        return makeChip(
            leading: avatar,
            title: user.displayName,
            canRemove: canRemove,
            isRemoving: isRemoving,
            locked: locked,
            removeTitle: isSelf
                ? String(localized: "pm.leave", defaultValue: "Leave")
                : String(localized: "pm.remove", defaultValue: "Remove"),
            onTap: { [weak self] in self?.onSelectUser?(user) },
            onRemove: { [weak self] in self?.onRemoveUser?(user) }
        )
    }

    private func makeGroupChip(
        _ group: DiscourseTopicDetail.AllowedGroup,
        canRemove: Bool,
        isRemoving: Bool,
        locked: Bool
    ) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: "person.3.fill"))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.tintColor = .secondaryLabel
        icon.contentMode = .scaleAspectFit
        icon.backgroundColor = .tertiarySystemFill
        icon.layer.cornerRadius = 14
        icon.clipsToBounds = true
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
        ])
        return makeChip(
            leading: icon,
            title: group.name,
            canRemove: canRemove,
            isRemoving: isRemoving,
            locked: locked,
            removeTitle: String(localized: "pm.remove", defaultValue: "Remove"),
            onTap: nil,
            onRemove: { [weak self] in self?.onRemoveGroup?(group) }
        )
    }

    private func makeChip(
        leading: UIView,
        title: String,
        canRemove: Bool,
        isRemoving: Bool,
        locked: Bool,
        removeTitle: String,
        onTap: (() -> Void)?,
        onRemove: (() -> Void)?
    ) -> UIView {
        let chip = PrivateMessageChipControl()
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.backgroundColor = .tertiarySystemFill
        chip.layer.cornerRadius = 16
        chip.layer.cornerCurve = .continuous
        chip.onTap = onTap
        chip.isEnabled = onTap != nil && !locked && !isRemoving
        chip.accessibilityLabel = title

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.text = title
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [leading, label])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        stack.isUserInteractionEnabled = false

        if canRemove {
            if isRemoving {
                let spinner = UIActivityIndicatorView(style: .medium)
                spinner.translatesAutoresizingMaskIntoConstraints = false
                spinner.startAnimating()
                stack.addArrangedSubview(spinner)
            } else {
                let remove = UIButton(type: .system)
                remove.translatesAutoresizingMaskIntoConstraints = false
                remove.setImage(
                    UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)),
                    for: .normal
                )
                remove.tintColor = .secondaryLabel
                remove.accessibilityLabel = removeTitle
                remove.isEnabled = !locked
                remove.addAction(UIAction { _ in onRemove?() }, for: .touchUpInside)
                NSLayoutConstraint.activate([
                    remove.widthAnchor.constraint(equalToConstant: 28),
                    remove.heightAnchor.constraint(equalToConstant: 28),
                ])
                stack.addArrangedSubview(remove)
                stack.isUserInteractionEnabled = true
                leading.isUserInteractionEnabled = false
                label.isUserInteractionEnabled = false
            }
        }

        chip.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: chip.topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -2),
            stack.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -4),
            chip.heightAnchor.constraint(equalToConstant: 32),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 140),
        ])
        return chip
    }
}

enum PrivateMessageParticipantsLocation {
    case firstPost
    case bottom
}

private final class PrivateMessageChipControl: UIControl {
    var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func handleTap() {
        onTap?()
    }
}

private final class WrappingChipView: UIView {
    private var chips: [UIView] = []
    private let spacing: CGFloat = 8

    func setChips(_ views: [UIView]) {
        chips.forEach { $0.removeFromSuperview() }
        chips = views
        views.forEach { addSubview($0) }
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        _ = layoutHeight(forWidth: bounds.width, apply: true)
    }

    override var intrinsicContentSize: CGSize {
        let width = bounds.width > 0 ? bounds.width : 320
        return CGSize(width: UIView.noIntrinsicMetric, height: layoutHeight(forWidth: width, apply: false))
    }

    @discardableResult
    private func layoutHeight(forWidth width: CGFloat, apply: Bool) -> CGFloat {
        guard !chips.isEmpty else { return 0 }
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for chip in chips {
            let size = chip.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            if apply {
                chip.frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return y + rowHeight
    }
}
