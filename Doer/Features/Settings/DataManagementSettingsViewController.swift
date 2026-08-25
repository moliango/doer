import UIKit
import UniformTypeIdentifiers
import SDWebImage

final class DataManagementSettingsViewController: ObservableViewController {
    private enum CacheRow: Int, CaseIterable {
        case image
        case cookie
        case local
        case all

        var title: String {
            switch self {
            case .image: return String(localized: "settings.data.image_cache")
            case .cookie: return String(localized: "settings.data.cookie_cache")
            case .local: return String(localized: "settings.data.local_cache")
            case .all: return String(localized: "settings.data.clear_all_cache")
            }
        }

        var symbolName: String {
            switch self {
            case .image: return "photo"
            case .cookie: return "globe.badge.chevron.backward"
            case .local: return "internaldrive"
            case .all: return "trash"
            }
        }

        var subtitleHint: String {
            switch self {
            case .image:
                return String(
                    localized: "settings.data.image_cache.hint",
                    defaultValue: "帖子图片与头像缓存，可重新下载"
                )
            case .cookie:
                return String(
                    localized: "settings.data.cookie_cache.hint",
                    defaultValue: "登录会话 Cookie，清除后可能需要重新验证"
                )
            case .local:
                return String(
                    localized: "settings.data.local_cache.hint",
                    defaultValue: "资料页与表情等本地缓存"
                )
            case .all:
                return String(
                    localized: "settings.data.clear_all_cache.hint",
                    defaultValue: "清除图片、Cookie 与本地缓存"
                )
            }
        }
    }

    private enum BackupRow: Int, CaseIterable {
        case export
        case `import`

        var title: String {
            switch self {
            case .export: return String(localized: "settings.data.export")
            case .import: return String(localized: "settings.data.import")
            }
        }

        var subtitle: String {
            switch self {
            case .export: return String(localized: "settings.data.export.subtitle")
            case .import: return String(localized: "settings.data.import.subtitle")
            }
        }

        var symbolName: String {
            switch self {
            case .export: return "square.and.arrow.up"
            case .import: return "square.and.arrow.down"
            }
        }
    }

    private let settings = AppSettings.shared
    private var imageCacheSize: Int64 = 0
    private var cacheRows: [CacheRow: DataManagementActionRowView] = [:]
    private var backupRows: [BackupRow: DataManagementActionRowView] = [:]
    private let autoClearRow = ReadingToggleRowView()
    private let avatarCacheSizeCard = AvatarCacheSizeCardView()
    private var sectionHeaderViews: [DataManagementSectionHeaderView] = []

    private let scrollView: UIScrollView = {
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.showsVerticalScrollIndicator = false
        return scroll
    }()

    private let contentStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 24
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 20, leading: 18, bottom: 28, trailing: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private var cookieCacheSize: Int64 {
        WebCookieStore.shared.persistedDataSize()
    }

    private var appLocalCacheSize: Int64 {
        MeProfileCacheStore.cacheSize() + EmojiStore.cacheSize()
    }

    private var allCacheSize: Int64 {
        imageCacheSize + cookieCacheSize + appLocalCacheSize
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observe(settings)
        title = String(localized: "settings.data_management")
        configureRootView()
        wireActions()
        rebuildContent()
        reloadCacheSizes()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        enableSettingsInteractiveBackSwipe()
        reloadCacheSizes()
    }

    override func updateUI() {
        title = String(localized: "settings.data_management")
        rebuildContent()
        refreshDataViews()
    }

    private func configureRootView() {
        view.backgroundColor = DataManagementPalette.screenBackground
        view.tintColor = settings.themeStyle.accentColor
        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
    }

    private func wireActions() {
        autoClearRow.onValueChanged = { [weak self] isOn in
            guard let self else { return }
            settings.clearImageCacheOnLaunch = isOn
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            refreshDataViews()
        }
        avatarCacheSizeCard.onValueChanged = { [weak self] limit in
            guard let self else { return }
            settings.avatarCacheSizeLimit = limit
            AvatarImageLoader.configureGlobalImageLoading()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            refreshDataViews()
        }
    }

    private func rebuildContent() {
        contentStack.arrangedSubviews.forEach { view in
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        cacheRows.removeAll()
        backupRows.removeAll()
        sectionHeaderViews.removeAll()

        // Appearance-style clean sections — no stats hero panel.
        let limitBody = UIStackView(arrangedSubviews: [avatarCacheSizeCard])
        limitBody.axis = .vertical
        limitBody.spacing = 12
        contentStack.addArrangedSubview(verticalSection(
            title: String(localized: "settings.data.avatar_cache_size.section", defaultValue: "头像缓存上限"),
            symbolName: "internaldrive.fill",
            body: limitBody
        ))

        let cacheBody = UIStackView()
        cacheBody.axis = .vertical
        cacheBody.spacing = 12
        for row in CacheRow.allCases {
            let actionRow = DataManagementActionRowView()
            actionRow.addAction(UIAction { [weak self] _ in
                guard let self, self.canClear(row) else { return }
                self.handleCacheRow(row)
            }, for: .touchUpInside)
            cacheBody.addArrangedSubview(actionRow)
            cacheRows[row] = actionRow
        }
        contentStack.addArrangedSubview(verticalSection(
            title: String(localized: "settings.data.cache_management"),
            symbolName: "externaldrive.badge.icloud",
            body: cacheBody
        ))

        let autoBody = UIStackView(arrangedSubviews: [autoClearRow])
        autoBody.axis = .vertical
        autoBody.spacing = 12
        contentStack.addArrangedSubview(verticalSection(
            title: String(localized: "settings.data.automatic_management"),
            symbolName: "trash.circle",
            body: autoBody
        ))

        let backupBody = UIStackView()
        backupBody.axis = .vertical
        backupBody.spacing = 12
        for row in BackupRow.allCases {
            let actionRow = DataManagementActionRowView()
            actionRow.addAction(UIAction { [weak self] _ in
                switch row {
                case .export:
                    self?.exportPreferences()
                case .import:
                    self?.importPreferences()
                }
            }, for: .touchUpInside)
            backupBody.addArrangedSubview(actionRow)
            backupRows[row] = actionRow
        }
        contentStack.addArrangedSubview(verticalSection(
            title: String(localized: "settings.data.backup"),
            symbolName: "icloud.and.arrow.up",
            body: backupBody
        ))
    }

    private func verticalSection(title: String, symbolName: String, body: UIView) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        let header = DataManagementSectionHeaderView(
            title: title,
            symbolName: symbolName,
            tintColor: settings.themeStyle.accentColor
        )
        sectionHeaderViews.append(header)
        stack.addArrangedSubview(header)
        stack.addArrangedSubview(body)
        return stack
    }

    private func reloadCacheSizes() {
        SDImageCache.shared.calculateSize { [weak self] _, totalSize in
            Task { @MainActor in
                self?.imageCacheSize = Int64(totalSize)
                self?.refreshDataViews()
            }
        }
    }

    private func refreshDataViews() {
        view.backgroundColor = DataManagementPalette.screenBackground
        view.tintColor = settings.themeStyle.accentColor
        let cardBackground = settings.themeStyle.topicCardBackgroundColor
        let accent = settings.themeStyle.accentColor
        sectionHeaderViews.forEach { $0.setTintColor(accent) }

        for row in CacheRow.allCases {
            let enabled = canClear(row)
            let tint: UIColor = {
                switch row {
                case .image: return DataManagementPalette.secondaryBlue
                case .cookie: return .systemTeal
                case .local: return .systemIndigo
                case .all: return .systemRed
                }
            }()
            let sizeText = cacheSizeText(for: row)
            let subtitle = enabled
                ? "\(sizeText) · \(row.subtitleHint)"
                : "\(String(localized: "settings.data.no_cache")) · \(row.subtitleHint)"
            cacheRows[row]?.configure(
                title: row.title,
                subtitle: subtitle,
                symbolName: row.symbolName,
                tintColor: enabled || row == .all ? tint : .tertiaryLabel,
                backgroundColor: cardBackground
            )
            cacheRows[row]?.isEnabled = enabled
            cacheRows[row]?.alpha = enabled ? 1 : 0.55
        }

        autoClearRow.configure(
            title: String(localized: "settings.data.clear_image_on_launch"),
            subtitle: String(localized: "settings.data.clear_image_on_launch.subtitle"),
            symbolName: "trash.circle",
            isOn: settings.clearImageCacheOnLaunch,
            accentColor: accent,
            backgroundColor: cardBackground
        )

        avatarCacheSizeCard.configure(
            limit: settings.avatarCacheSizeLimit,
            accentColor: accent,
            backgroundColor: cardBackground
        )

        for row in BackupRow.allCases {
            backupRows[row]?.configure(
                title: row.title,
                subtitle: row.subtitle,
                symbolName: row.symbolName,
                tintColor: accent,
                backgroundColor: cardBackground
            )
            backupRows[row]?.isEnabled = true
            backupRows[row]?.alpha = 1
        }
    }
}

extension DataManagementSettingsViewController {
    private func cacheSizeText(for row: CacheRow) -> String {
        switch row {
        case .image:
            return formattedSize(imageCacheSize)
        case .cookie:
            return formattedSize(cookieCacheSize)
        case .local:
            return formattedSize(appLocalCacheSize)
        case .all:
            return formattedSize(allCacheSize)
        }
    }

    private func canClear(_ row: CacheRow) -> Bool {
        switch row {
        case .image:
            return imageCacheSize > 0
        case .cookie:
            return cookieCacheSize > 0
        case .local:
            return appLocalCacheSize > 0
        case .all:
            return allCacheSize > 0
        }
    }

    private func formattedSize(_ size: Int64) -> String {
        guard size > 0 else {
            return String(localized: "settings.data.no_cache")
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.includesCount = true
        return formatter.string(fromByteCount: size)
    }

    private func handleCacheRow(_ row: CacheRow) {
        switch row {
        case .image:
            clearImageCache(showCompletion: true)
        case .cookie:
            confirm(
                title: String(localized: "settings.data.clear_cookie.confirm.title"),
                message: String(localized: "settings.data.clear_cookie.confirm.message"),
                destructiveTitle: String(localized: "settings.data.clear")
            ) { [weak self] in
                self?.clearCookieCache(showCompletion: true)
            }
        case .local:
            confirm(
                title: String(
                    localized: "settings.data.clear_local.confirm.title",
                    defaultValue: "清除本地缓存？"
                ),
                message: String(
                    localized: "settings.data.clear_local.confirm.message",
                    defaultValue: "将清除资料页与表情本地缓存，不会退出登录。"
                ),
                destructiveTitle: String(localized: "settings.data.clear")
            ) { [weak self] in
                self?.clearLocalCache(showCompletion: true)
            }
        case .all:
            confirm(
                title: String(localized: "settings.data.clear_all.confirm.title"),
                message: String(localized: "settings.data.clear_all.confirm.message"),
                destructiveTitle: String(localized: "settings.data.clear")
            ) { [weak self] in
                self?.clearAllCaches()
            }
        }
    }

    func clearImageCache(showCompletion: Bool, completion: (() -> Void)? = nil) {
        AvatarImageLoader.clearAllCaches { [weak self] in
            self?.reloadCacheSizes()
            if showCompletion {
                self?.showMessage(String(localized: "settings.data.image_cache_cleared"))
            }
            completion?()
        }
    }

    func clearCookieCache(showCompletion: Bool, completion: (() -> Void)? = nil) {
        Task { @MainActor [weak self] in
            AuthManager.shared.invalidateWebSession(for: ForumInstance.linuxDoBaseURL)
            await WebCookieStore.shared.clearWebViewCookies(for: ForumInstance.linuxDoBaseURL)
            self?.reloadCacheSizes()
            if showCompletion {
                self?.showMessage(String(localized: "settings.data.cookie_cache_cleared"))
            }
            completion?()
        }
    }

    func clearLocalCache(showCompletion: Bool, completion: (() -> Void)? = nil) {
        MeProfileCacheStore.clearAll()
        EmojiStore.clearCache()
        reloadCacheSizes()
        if showCompletion {
            showMessage(String(
                localized: "settings.data.local_cache_cleared",
                defaultValue: "本地缓存已清除"
            ))
        }
        completion?()
    }

    func clearAllCaches() {
        clearImageCache(showCompletion: false) { [weak self] in
            self?.clearLocalCache(showCompletion: false) {
                self?.clearCookieCache(showCompletion: false) {
                    self?.reloadCacheSizes()
                    self?.showMessage(String(localized: "settings.data.all_cache_cleared"))
                }
            }
        }
    }

    func confirm(title: String, message: String, destructiveTitle: String, action: @escaping () -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: destructiveTitle, style: .destructive) { _ in
            action()
        })
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        present(alert, animated: true)
    }

    func exportPreferences() {
        do {
            let data = try settings.makePreferencesBackupData()
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("Doer-Preferences-\(Self.backupTimestamp()).json")
            try data.write(to: fileURL, options: .atomic)
            let activity = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
            activity.popoverPresentationController?.sourceView = view
            activity.popoverPresentationController?.sourceRect = view.bounds
            present(activity, animated: true)
        } catch {
            showError(error.localizedDescription)
        }
    }

    func importPreferences() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    func showMessage(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "common.ok"), style: .default))
        present(alert, animated: true)
    }

    func showError(_ message: String) {
        let alert = UIAlertController(
            title: String(localized: "settings.operation_failed"),
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "common.ok"), style: .default))
        present(alert, animated: true)
    }

    static func backupTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

enum DataManagementPalette {
    static let dataBlue = UIColor(red: 0.12, green: 0.25, blue: 0.69, alpha: 1)
    static let secondaryBlue = UIColor(red: 0.23, green: 0.51, blue: 0.96, alpha: 1)
    static let deepBlue = UIColor(red: 0.06, green: 0.12, blue: 0.27, alpha: 1)
    static let amber = UIColor(red: 0.96, green: 0.62, blue: 0.04, alpha: 1)

    static var screenBackground: UIColor {
        let theme = AppSettings.shared.themeStyle
        if theme == .oled {
            return theme.topicListBackgroundColor
        }
        return UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.04, green: 0.07, blue: 0.12, alpha: 1)
                : UIColor(red: 0.97, green: 0.98, blue: 0.99, alpha: 1)
        }
    }

    static var borderColor: UIColor {
        UIColor.separator.withAlphaComponent(0.22)
    }
}

final class DataManagementSectionHeaderView: UIView {
    private let iconView: UIImageView = {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isUserInteractionEnabled = false
        return view
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 17, weight: .bold)
        label.textColor = .label
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isUserInteractionEnabled = false
        return label
    }()

    init(title: String, symbolName: String, tintColor: UIColor) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = title
        iconView.image = UIImage(systemName: symbolName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .bold))
        iconView.tintColor = tintColor
        addSubview(iconView)
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 9),
            titleLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    func setTintColor(_ color: UIColor) {
        iconView.tintColor = color
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class DataManagementActionRowView: UIControl {
    private let iconContainer = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let chevronView = UIImageView(image: UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)))

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.14, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.alpha = self.isHighlighted ? 0.76 : 1
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.99, y: 0.99) : .identity
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
    }

    private func setupUI() {
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(greaterThanOrEqualToConstant: 66).isActive = true
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = DataManagementPalette.borderColor.cgColor
        layer.shadowOpacity = 0.07
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 5)
        // 性能优化：预计算阴影路径
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath

        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.layer.cornerRadius = 13
        iconContainer.layer.cornerCurve = .continuous
        iconContainer.isUserInteractionEnabled = false

        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.isUserInteractionEnabled = false
        iconContainer.addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        titleLabel.textColor = .label
        titleLabel.isUserInteractionEnabled = false

        subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 2
        subtitleLabel.isUserInteractionEnabled = false

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.isUserInteractionEnabled = false

        chevronView.tintColor = .tertiaryLabel
        chevronView.translatesAutoresizingMaskIntoConstraints = false
        chevronView.isUserInteractionEnabled = false

        addSubview(iconContainer)
        addSubview(textStack)
        addSubview(chevronView)
        NSLayoutConstraint.activate([
            iconContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconContainer.widthAnchor.constraint(equalToConstant: 40),
            iconContainer.heightAnchor.constraint(equalToConstant: 40),
            iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
            textStack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            textStack.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 12),
            textStack.trailingAnchor.constraint(equalTo: chevronView.leadingAnchor, constant: -14),
            textStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            chevronView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            chevronView.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 12),
            chevronView.heightAnchor.constraint(equalToConstant: 18),
        ])
        accessibilityTraits = [.button]
    }

    func configure(title: String, subtitle: String, symbolName: String, tintColor: UIColor, backgroundColor: UIColor) {
        self.backgroundColor = backgroundColor
        layer.shadowColor = tintColor.cgColor
        layer.borderColor = tintColor.withAlphaComponent(0.14).cgColor
        iconContainer.backgroundColor = tintColor.withAlphaComponent(0.14)
        iconView.image = UIImage(systemName: symbolName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold))
        iconView.tintColor = tintColor
        titleLabel.text = title
        subtitleLabel.text = subtitle
        accessibilityLabel = "\(title)，\(subtitle)"
    }

}

extension DataManagementSettingsViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let data = try Data(contentsOf: url)
            try settings.importPreferencesBackupData(data)
            LightweightDohProxyService.shared.configureFromSettings()
            AvatarImageLoader.configureGlobalImageLoading()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            reloadCacheSizes()
            showMessage(String(localized: "settings.data.import_success"))
        } catch {
            showError(error.localizedDescription)
        }
    }
}

final class PaddingLabel: UILabel {
    var contentInsets = UIEdgeInsets.zero {
        didSet {
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
        }
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: size.width + contentInsets.left + contentInsets.right,
            height: size.height + contentInsets.top + contentInsets.bottom
        )
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: contentInsets))
    }
}
