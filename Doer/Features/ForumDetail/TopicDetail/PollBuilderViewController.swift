import UIKit

final class PollBuilderViewController: UIViewController, UITextViewDelegate {
    var onSave: ((ComposerPollSpec) -> Void)?

    private var spec: ComposerPollSpec
    private let kindControl = UISegmentedControl(items: [
        String(localized: "reply.tool.poll.single", defaultValue: "单选"),
        String(localized: "reply.tool.poll.multiple", defaultValue: "多选"),
        String(localized: "reply.tool.poll.number", defaultValue: "数字"),
    ])
    private let optionsView: UITextView = {
        let view = UITextView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.font = .preferredFont(forTextStyle: .body)
        view.layer.cornerRadius = 12
        view.layer.cornerCurve = .continuous
        view.backgroundColor = .secondarySystemFill
        view.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        return view
    }()
    private let resultsControl = UISegmentedControl(items: [
        String(localized: "reply.tool.poll.results.always", defaultValue: "始终"),
        String(localized: "reply.tool.poll.results.vote", defaultValue: "投票后"),
        String(localized: "reply.tool.poll.results.close", defaultValue: "关闭后"),
    ])
    private let publicSwitch = UISwitch()
    private let chartControl = UISegmentedControl(items: [
        String(localized: "reply.tool.poll.chart.bar", defaultValue: "柱状"),
        String(localized: "reply.tool.poll.chart.pie", defaultValue: "饼图"),
    ])
    private let closeSwitch = UISwitch()
    private let closePicker = UIDatePicker()
    private let minField = UITextField()
    private let maxField = UITextField()
    private let stepField = UITextField()
    private let numberStack = UIStackView()
    private let optionsLabel = UILabel()

    init(spec: ComposerPollSpec) {
        self.spec = spec
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "reply.tool.poll", defaultValue: "插入投票")
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancelTapped)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "reply.tool.insert", defaultValue: "插入"),
            style: .done,
            target: self,
            action: #selector(saveTapped)
        )

        kindControl.selectedSegmentIndex = kindIndex(spec.kind)
        kindControl.addTarget(self, action: #selector(kindChanged), for: .valueChanged)
        optionsView.delegate = self
        optionsView.text = spec.options.joined(separator: "\n")
        resultsControl.selectedSegmentIndex = resultsIndex(spec.results)
        publicSwitch.isOn = spec.isPublic
        chartControl.selectedSegmentIndex = spec.chart == .pie ? 1 : 0
        closePicker.datePickerMode = .dateAndTime
        if #available(iOS 13.4, *) {
            closePicker.preferredDatePickerStyle = .compact
        }
        closePicker.minimumDate = Date()
        if let close = spec.closeISO8601, let date = ISO8601DateFormatter().date(from: close) {
            closeSwitch.isOn = true
            closePicker.date = date
        }
        closePicker.isEnabled = closeSwitch.isOn
        closeSwitch.addTarget(self, action: #selector(closeToggled), for: .valueChanged)
        configureNumberField(minField, value: spec.minValue, placeholder: "min")
        configureNumberField(maxField, value: spec.maxValue, placeholder: "max")
        configureNumberField(stepField, value: spec.step, placeholder: "step")

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 14
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 16, bottom: 32, trailing: 16)

        optionsLabel.font = .preferredFont(forTextStyle: .subheadline)
        optionsLabel.text = String(localized: "reply.tool.poll.options", defaultValue: "每行一个选项，至少两个")
        optionsLabel.textColor = .secondaryLabel
        optionsLabel.numberOfLines = 0

        numberStack.axis = .horizontal
        numberStack.spacing = 8
        numberStack.distribution = .fillEqually
        numberStack.addArrangedSubview(minField)
        numberStack.addArrangedSubview(maxField)
        numberStack.addArrangedSubview(stepField)

        stack.addArrangedSubview(sectionLabel(String(localized: "reply.tool.poll.type", defaultValue: "类型")))
        stack.addArrangedSubview(kindControl)
        stack.addArrangedSubview(optionsLabel)
        stack.addArrangedSubview(optionsView)
        stack.addArrangedSubview(numberStack)
        stack.addArrangedSubview(sectionLabel(String(localized: "reply.tool.poll.results", defaultValue: "结果可见性")))
        stack.addArrangedSubview(resultsControl)
        stack.addArrangedSubview(toggleRow(
            title: String(localized: "reply.tool.poll.public", defaultValue: "公开投票人"),
            control: publicSwitch
        ))
        stack.addArrangedSubview(sectionLabel(String(localized: "reply.tool.poll.chart", defaultValue: "图表")))
        stack.addArrangedSubview(chartControl)
        stack.addArrangedSubview(toggleRow(
            title: String(localized: "reply.tool.poll.close", defaultValue: "定时关闭"),
            control: closeSwitch
        ))
        stack.addArrangedSubview(closePicker)

        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            optionsView.heightAnchor.constraint(equalToConstant: 140),
        ])
        refreshKindVisibility()
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func saveTapped() {
        spec.kind = kindFromIndex(kindControl.selectedSegmentIndex)
        spec.options = optionsView.text.components(separatedBy: .newlines)
        spec.results = resultsFromIndex(resultsControl.selectedSegmentIndex)
        spec.isPublic = publicSwitch.isOn
        spec.chart = chartControl.selectedSegmentIndex == 1 ? .pie : .bar
        spec.closeISO8601 = closeSwitch.isOn ? ISO8601DateFormatter().string(from: closePicker.date) : nil
        spec.minValue = Int(minField.text ?? "") ?? 1
        spec.maxValue = Int(maxField.text ?? "") ?? 10
        spec.step = max(1, Int(stepField.text ?? "") ?? 1)
        onSave?(spec)
        dismiss(animated: true)
    }

    @objc private func kindChanged() {
        refreshKindVisibility()
    }

    @objc private func closeToggled() {
        closePicker.isEnabled = closeSwitch.isOn
    }

    private func refreshKindVisibility() {
        let isNumber = kindFromIndex(kindControl.selectedSegmentIndex) == .number
        optionsView.isHidden = isNumber
        optionsLabel.isHidden = isNumber
        numberStack.isHidden = !isNumber
        chartControl.isEnabled = !isNumber
    }

    private func sectionLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .headline)
        label.text = text
        return label
    }

    private func toggleRow(title: String, control: UISwitch) -> UIView {
        let label = UILabel()
        label.text = title
        label.font = .preferredFont(forTextStyle: .body)
        let row = UIStackView(arrangedSubviews: [label, control])
        row.axis = .horizontal
        row.alignment = .center
        return row
    }

    private func configureNumberField(_ field: UITextField, value: Int, placeholder: String) {
        field.borderStyle = .roundedRect
        field.keyboardType = .numberPad
        field.placeholder = placeholder
        field.text = "\(value)"
        field.textAlignment = .center
    }

    private func kindIndex(_ kind: ComposerPollSpec.Kind) -> Int {
        switch kind {
        case .regular: return 0
        case .multiple: return 1
        case .number: return 2
        }
    }

    private func kindFromIndex(_ index: Int) -> ComposerPollSpec.Kind {
        switch index {
        case 1: return .multiple
        case 2: return .number
        default: return .regular
        }
    }

    private func resultsIndex(_ results: ComposerPollSpec.ResultsVisibility) -> Int {
        switch results {
        case .onVote: return 1
        case .onClose, .staffOnly: return 2
        default: return 0
        }
    }

    private func resultsFromIndex(_ index: Int) -> ComposerPollSpec.ResultsVisibility {
        switch index {
        case 1: return .onVote
        case 2: return .onClose
        default: return .always
        }
    }
}
