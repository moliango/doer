import UIKit
import WebKit

/// Native username/password login, laid out like Doer Settings / Me cards.
final class NativeLoginViewController: UIViewController, UITextFieldDelegate {
    static let linuxDoHCaptchaSiteKey = "a776b4ac-8c4c-441e-986a-c6ee9ed8cf08"

    private let forum: ForumInstance
    private let preferredUsername: String?
    private let onBrowseWelcome: (() -> Void)?
    private let onSuccess: ([HTTPCookie], String?) -> Void
    private let credentialStore: AccountCredentialStore

    private let scrollView = UIScrollView()
    private let usernameField = UITextField()
    private let passwordField = UITextField()
    private let usernameWrap = UIView()
    private let passwordWrap = UIView()
    private let usernameFocusBar = UIView()
    private let passwordFocusBar = UIView()
    private let rememberButton = UIButton(type: .system)
    private let loginButton = UIButton(type: .system)
    private let passwordToggle = UIButton(type: .system)
    private var usernameIconView: UIImageView?
    private var passwordIconView: UIImageView?
    private var rememberOn = true
    private var runner: NativeLoginSessionRunner?
    private var isSubmitting = false

    init(
        forum: ForumInstance,
        preferredUsername: String?,
        onBrowseWelcome: (() -> Void)? = nil,
        onSuccess: @escaping ([HTTPCookie], String?) -> Void
    ) {
        self.forum = forum
        self.preferredUsername = preferredUsername
        self.onBrowseWelcome = onBrowseWelcome
        self.onSuccess = onSuccess
        self.credentialStore = AccountCredentialStore.forBaseURL(forum.baseURL)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = AppSettings.shared.appearanceMode.userInterfaceStyle
        view.backgroundColor = theme.topicListBackgroundColor
        view.tintColor = accentColor
        title = String(localized: "native_login.submit", defaultValue: "登录")
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "chevron.backward"),
            style: .plain,
            target: self,
            action: #selector(closeTapped)
        )
        if credentialStore.hasCredentials {
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                image: UIImage(systemName: "trash"),
                style: .plain,
                target: self,
                action: #selector(clearCredentialsTapped)
            )
        }
        applyNavigationChrome()
        setupUI()
        prefillCredentials()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        applyNavigationChrome()
    }

    private var forumHost: String {
        URL(string: forum.baseURL)?.host ?? "LINUX.DO"
    }

    private var hcaptchaSiteKey: String? {
        let host = forumHost.lowercased()
        if host == "linux.do" || host.hasSuffix(".linux.do") {
            return Self.linuxDoHCaptchaSiteKey
        }
        return nil
    }

    private var theme: AppSettings.ThemeStyle { AppSettings.shared.themeStyle }
    private var accentColor: UIColor { theme.accentColor }
    private var cardRadius: CGFloat { max(theme.chromeCornerRadius, 12) }

    private func applyNavigationChrome() {
        let appearance = UINavigationBarAppearance()
        if theme.prefersOpaqueChrome || theme == .oled {
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = theme.topicListBackgroundColor
        } else {
            appearance.configureWithDefaultBackground()
            appearance.backgroundColor = theme.topicListBackgroundColor.withAlphaComponent(0.92)
        }
        appearance.shadowColor = .clear
        appearance.titleTextAttributes = [
            .foregroundColor: UIColor.label,
            .font: AppSettings.shared.appInterfaceFont(ofSize: 17, weight: .semibold, fallback: .systemFont(ofSize: 17, weight: .semibold)),
        ]
        let nav = navigationController?.navigationBar
        nav?.standardAppearance = appearance
        nav?.scrollEdgeAppearance = appearance
        nav?.compactAppearance = appearance
        nav?.tintColor = accentColor
        nav?.isTranslucent = !theme.prefersOpaqueChrome && theme != .oled
    }

    private func setupUI() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive
        scrollView.showsVerticalScrollIndicator = false
        view.addSubview(scrollView)

        let content = UIStackView()
        content.axis = .vertical
        content.alignment = .fill
        content.spacing = 16
        content.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(content)

        content.addArrangedSubview(makeHeader())
        content.setCustomSpacing(28, after: content.arrangedSubviews.last!)
        content.addArrangedSubview(makeFormCard())
        content.addArrangedSubview(makeRememberRow())
        content.addArrangedSubview(loginButton)
        configureLoginButton()
        content.setCustomSpacing(28, after: loginButton)
        content.addArrangedSubview(makeAltLogin())

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 20),
            content.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -18),
            content.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -32),
        ])
    }

    private func makeHeader() -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12

        let icon = UIImageView(image: appIconImage())
        icon.contentMode = .scaleAspectFill
        icon.clipsToBounds = true
        icon.layer.cornerRadius = 18
        icon.layer.cornerCurve = .continuous
        icon.layer.borderWidth = 0.5
        icon.layer.borderColor = UIColor.separator.withAlphaComponent(0.35).cgColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true

        let title = UILabel()
        title.text = String(localized: "native_login.brand", defaultValue: "LinuxDO x Doer")
        title.font = AppSettings.shared.appInterfaceFont(ofSize: 22, weight: .bold, fallback: .systemFont(ofSize: 22, weight: .bold))
        title.textColor = .label
        title.textAlignment = .center

        let slogan = UILabel()
        slogan.text = String(localized: "native_login.welcome", defaultValue: "欢迎来到 Doer")
        slogan.font = AppSettings.shared.appInterfaceFont(ofSize: 15, weight: .regular, fallback: .systemFont(ofSize: 15))
        slogan.textColor = .secondaryLabel
        slogan.textAlignment = .center

        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(slogan)
        stack.setCustomSpacing(8, after: title)
        return stack
    }

    private func appIconImage() -> UIImage? {
        AppSettings.shared.appIconStyle.previewImage
            ?? UIImage(named: "AboutAppIcon")
            ?? UIImage(named: "AppIcon")
            ?? UIImage(named: "launchImg")
    }

    private func makeFormCard() -> UIView {
        let card = themedCard()
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        let userIcon = makeFieldRow(
            wrap: usernameWrap,
            field: usernameField,
            focusBar: usernameFocusBar,
            icon: "person.fill",
            placeholder: String(localized: "native_login.username", defaultValue: "用户名 / 邮箱")
        )
        usernameIconView = userIcon
        usernameField.textContentType = .username
        usernameField.keyboardType = .emailAddress
        usernameField.returnKeyType = .next
        usernameField.delegate = self

        let passIcon = makeFieldRow(
            wrap: passwordWrap,
            field: passwordField,
            focusBar: passwordFocusBar,
            icon: "lock.fill",
            placeholder: String(localized: "native_login.password", defaultValue: "密码")
        )
        passwordIconView = passIcon
        passwordField.isSecureTextEntry = true
        passwordField.textContentType = .password
        passwordField.returnKeyType = .go
        passwordField.delegate = self
        passwordToggle.frame = CGRect(x: 0, y: 0, width: 36, height: 44)
        passwordToggle.setImage(UIImage(systemName: "eye"), for: .normal)
        passwordToggle.tintColor = .tertiaryLabel
        passwordToggle.addTarget(self, action: #selector(togglePassword), for: .touchUpInside)
        passwordField.rightView = passwordToggle
        passwordField.rightViewMode = .always

        stack.addArrangedSubview(usernameWrap)
        stack.addArrangedSubview(makeSeparator())
        stack.addArrangedSubview(passwordWrap)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        return card
    }

    private func makeSeparator() -> UIView {
        let wrap = UIView()
        wrap.backgroundColor = .clear
        let line = UIView()
        line.backgroundColor = UIColor.separator.withAlphaComponent(0.45)
        line.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(line)
        wrap.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 52),
            line.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            line.topAnchor.constraint(equalTo: wrap.topAnchor),
            line.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
        ])
        return wrap
    }

    private func makeFieldRow(
        wrap: UIView,
        field: UITextField,
        focusBar: UIView,
        icon: String,
        placeholder: String
    ) -> UIImageView {
        wrap.backgroundColor = .clear
        wrap.heightAnchor.constraint(equalToConstant: 56).isActive = true

        focusBar.backgroundColor = accentColor
        focusBar.alpha = 0
        focusBar.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(focusBar)

        let image = UIImageView(image: UIImage(systemName: icon))
        image.tintColor = .secondaryLabel
        image.contentMode = .scaleAspectFit
        image.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(image)

        field.placeholder = placeholder
        field.borderStyle = .none
        field.backgroundColor = .clear
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.font = AppSettings.shared.appInterfaceFont(ofSize: 16, weight: .regular, fallback: .systemFont(ofSize: 16))
        field.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(field)

        NSLayoutConstraint.activate([
            focusBar.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            focusBar.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 12),
            focusBar.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -12),
            focusBar.widthAnchor.constraint(equalToConstant: 3),
            image.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 16),
            image.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 20),
            image.heightAnchor.constraint(equalToConstant: 20),
            field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -14),
            field.topAnchor.constraint(equalTo: wrap.topAnchor),
            field.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
        ])
        return image
    }

    private func makeRememberRow() -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 6
        rememberButton.tintColor = accentColor
        rememberButton.addTarget(self, action: #selector(toggleRemember), for: .touchUpInside)
        updateRememberButton()
        let rememberLabel = UIButton(type: .system)
        rememberLabel.setTitle(String(localized: "native_login.remember", defaultValue: "记住密码"), for: .normal)
        rememberLabel.setTitleColor(.label, for: .normal)
        rememberLabel.titleLabel?.font = AppSettings.shared.appInterfaceFont(ofSize: 15, weight: .regular, fallback: .systemFont(ofSize: 15))
        rememberLabel.addTarget(self, action: #selector(toggleRemember), for: .touchUpInside)
        let forgot = UIButton(type: .system)
        forgot.setTitle(String(localized: "native_login.forgot", defaultValue: "忘记密码？"), for: .normal)
        forgot.tintColor = accentColor
        forgot.titleLabel?.font = AppSettings.shared.appInterfaceFont(ofSize: 15, weight: .medium, fallback: .systemFont(ofSize: 15, weight: .medium))
        forgot.addTarget(self, action: #selector(forgotTapped), for: .touchUpInside)
        row.addArrangedSubview(rememberButton)
        row.addArrangedSubview(rememberLabel)
        row.addArrangedSubview(UIView())
        row.addArrangedSubview(forgot)
        return row
    }

    private func configureLoginButton() {
        var config = UIButton.Configuration.filled()
        config.title = String(localized: "native_login.submit", defaultValue: "登录")
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 16, weight: .semibold)
            return outgoing
        }
        config.baseBackgroundColor = accentColor
        config.baseForegroundColor = .white
        config.background.cornerRadius = cardRadius
        loginButton.configuration = config
        loginButton.heightAnchor.constraint(equalToConstant: 50).isActive = true
        loginButton.addTarget(self, action: #selector(loginTapped), for: .touchUpInside)
    }

    private func makeAltLogin() -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10

        let label = UILabel()
        label.text = String(localized: "native_login.or", defaultValue: "其他方式")
        label.font = AppSettings.shared.appInterfaceFont(ofSize: 13, weight: .medium, fallback: .systemFont(ofSize: 13, weight: .medium))
        label.textColor = .secondaryLabel
        stack.addArrangedSubview(label)

        let card = themedCard()
        let rows = UIStackView()
        rows.axis = .vertical
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(rows)
        rows.addArrangedSubview(makeAltRow(
            title: String(localized: "native_login.other", defaultValue: "OAuth / Passkey / 注册"),
            symbol: "arrow.up.forward.app",
            action: #selector(otherLoginTapped)
        ))
        rows.addArrangedSubview(makeSeparator())
        rows.addArrangedSubview(makeAltRow(
            title: String(localized: "native_login.welcome_page", defaultValue: "了解 Doer"),
            symbol: "sparkles",
            action: #selector(welcomePageTapped)
        ))
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: card.topAnchor),
            rows.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            rows.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        stack.addArrangedSubview(card)

        let hint = UILabel()
        hint.text = String(localized: "native_login.other_hint", defaultValue: "注册、Passkey、OAuth 与备用码请走网页登录")
        hint.font = AppSettings.shared.appInterfaceFont(ofSize: 12, weight: .regular, fallback: .systemFont(ofSize: 12))
        hint.textColor = .tertiaryLabel
        hint.numberOfLines = 0
        stack.addArrangedSubview(hint)
        return stack
    }

    private func makeAltRow(title: String, symbol: String, action: Selector) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.title = title
        config.image = UIImage(systemName: symbol)
        config.imagePadding = 10
        config.baseForegroundColor = .label
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
        let button = UIButton(configuration: config)
        button.contentHorizontalAlignment = .leading
        button.addTarget(self, action: action, for: .touchUpInside)
        button.heightAnchor.constraint(equalToConstant: 52).isActive = true
        return button
    }

    private func themedCard() -> UIView {
        let card = UIView()
        card.backgroundColor = theme.topicCardBackgroundColor
        card.layer.cornerRadius = cardRadius
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 0.5
        card.layer.borderColor = UIColor.separator.withAlphaComponent(0.28).cgColor
        card.clipsToBounds = true
        return card
    }

    private func setFieldFocused(_ wrap: UIView, bar: UIView, icon: UIImageView?, focused: Bool) {
        UIView.animate(withDuration: 0.18) {
            bar.alpha = focused ? 1 : 0
            wrap.backgroundColor = focused ? self.accentColor.withAlphaComponent(0.06) : .clear
            icon?.tintColor = focused ? self.accentColor : .secondaryLabel
        }
    }

    private func updateRememberButton() {
        let name = rememberOn ? "checkmark.square.fill" : "square"
        rememberButton.setImage(UIImage(systemName: name), for: .normal)
    }

    private func prefillCredentials() {
        let account: AccountCredentialStore.Account?
        if let preferred = preferredUsername {
            account = credentialStore.accounts.first { $0.username.caseInsensitiveCompare(preferred) == .orderedSame }
                ?? credentialStore.lastUsedAccount
        } else {
            account = credentialStore.lastUsedAccount
        }
        usernameField.text = account?.username
        passwordField.text = account?.password
        rememberOn = account != nil
        updateRememberButton()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === usernameField {
            passwordField.becomeFirstResponder()
        } else {
            loginTapped()
        }
        return true
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        if textField === usernameField {
            setFieldFocused(usernameWrap, bar: usernameFocusBar, icon: usernameIconView, focused: true)
        } else if textField === passwordField {
            setFieldFocused(passwordWrap, bar: passwordFocusBar, icon: passwordIconView, focused: true)
        }
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        if textField === usernameField {
            setFieldFocused(usernameWrap, bar: usernameFocusBar, icon: usernameIconView, focused: false)
        } else if textField === passwordField {
            setFieldFocused(passwordWrap, bar: passwordFocusBar, icon: passwordIconView, focused: false)
        }
    }

    @objc private func togglePassword() {
        passwordField.isSecureTextEntry.toggle()
        let name = passwordField.isSecureTextEntry ? "eye" : "eye.slash"
        passwordToggle.setImage(UIImage(systemName: name), for: .normal)
    }

    @objc private func toggleRemember() {
        rememberOn.toggle()
        updateRememberButton()
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    @objc private func clearCredentialsTapped() {
        credentialStore.clear()
        usernameField.text = nil
        passwordField.text = nil
        rememberOn = false
        updateRememberButton()
        navigationItem.rightBarButtonItem = nil
    }

    @objc private func forgotTapped() {
        openWebLogin(path: "/password-reset")
    }

    @objc private func otherLoginTapped() {
        openWebLogin(path: "/login")
    }

    @objc private func welcomePageTapped() {
        dismiss(animated: true) { [weak self] in
            self?.onBrowseWelcome?()
        }
    }

    @objc private func loginTapped() {
        view.endEditing(true)
        let identifier = usernameField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let password = passwordField.text ?? ""
        guard !identifier.isEmpty, !password.isEmpty else {
            DoerFeedback.presentToast(String(localized: "native_login.fill_both", defaultValue: "请输入用户名和密码"), on: self)
            return
        }
        guard !isSubmitting else { return }
        isSubmitting = true
        setLoginLoading(true)

        let baseURL = URL(string: forum.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            ?? URL(string: "https://linux.do")!
        let runner = NativeLoginSessionRunner(baseURL: baseURL, siteKey: hcaptchaSiteKey)
        self.runner = runner
        var askedSecondFactor = false
        Task { @MainActor in
            let outcome = await runner.run(
                identifier: identifier,
                password: password,
                from: self
            ) { [weak self] in
                if askedSecondFactor, let self {
                    DoerFeedback.presentToast(
                        String(localized: "native_login.totp.retry", defaultValue: "验证码错误，请重试"),
                        on: self
                    )
                }
                askedSecondFactor = true
                return await self?.promptSecondFactor()
            }
            self.isSubmitting = false
            self.setLoginLoading(false)
            self.runner = nil
            switch outcome {
            case .success:
                if self.rememberOn {
                    self.credentialStore.save(username: identifier, password: password)
                }
                await self.finishWithWebCookies()
            case .canceled:
                break
            case .failure(let message):
                DoerFeedback.presentToast(message, on: self)
            case .secondFactor:
                break
            }
        }
    }

    private func setLoginLoading(_ loading: Bool) {
        loginButton.isEnabled = !loading
        var config = loginButton.configuration ?? .filled()
        config.title = loading
            ? String(localized: "native_login.submitting", defaultValue: "登录中…")
            : String(localized: "native_login.submit", defaultValue: "登录")
        loginButton.configuration = config
    }

    private func promptSecondFactor() async -> String? {
        await NativeTwoFactorPanel.present(on: self, accent: accentColor) { [weak self] in
            self?.openWebLogin(path: "/login")
        }
    }

    private func finishWithWebCookies() async {
        let store = WKWebsiteDataStore.default()
        let cookies = await store.httpCookieStore.allCookies()
        let host = URL(string: forum.baseURL)?.host ?? ""
        let relevant = cookies.filter { $0.domain.contains(host) }
        dismiss(animated: true) {
            self.onSuccess(relevant, WebCookieStore.shared.userAgent)
        }
    }

    private func openWebLogin(path: String) {
        let base = forum.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)\(path)") else { return }
        let web = WebLoginViewController(targetURL: url, preferredUsername: preferredUsername) { [weak self] cookies, ua in
            guard let self else { return }
            self.onSuccess(cookies, ua)
            self.dismiss(animated: true)
        }
        navigationController?.pushViewController(web, animated: true)
    }
}
