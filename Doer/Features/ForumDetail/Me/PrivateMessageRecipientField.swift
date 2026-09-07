import UIKit

struct PrivateMessageRecipientSelection: Equatable {
    var names: [String]
    var groupNames: Set<String>

    var usernames: [String] {
        names.filter { !groupNames.contains($0) }
    }

    var isEmpty: Bool { names.isEmpty }

    static let empty = PrivateMessageRecipientSelection(names: [], groupNames: [])
}

final class PrivateMessageRecipientField: UIView, UITextFieldDelegate, UITableViewDataSource, UITableViewDelegate {
    var onChange: ((PrivateMessageRecipientSelection) -> Void)?

    private(set) var selection = PrivateMessageRecipientSelection.empty
    private var users: [DiscourseMentionUser] = []
    private var groups: [DiscourseMentionGroup] = []
    private var searchTask: Task<Void, Never>?

    private let api: DiscourseAPI
    private let chipStack = UIStackView()
    private let textField = UITextField()
    private let resultsTable = UITableView()
    private var resultsHeight: NSLayoutConstraint?

    init(api: DiscourseAPI) {
        self.api = api
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        chipStack.translatesAutoresizingMaskIntoConstraints = false
        chipStack.axis = .vertical
        chipStack.spacing = 6
        chipStack.alignment = .leading

        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.borderStyle = .roundedRect
        textField.placeholder = String(
            localized: "messages.compose.recipient_placeholder",
            defaultValue: "Username or group"
        )
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.returnKeyType = .next
        textField.delegate = self
        textField.addTarget(self, action: #selector(textChanged), for: .editingChanged)
        textField.font = .preferredFont(forTextStyle: .body)
        textField.adjustsFontForContentSizeCategory = true

        resultsTable.translatesAutoresizingMaskIntoConstraints = false
        resultsTable.dataSource = self
        resultsTable.delegate = self
        resultsTable.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        resultsTable.isHidden = true
        resultsTable.layer.cornerRadius = 10
        resultsTable.layer.cornerCurve = .continuous
        resultsTable.layer.borderWidth = 1
        resultsTable.layer.borderColor = UIColor.separator.withAlphaComponent(0.4).cgColor

        addSubview(chipStack)
        addSubview(textField)
        addSubview(resultsTable)
        let height = resultsTable.heightAnchor.constraint(equalToConstant: 0)
        resultsHeight = height
        NSLayoutConstraint.activate([
            chipStack.topAnchor.constraint(equalTo: topAnchor),
            chipStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            chipStack.trailingAnchor.constraint(equalTo: trailingAnchor),

            textField.topAnchor.constraint(equalTo: chipStack.bottomAnchor, constant: 8),
            textField.leadingAnchor.constraint(equalTo: leadingAnchor),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor),
            textField.heightAnchor.constraint(equalToConstant: 40),

            resultsTable.topAnchor.constraint(equalTo: textField.bottomAnchor, constant: 6),
            resultsTable.leadingAnchor.constraint(equalTo: leadingAnchor),
            resultsTable.trailingAnchor.constraint(equalTo: trailingAnchor),
            resultsTable.bottomAnchor.constraint(equalTo: bottomAnchor),
            height,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @discardableResult
    override func becomeFirstResponder() -> Bool {
        textField.becomeFirstResponder()
    }

    func setSelection(_ selection: PrivateMessageRecipientSelection) {
        self.selection = selection
        rebuildChips()
        onChange?(selection)
    }

    func addInitialRecipient(_ name: String, isGroup: Bool = false) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard !trimmed.isEmpty else { return }
        add(name: trimmed, isGroup: isGroup)
    }

    @objc private func textChanged() {
        let term = (textField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        guard term.count >= 1 else {
            users = []
            groups = []
            reloadResults()
            return
        }
        searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled, let self else { return }
            do {
                let result = try await self.api.searchPrivateMessageRecipients(term: term)
                guard !Task.isCancelled else { return }
                self.users = result.users.filter { user in
                    !self.selection.names.contains { $0.compare(user.username, options: .caseInsensitive) == .orderedSame }
                }
                self.groups = result.groups.filter { group in
                    !self.selection.names.contains { $0.compare(group.name, options: .caseInsensitive) == .orderedSame }
                }
                self.reloadResults()
            } catch {
                self.users = []
                self.groups = []
                self.reloadResults()
            }
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let typed = (textField.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        if !typed.isEmpty {
            add(name: typed, isGroup: false)
        }
        return false
    }

    private func add(name: String, isGroup: Bool) {
        let exists = selection.names.contains { $0.compare(name, options: .caseInsensitive) == .orderedSame }
        guard !exists else { return }
        selection.names.append(name)
        if isGroup {
            selection.groupNames.insert(name)
        }
        textField.text = ""
        users = []
        groups = []
        rebuildChips()
        reloadResults()
        onChange?(selection)
    }

    private func remove(name: String) {
        selection.names.removeAll { $0.compare(name, options: .caseInsensitive) == .orderedSame }
        selection.groupNames = selection.groupNames.filter {
            $0.compare(name, options: .caseInsensitive) != .orderedSame
        }
        rebuildChips()
        onChange?(selection)
    }

    private func rebuildChips() {
        chipStack.arrangedSubviews.forEach {
            chipStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        guard !selection.names.isEmpty else {
            chipStack.isHidden = true
            return
        }
        chipStack.isHidden = false
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 6
        row.alignment = .center
        row.distribution = .fill
        var current = row
        chipStack.addArrangedSubview(current)

        for name in selection.names {
            let isGroup = selection.groupNames.contains(where: {
                $0.compare(name, options: .caseInsensitive) == .orderedSame
            })
            let chip = makeChip(name: name, isGroup: isGroup)
            current.addArrangedSubview(chip)
        }
    }

    private func makeChip(name: String, isGroup: Bool) -> UIView {
        let chip = UIButton(type: .system)
        var config = UIButton.Configuration.gray()
        config.cornerStyle = .capsule
        config.title = name
        config.image = UIImage(systemName: isGroup ? "person.3.fill" : "person.fill")
        config.imagePadding = 4
        config.imagePlacement = .leading
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 13, weight: .medium)
            return outgoing
        }
        chip.configuration = config
        chip.accessibilityLabel = name
        let remove = UIAction(
            title: String(localized: "pm.remove", defaultValue: "Remove"),
            attributes: .destructive
        ) { [weak self] _ in
            self?.remove(name: name)
        }
        chip.menu = UIMenu(children: [remove])
        chip.showsMenuAsPrimaryAction = false
        chip.addAction(UIAction { [weak self] _ in self?.remove(name: name) }, for: .touchUpInside)
        return chip
    }

    private func reloadResults() {
        resultsTable.reloadData()
        let count = users.count + groups.count
        resultsTable.isHidden = count == 0
        resultsHeight?.constant = CGFloat(min(count, 5) * 44)
        invalidateIntrinsicContentSize()
    }

    private var resultCount: Int { users.count + groups.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        resultCount
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        if indexPath.row < users.count {
            let user = users[indexPath.row]
            content.text = user.username
            content.secondaryText = user.name
            content.image = UIImage(systemName: "person.fill")
        } else {
            let group = groups[indexPath.row - users.count]
            content.text = group.name
            content.secondaryText = group.fullName
            content.image = UIImage(systemName: "person.3.fill")
        }
        cell.contentConfiguration = content
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.row < users.count {
            add(name: users[indexPath.row].username, isGroup: false)
        } else {
            add(name: groups[indexPath.row - users.count].name, isGroup: true)
        }
    }
}
