import UIKit

/// Custom 2FA sheet. FluxDo uses a Material dialog; UIAlertController is easy
/// to miss under the hCaptcha overlay, so this is a first-class card on the
/// login page.
@MainActor
final class NativeTwoFactorPanel: UIView, UITextFieldDelegate {
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onBackup: (() -> Void)?

    private let dimmer = UIView()
    private let card = UIView()
    private let hiddenField = UITextField()
    private let digitLabels: [UILabel]
    private let confirmButton = UIButton(type: .system)
    private let accent: UIColor

    init(accent: UIColor) {
        self.accent = accent
        digitLabels = (0..<6).map { _ in
            let label = UILabel()
            label.textAlignment = .center
            label.font = .monospacedDigitSystemFont(ofSize: 24, weight: .semibold)
            label.textColor = .label
            label.backgroundColor = UIColor.tertiarySystemFill.withAlphaComponent(0.55)
            label.layer.cornerRadius = 12
            label.layer.cornerCurve = .continuous
            label.clipsToBounds = true
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 40).isActive = true
            label.heightAnchor.constraint(equalToConstant: 52).isActive = true
            return label
        }
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func present(
        on host: UIViewController,
        accent: UIColor,
        onBackup: @escaping () -> Void
    ) async -> String? {
        await withCheckedContinuation { continuation in
            let panel = NativeTwoFactorPanel(accent: accent)
            panel.translatesAutoresizingMaskIntoConstraints = false
            host.view.addSubview(panel)
            host.view.bringSubviewToFront(panel)
            NSLayoutConstraint.activate([
                panel.topAnchor.constraint(equalTo: host.view.topAnchor),
                panel.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
                panel.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
                panel.bottomAnchor.constraint(equalTo: host.view.bottomAnchor),
            ])
            var resumed = false
            let finish: (String?) -> Void = { value in
                guard !resumed else { return }
                resumed = true
                UIView.animate(withDuration: 0.2, animations: {
                    panel.alpha = 0
                }, completion: { _ in
                    panel.removeFromSuperview()
                    continuation.resume(returning: value)
                })
            }
            panel.onSubmit = { finish($0) }
            panel.onCancel = { finish(nil) }
            panel.onBackup = {
                onBackup()
                finish(nil)
            }
            panel.alpha = 0
            UIView.animate(withDuration: 0.22) { panel.alpha = 1 }
            DispatchQueue.main.async { panel.hiddenField.becomeFirstResponder() }
        }
    }

    private func setup() {
        dimmer.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        dimmer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dimmer)

        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 24
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        let iconWrap = UIView()
        iconWrap.backgroundColor = accent.withAlphaComponent(0.14)
        iconWrap.layer.cornerRadius = 28
        iconWrap.translatesAutoresizingMaskIntoConstraints = false
        let icon = UIImageView(image: UIImage(systemName: "lock.shield.fill"))
        icon.tintColor = accent
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconWrap.addSubview(icon)

        let title = UILabel()
        title.text = String(localized: "native_login.totp.title", defaultValue: "二步验证")
        title.font = AppSettings.shared.appInterfaceFont(ofSize: 20, weight: .bold, fallback: .systemFont(ofSize: 20, weight: .bold))
        title.textAlignment = .center

        let hint = UILabel()
        hint.text = String(localized: "native_login.totp.message", defaultValue: "请输入身份验证器 App 显示的 6 位验证码")
        hint.font = AppSettings.shared.appInterfaceFont(ofSize: 14, weight: .regular, fallback: .systemFont(ofSize: 14))
        hint.textColor = .secondaryLabel
        hint.textAlignment = .center
        hint.numberOfLines = 0

        let digits = UIStackView(arrangedSubviews: digitLabels)
        digits.axis = .horizontal
        digits.spacing = 8
        digits.alignment = .center
        digits.distribution = .equalSpacing
        digits.translatesAutoresizingMaskIntoConstraints = false

        hiddenField.keyboardType = .numberPad
        hiddenField.textContentType = .oneTimeCode
        hiddenField.delegate = self
        hiddenField.addTarget(self, action: #selector(codeChanged), for: .editingChanged)
        hiddenField.alpha = 0.01
        hiddenField.translatesAutoresizingMaskIntoConstraints = false

        let tapDigits = UITapGestureRecognizer(target: self, action: #selector(focusField))
        digits.addGestureRecognizer(tapDigits)
        digits.isUserInteractionEnabled = true

        var confirm = UIButton.Configuration.filled()
        confirm.title = String(localized: "native_login.totp.confirm", defaultValue: "验证")
        confirm.cornerStyle = .capsule
        confirm.baseBackgroundColor = accent
        confirm.baseForegroundColor = .white
        confirmButton.configuration = confirm
        confirmButton.isEnabled = false
        confirmButton.addTarget(self, action: #selector(submitTapped), for: .touchUpInside)
        confirmButton.translatesAutoresizingMaskIntoConstraints = false
        confirmButton.heightAnchor.constraint(equalToConstant: 48).isActive = true

        let cancel = UIButton(type: .system)
        cancel.setTitle(String(localized: "action.cancel"), for: .normal)
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        let backup = UIButton(type: .system)
        backup.setTitle(String(localized: "native_login.totp.backup", defaultValue: "改用备用码 / 网页登录"), for: .normal)
        backup.titleLabel?.font = .systemFont(ofSize: 13)
        backup.addTarget(self, action: #selector(backupTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            iconWrap, title, hint, digits, confirmButton, cancel, backup,
        ])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(16, after: hint)
        stack.setCustomSpacing(20, after: digits)
        card.addSubview(stack)
        card.addSubview(hiddenField)

        NSLayoutConstraint.activate([
            dimmer.topAnchor.constraint(equalTo: topAnchor),
            dimmer.leadingAnchor.constraint(equalTo: leadingAnchor),
            dimmer.trailingAnchor.constraint(equalTo: trailingAnchor),
            dimmer.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -36),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 28),
            card.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -28),
            card.widthAnchor.constraint(equalToConstant: 320),
            iconWrap.widthAnchor.constraint(equalToConstant: 56),
            iconWrap.heightAnchor.constraint(equalToConstant: 56),
            icon.centerXAnchor.constraint(equalTo: iconWrap.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconWrap.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 26),
            icon.heightAnchor.constraint(equalToConstant: 26),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            digits.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            digits.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            confirmButton.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            confirmButton.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            hiddenField.widthAnchor.constraint(equalToConstant: 1),
            hiddenField.heightAnchor.constraint(equalToConstant: 1),
            hiddenField.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            hiddenField.topAnchor.constraint(equalTo: card.topAnchor),
        ])
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        let current = textField.text ?? ""
        guard let swiftRange = Range(range, in: current) else { return false }
        let next = current.replacingCharacters(in: swiftRange, with: string)
        let digits = next.filter(\.isNumber)
        return digits.count <= 6
    }

    @objc private func codeChanged() {
        let digits = (hiddenField.text ?? "").filter(\.isNumber)
        hiddenField.text = digits
        for (index, label) in digitLabels.enumerated() {
            if index < digits.count {
                label.text = String(digits[digits.index(digits.startIndex, offsetBy: index)])
                label.layer.borderWidth = 1.5
                label.layer.borderColor = accent.cgColor
            } else {
                label.text = ""
                label.layer.borderWidth = index == digits.count ? 1.5 : 0
                label.layer.borderColor = index == digits.count ? accent.withAlphaComponent(0.55).cgColor : nil
            }
        }
        confirmButton.isEnabled = digits.count == 6
        if digits.count == 6 {
            onSubmit?(digits)
        }
    }

    @objc private func focusField() {
        hiddenField.becomeFirstResponder()
    }

    @objc private func submitTapped() {
        let digits = (hiddenField.text ?? "").filter(\.isNumber)
        guard digits.count == 6 else { return }
        onSubmit?(digits)
    }

    @objc private func cancelTapped() {
        onCancel?()
    }

    @objc private func backupTapped() {
        onBackup?()
    }
}
