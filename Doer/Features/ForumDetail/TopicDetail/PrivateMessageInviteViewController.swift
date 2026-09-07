import UIKit

final class PrivateMessageInviteViewController: UIViewController {
    var onConfirm: ((PrivateMessageRecipientSelection) -> Void)?

    private let recipientField: PrivateMessageRecipientField
    private var selection = PrivateMessageRecipientSelection.empty
    private var confirmItem: UIBarButtonItem?

    init(api: DiscourseAPI) {
        recipientField = PrivateMessageRecipientField(api: api)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "pm.invite", defaultValue: "Invite")
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: String(localized: "common.cancel", defaultValue: "Cancel"),
            style: .plain,
            target: self,
            action: #selector(cancelTapped)
        )
        let confirm = UIBarButtonItem(
            title: String(localized: "common.done", defaultValue: "Done"),
            style: .done,
            target: self,
            action: #selector(confirmTapped)
        )
        confirm.isEnabled = false
        confirmItem = confirm
        navigationItem.rightBarButtonItem = confirm

        let hint = UILabel()
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.font = .preferredFont(forTextStyle: .footnote)
        hint.textColor = .secondaryLabel
        hint.numberOfLines = 0
        hint.text = String(
            localized: "pm.invite.hint",
            defaultValue: "Search users or groups to add to this message."
        )

        recipientField.onChange = { [weak self] selection in
            self?.selection = selection
            self?.confirmItem?.isEnabled = !selection.isEmpty
        }

        view.addSubview(hint)
        view.addSubview(recipientField)
        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            recipientField.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 12),
            recipientField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            recipientField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        recipientField.becomeFirstResponder()
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func confirmTapped() {
        guard !selection.isEmpty else { return }
        let result = selection
        dismiss(animated: true) { [onConfirm] in
            onConfirm?(result)
        }
    }
}
