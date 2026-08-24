import UIKit
import ObjectiveC
import CoreText

// MARK: - Appearance
extension AppSettings {

    enum AppearanceMode: Int, CaseIterable {
        case system = 0
        case light = 1
        case dark = 2

        var title: String {
            switch self {
            case .system: return String(localized: "appearance.system")
            case .light: return String(localized: "appearance.light")
            case .dark: return String(localized: "appearance.dark")
            }
        }

        var userInterfaceStyle: UIUserInterfaceStyle {
            switch self {
            case .system: return .unspecified
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    enum PluginDockSide: String, CaseIterable {
        case left
        case right
    }

    enum AppLanguage: String, CaseIterable {
        case simplifiedChinese = "zh-Hans"
        case traditionalChineseTaiwan = "zh-Hant-TW"
        case traditionalChineseHongKong = "zh-Hant-HK"
        case english = "en"

        var title: String {
            switch self {
            case .simplifiedChinese: return String(localized: "settings.language.zh_hans")
            case .traditionalChineseTaiwan: return String(localized: "settings.language.zh_hant_tw")
            case .traditionalChineseHongKong: return String(localized: "settings.language.zh_hk")
            case .english: return String(localized: "settings.language.en")
            }
        }

        var preferredLanguageCodes: [String] {
            switch self {
            case .simplifiedChinese:
                return ["zh-Hans"]
            case .traditionalChineseTaiwan:
                return ["zh-Hant-TW", "zh-Hant", "zh-Hans"]
            case .traditionalChineseHongKong:
                return ["zh-Hant-HK", "zh-HK", "zh-Hant", "zh-Hans"]
            case .english:
                return ["en"]
            }
        }

        static func storedValue(_ rawValue: String) -> AppLanguage? {
            switch rawValue {
            case "zh-Hant", "zh-TW":
                return .traditionalChineseTaiwan
            case "zh-HK":
                return .traditionalChineseHongKong
            default:
                return AppLanguage(rawValue: rawValue)
            }
        }
    }

    enum ThemeStyle: Int, CaseIterable {
        case systemDefault = 0
        case eyeCare = 1
        case xiaohongshu = 2
        case telegram = 3
        /// WeChat-inspired green system: colors + denser opaque chrome (option B).
        case weChat = 4

        var title: String {
            switch self {
            case .systemDefault: return String(localized: "settings.theme.default")
            case .eyeCare: return String(localized: "settings.theme.eye_care")
            case .xiaohongshu: return String(localized: "settings.theme.xiaohongshu")
            case .telegram: return String(localized: "settings.theme.telegram")
            case .weChat: return String(localized: "settings.theme.wechat", defaultValue: "微信风格")
            }
        }

        /// Preferred continuous corner radius for cards/chips under this theme.
        var chromeCornerRadius: CGFloat {
            switch self {
            case .weChat: return 10
            case .telegram: return 14
            case .xiaohongshu: return 14
            case .systemDefault, .eyeCare: return 12
            }
        }

        /// WeChat / Telegram use fully opaque tab/nav bars (less iOS blur glass).
        var prefersOpaqueChrome: Bool {
            switch self {
            case .weChat, .telegram: return true
            case .systemDefault, .eyeCare, .xiaohongshu: return false
            }
        }

        /// Theme *pairs* with chat-bubble Topic Detail (WeChat / Telegram).
        /// Effective UI still respects `AppSettings.chatTopicDetailEnabled`.
        var usesChatTopicDetail: Bool {
            switch self {
            case .weChat, .telegram: return true
            default: return false
            }
        }

        /// Full-bleed session-list rows (Home, notifications, history, bookmarks).
        var usesChatHomeList: Bool {
            switch self {
            case .weChat, .telegram: return true
            default: return false
            }
        }

        var accentColor: UIColor {
            switch self {
            case .systemDefault: return .systemBlue
            case .eyeCare: return UIColor(red: 0.24, green: 0.55, blue: 0.34, alpha: 1)
            case .xiaohongshu: return UIColor(red: 0.92, green: 0.13, blue: 0.22, alpha: 1)
            // Telegram brand blue ≈ #3390EC
            case .telegram: return UIColor(red: 0.20, green: 0.56, blue: 0.93, alpha: 1)
            // Official-ish WeChat green #07C160
            case .weChat: return UIColor(red: 0.027, green: 0.757, blue: 0.376, alpha: 1)
            }
        }

        var topicCardBackgroundColor: UIColor {
            switch self {
            case .systemDefault:
                return .secondarySystemGroupedBackground
            case .xiaohongshu:
                return UIColor { trait in
                    trait.userInterfaceStyle == .dark
                        ? UIColor(red: 0.18, green: 0.11, blue: 0.12, alpha: 1)
                        : UIColor.white
                }
            case .eyeCare:
                return contentBackgroundColor
            case .telegram:
                // White rows on white list (Telegram), dark navy in night mode.
                return contentBackgroundColor
            case .weChat:
                return UIColor { trait in
                    trait.userInterfaceStyle == .dark
                        ? UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
                        : UIColor.white
                }
            }
        }

        var topicListBackgroundColor: UIColor {
            switch self {
            case .systemDefault:
                return .systemGroupedBackground
            case .eyeCare, .xiaohongshu:
                return mutedContentBackgroundColor
            case .telegram:
                // Official Telegram chat list is pure white (not WeChat gray).
                return contentBackgroundColor
            case .weChat:
                // WeChat list is slightly gray behind white cells.
                return mutedContentBackgroundColor
            }
        }

        var topicChipBackgroundColor: UIColor {
            switch self {
            case .systemDefault:
                return .secondarySystemGroupedBackground
            case .telegram:
                return UIColor { trait in
                    trait.userInterfaceStyle == .dark
                        ? UIColor(red: 0.14, green: 0.17, blue: 0.20, alpha: 1)
                        : UIColor(red: 0.94, green: 0.95, blue: 0.96, alpha: 1)
                }
            case .eyeCare, .xiaohongshu, .weChat:
                return mutedContentBackgroundColor
            }
        }

        var topicCountForegroundColor: UIColor {
            switch self {
            case .systemDefault: return .secondaryLabel
            case .eyeCare, .xiaohongshu, .telegram, .weChat: return accentColor
            }
        }

        var topicCountBackgroundColor: UIColor {
            switch self {
            case .systemDefault: return .tertiarySystemFill
            case .eyeCare, .xiaohongshu, .telegram, .weChat: return accentColor.withAlphaComponent(0.12)
            }
        }

        var hotTopicColor: UIColor {
            switch self {
            case .systemDefault: return .systemOrange
            case .eyeCare: return UIColor(red: 0.72, green: 0.47, blue: 0.18, alpha: 1)
            case .xiaohongshu: return UIColor(red: 1.0, green: 0.34, blue: 0.40, alpha: 1)
            case .telegram: return UIColor(red: 0.0, green: 0.56, blue: 0.86, alpha: 1)
            case .weChat: return UIColor(red: 0.98, green: 0.62, blue: 0.15, alpha: 1) // warm amber accent
            }
        }

        func topicTagColor(for seed: String) -> UIColor {
            paletteColor(for: seed, palette: topicTagPalette)
        }

        func topicCategoryColor(for seed: String?, fallback: UIColor?) -> UIColor {
            // Default theme (and optional "original colors" mode) keep server/fallback hues.
            guard self != .systemDefault, AppSettings.shared.themeTaxonomyColorsEnabled else {
                return fallback ?? .systemGray
            }
            return paletteColor(for: seed ?? "", palette: topicCategoryPalette)
        }

        var contentBackgroundColor: UIColor {
            switch self {
            case .systemDefault:
                return UIColor { trait in
                    trait.userInterfaceStyle == .dark
                        ? UIColor.secondarySystemGroupedBackground
                        : UIColor.white
                }
            case .eyeCare:
                return UIColor { trait in
                    trait.userInterfaceStyle == .dark
                        ? UIColor(red: 0.12, green: 0.16, blue: 0.12, alpha: 1)
                        : UIColor(red: 0.94, green: 0.97, blue: 0.90, alpha: 1)
                }
            case .xiaohongshu:
                return UIColor { trait in
                    trait.userInterfaceStyle == .dark
                        ? UIColor(red: 0.18, green: 0.11, blue: 0.12, alpha: 1)
                        : UIColor(red: 1.0, green: 0.96, blue: 0.96, alpha: 1)
                }
            case .telegram:
                return UIColor { trait in
                    trait.userInterfaceStyle == .dark
                        ? UIColor(red: 0.07, green: 0.09, blue: 0.12, alpha: 1) // list row surface
                        : UIColor.white
                }
            case .weChat:
                return UIColor { trait in
                    trait.userInterfaceStyle == .dark
                        ? UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1) // near pure black
                        : UIColor.white
                }
            }
        }

        var mutedContentBackgroundColor: UIColor {
            switch self {
            case .systemDefault:
                return UIColor { trait in
                    trait.userInterfaceStyle == .dark
                        ? UIColor.tertiarySystemGroupedBackground
                        : UIColor.systemGroupedBackground
                }
            case .eyeCare:
                return UIColor { trait in
                    trait.userInterfaceStyle == .dark
                        ? UIColor(red: 0.09, green: 0.12, blue: 0.09, alpha: 1)
                        : UIColor(red: 0.90, green: 0.94, blue: 0.85, alpha: 1)
                }
            case .xiaohongshu:
                return UIColor { trait in
                    trait.userInterfaceStyle == .dark
                        ? UIColor(red: 0.12, green: 0.08, blue: 0.09, alpha: 1)
                        : UIColor(red: 0.97, green: 0.94, blue: 0.94, alpha: 1)
                }
            case .telegram:
                return UIColor { trait in
                    trait.userInterfaceStyle == .dark
                        ? UIColor(red: 0.055, green: 0.086, blue: 0.129, alpha: 1) // #0E1621
                        : UIColor(red: 0.94, green: 0.95, blue: 0.96, alpha: 1)
                }
            case .weChat:
                return UIColor { trait in
                    trait.userInterfaceStyle == .dark
                        ? UIColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1)
                        : UIColor(red: 0.93, green: 0.93, blue: 0.93, alpha: 1) // #EDEDED-ish
                }
            }
        }

        /// Tab / navigation bar surface for themes that prefer opaque chrome.
        var chromeBackgroundColor: UIColor {
            switch self {
            case .weChat:
                return UIColor { trait in
                    trait.userInterfaceStyle == .dark
                        ? UIColor(red: 0.11, green: 0.11, blue: 0.11, alpha: 1)
                        : UIColor(red: 0.97, green: 0.97, blue: 0.97, alpha: 1) // WeChat light chrome gray
                }
            case .telegram:
                return UIColor { trait in
                    trait.userInterfaceStyle == .dark
                        ? UIColor(red: 0.10, green: 0.13, blue: 0.16, alpha: 1)
                        : UIColor(red: 0.96, green: 0.97, blue: 0.98, alpha: 1)
                }
            case .systemDefault, .eyeCare, .xiaohongshu:
                return contentBackgroundColor
            }
        }

        var webAccentHex: String {
            switch self {
            case .systemDefault: return "#0079d3"
            case .eyeCare: return "#3d8c56"
            case .xiaohongshu: return "#eb3349"
            case .telegram: return "#3390EC"
            case .weChat: return "#07C160"
            }
        }

        var webBackgroundHex: String {
            switch self {
            case .systemDefault: return "transparent"
            case .eyeCare: return "#f0f7e7"
            case .xiaohongshu: return "#fff5f5"
            case .telegram: return "#c8d9e8"
            case .weChat: return "#ffffff"
            }
        }

        var webMutedBackgroundHex: String {
            switch self {
            case .systemDefault: return "#f6f8ff"
            case .eyeCare: return "#e3efd7"
            case .xiaohongshu: return "#ffe8eb"
            case .telegram: return "#e8f4fc"
            case .weChat: return "#ededed"
            }
        }

        var webQuoteBorderHex: String {
            switch self {
            case .systemDefault: return "#cccccc"
            case .eyeCare, .xiaohongshu, .telegram, .weChat: return webAccentHex
            }
        }

        var webBlockquoteBackgroundHex: String {
            switch self {
            case .systemDefault: return "transparent"
            case .eyeCare, .xiaohongshu, .telegram, .weChat: return webMutedBackgroundHex
            }
        }

        private var topicTagPalette: [UIColor] {
            switch self {
            case .systemDefault:
                return [.systemBlue, .systemGreen, .systemOrange, .systemPink, .systemPurple, .systemTeal, .systemIndigo]
            case .eyeCare:
                return [
                    UIColor(red: 0.19, green: 0.48, blue: 0.29, alpha: 1),
                    UIColor(red: 0.45, green: 0.60, blue: 0.25, alpha: 1),
                    UIColor(red: 0.33, green: 0.55, blue: 0.42, alpha: 1),
                ]
            case .xiaohongshu:
                return [
                    UIColor(red: 0.92, green: 0.13, blue: 0.22, alpha: 1),
                    UIColor(red: 1.0, green: 0.50, blue: 0.36, alpha: 1),
                    UIColor(red: 0.25, green: 0.68, blue: 0.46, alpha: 1),
                    UIColor(red: 0.21, green: 0.62, blue: 0.82, alpha: 1),
                    UIColor(red: 0.92, green: 0.58, blue: 0.17, alpha: 1),
                ]
            case .telegram:
                return [
                    UIColor(red: 0.13, green: 0.55, blue: 0.82, alpha: 1),
                    UIColor(red: 0.0, green: 0.47, blue: 0.74, alpha: 1),
                    UIColor(red: 0.27, green: 0.66, blue: 0.90, alpha: 1),
                ]
            case .weChat:
                return [
                    UIColor(red: 0.027, green: 0.757, blue: 0.376, alpha: 1), // green
                    UIColor(red: 0.10, green: 0.64, blue: 0.62, alpha: 1), // teal
                    UIColor(red: 0.20, green: 0.55, blue: 0.90, alpha: 1), // blue
                    UIColor(red: 0.98, green: 0.62, blue: 0.15, alpha: 1), // amber
                    UIColor(red: 0.45, green: 0.50, blue: 0.55, alpha: 1), // blue-gray
                ]
            }
        }

        private var topicCategoryPalette: [UIColor] {
            switch self {
            case .systemDefault:
                return topicTagPalette
            case .eyeCare:
                return [
                    UIColor(red: 0.19, green: 0.48, blue: 0.29, alpha: 1),
                    UIColor(red: 0.45, green: 0.60, blue: 0.25, alpha: 1),
                    UIColor(red: 0.33, green: 0.55, blue: 0.42, alpha: 1),
                ]
            case .xiaohongshu:
                return [
                    UIColor(red: 0.92, green: 0.13, blue: 0.22, alpha: 1),
                    UIColor(red: 1.0, green: 0.50, blue: 0.36, alpha: 1),
                    UIColor(red: 0.25, green: 0.68, blue: 0.46, alpha: 1),
                    UIColor(red: 0.21, green: 0.62, blue: 0.82, alpha: 1),
                    UIColor(red: 0.92, green: 0.58, blue: 0.17, alpha: 1),
                ]
            case .telegram:
                return [
                    UIColor(red: 0.13, green: 0.55, blue: 0.82, alpha: 1),
                    UIColor(red: 0.0, green: 0.47, blue: 0.74, alpha: 1),
                    UIColor(red: 0.27, green: 0.66, blue: 0.90, alpha: 1),
                ]
            case .weChat:
                return [
                    UIColor(red: 0.027, green: 0.757, blue: 0.376, alpha: 1),
                    UIColor(red: 0.05, green: 0.62, blue: 0.32, alpha: 1),
                    UIColor(red: 0.15, green: 0.70, blue: 0.55, alpha: 1),
                    UIColor(red: 0.30, green: 0.55, blue: 0.85, alpha: 1),
                ]
            }
        }

        private func paletteColor(for seed: String, palette: [UIColor]) -> UIColor {
            guard !palette.isEmpty else { return accentColor }
            let hash = seed.unicodeScalars.reduce(UInt64(0)) { ($0 &* 31) &+ UInt64($1.value) }
            return palette[Int(hash % UInt64(palette.count))]
        }
    }

    enum AppIconStyle: String, CaseIterable {
        case primary
        case purple = "AppIconPurple"
        case green = "AppIconGreen"
        case orange = "AppIconOrange"
        case dark = "AppIconDark"
        case red = "AppIconRed"
        case white = "AppIconWhite"

        var alternateIconName: String? {
            self == .primary ? nil : rawValue
        }

        var title: String {
            switch self {
            case .primary:
                return String(localized: "settings.app_icon.default")
            case .purple:
                return String(localized: "settings.app_icon.purple", defaultValue: "魅影紫")
            case .green:
                return String(localized: "settings.app_icon.green", defaultValue: "翡翠绿")
            case .orange:
                return String(localized: "settings.app_icon.orange", defaultValue: "暖阳橙")
            case .dark:
                return String(localized: "settings.app_icon.dark", defaultValue: "暗夜黑")
            case .red:
                return String(localized: "settings.app_icon.red", defaultValue: "绯红色")
            case .white:
                return String(localized: "settings.app_icon.white", defaultValue: "珍珠白")
            }
        }

        var previewImage: UIImage? {
            switch self {
            case .primary:
                return UIImage(named: "AppIcon") ?? UIImage(named: "AppIconOriginal")
            default:
                return UIImage(named: rawValue)
            }
        }
    }

    var appearanceMode: AppearanceMode {
        get { AppearanceMode(rawValue: defaults.integer(forKey: "appearanceMode")) ?? .system }
        set {
            defaults.set(newValue.rawValue, forKey: "appearanceMode")
            applyAppearance()
            notifyChanged()
        }
    }

    var appLanguage: AppLanguage {
        get {
            guard let rawValue = defaults.string(forKey: "appLanguage") else {
                return .simplifiedChinese
            }
            return AppLanguage.storedValue(rawValue) ?? .simplifiedChinese
        }
        set {
            defaults.set(newValue.rawValue, forKey: "appLanguage")
            defaults.set(newValue.preferredLanguageCodes, forKey: "AppleLanguages")
            RuntimeLanguageBundle.shared.apply(language: newValue)
            notifyChanged()
        }
    }

    var themeStyle: ThemeStyle {
        // Read from cross-thread cache. DiffableDataSource applies on
        // `com.apple.uikit.datasource.diffing` and used to call
        // defaults.integer(forKey:) via MainActor AppSettings — recursive
        // executor/settings re-entry → EXC_BAD_ACCESS code=2.
        get { AppSettingsRuntimeCache.themeStyle }
        set {
            defaults.set(newValue.rawValue, forKey: "themeStyle")
            AppSettingsRuntimeCache.update { $0.themeStyleRaw = newValue.rawValue }
            applyAppearance()
            notifyChanged()
        }
    }

    var pluginDockEnabled: Bool {
        get { bool(forKey: "pluginDockEnabled", defaultValue: true) }
        set {
            defaults.set(newValue, forKey: "pluginDockEnabled")
            notifyChanged()
        }
    }

    var miniProgramsEnabled: Bool {
        get {
            if defaults.object(forKey: "miniProgramsEnabled") != nil {
                return defaults.bool(forKey: "miniProgramsEnabled")
            }
            return bool(forKey: "pluginDockEnabled", defaultValue: true)
        }
        set {
            guard miniProgramsEnabled != newValue else { return }
            defaults.set(newValue, forKey: "miniProgramsEnabled")
            notifyChanged()
        }
    }

    /// FluxDo 风格：左缘右滑打开分类/标签侧栏。关闭时保持现有分类 tab + 下拉菜单。
    var homeCategoryDrawerSwipeEnabled: Bool {
        get { bool(forKey: "homeCategoryDrawerSwipeEnabled", defaultValue: false) }
        set {
            defaults.set(newValue, forKey: "homeCategoryDrawerSwipeEnabled")
            notifyChanged()
        }
    }

    var autoCheckForUpdates: Bool {
        get { bool(forKey: "autoCheckForUpdates", defaultValue: true) }
        set {
            guard autoCheckForUpdates != newValue else { return }
            defaults.set(newValue, forKey: "autoCheckForUpdates")
            notifyChanged()
        }
    }

    var pluginDockSide: PluginDockSide {
        get {
            defaults.string(forKey: "pluginDockSide").flatMap(PluginDockSide.init(rawValue:)) ?? .right
        }
        set {
            guard pluginDockSide != newValue else { return }
            defaults.set(newValue.rawValue, forKey: "pluginDockSide")
            notifyChanged()
        }
    }

    var pluginDockVerticalPosition: Double {
        get {
            guard defaults.object(forKey: "pluginDockVerticalPosition") != nil else { return 0.72 }
            return Self.normalizedPluginDockVerticalPosition(defaults.double(forKey: "pluginDockVerticalPosition"))
        }
        set {
            let value = Self.normalizedPluginDockVerticalPosition(newValue)
            guard abs(pluginDockVerticalPosition - value) > 0.0001 else { return }
            defaults.set(value, forKey: "pluginDockVerticalPosition")
            notifyChanged()
        }
    }

    private static func normalizedPluginDockVerticalPosition(_ value: Double) -> Double {
        guard value.isFinite else { return 0.72 }
        return min(max(value, 0), 1)
    }

    var xiaohongshuCardsStaggered: Bool {
        get { bool(forKey: "xiaohongshuCardsStaggered", defaultValue: false) }
        set {
            defaults.set(newValue, forKey: "xiaohongshuCardsStaggered")
            notifyChanged()
        }
    }

    /// When the active theme supports chat Topic Detail (WeChat / Telegram), whether to
    /// actually open the chat-bubble surface. Default **on** (theme-matched). Off → classic
    /// `TopicDetailViewController`. Ignored for non-chat themes.
    var chatTopicDetailEnabled: Bool {
        get {
            guard themeStyle.usesChatTopicDetail else { return false }
            return bool(forKey: "chatTopicDetailEnabled", defaultValue: true)
        }
        set {
            defaults.set(newValue, forKey: "chatTopicDetailEnabled")
            notifyChanged()
        }
    }

    /// Effective Topic Detail surface: theme capability ∧ user preference.
    var prefersChatTopicDetail: Bool {
        themeStyle.usesChatTopicDetail && chatTopicDetailEnabled
    }

    /// When true, category/tag chips use the active theme palettes.
    /// When false, keep Discourse/default colors (same as the default theme path).
    var themeTaxonomyColorsEnabled: Bool {
        get { bool(forKey: "themeTaxonomyColorsEnabled", defaultValue: true) }
        set {
            defaults.set(newValue, forKey: "themeTaxonomyColorsEnabled")
            notifyChanged()
        }
    }

    var appIconStyle: AppIconStyle {
        get {
            if let activeName = UIApplication.shared.alternateIconName,
               let active = AppIconStyle(rawValue: activeName) {
                return active
            }
            guard let storedValue = defaults.string(forKey: "appIconStyle") else {
                return .primary
            }
            return AppIconStyle(rawValue: storedValue) ?? .primary
        }
    }

    func setAppIconStyle(_ style: AppIconStyle, completion: ((Error?) -> Void)? = nil) {
        let applyStoredValue = {
            self.defaults.set(style.rawValue, forKey: "appIconStyle")
            self.notifyChanged()
            completion?(nil)
        }

        guard style != appIconStyle else {
            completion?(nil)
            return
        }

        guard UIApplication.shared.supportsAlternateIcons else {
            completion?(AppIconChangeError.unsupported)
            return
        }

        UIApplication.shared.setAlternateIconName(style.alternateIconName) { error in
            Task { @MainActor in
                if let error {
                    completion?(error)
                    return
                }
                applyStoredValue()
            }
        }
    }

    enum AppIconChangeError: LocalizedError {
        case unsupported

        var errorDescription: String? {
            switch self {
            case .unsupported:
                return String(localized: "settings.app_icon.unsupported")
            }
        }
    }

    func applyAppearance() {
        let style = appearanceMode.userInterfaceStyle
        let theme = themeStyle
        let tintColor = theme.accentColor
        UINavigationBar.appearance().tintColor = tintColor
        UITabBar.appearance().tintColor = tintColor

        // Option B: WeChat prefers opaque gray chrome instead of iOS blur glass.
        let navAppearance = UINavigationBarAppearance()
        if theme.prefersOpaqueChrome {
            navAppearance.configureWithOpaqueBackground()
            // UINavigationBarAppearance color is not animatable via UIViewPropertyAnimator;
            // live bars are refreshed below after appearance is reassigned.
            navAppearance.backgroundColor = theme.chromeBackgroundColor
            navAppearance.shadowColor = UIColor.separator.withAlphaComponent(0.28)
        } else {
            navAppearance.configureWithDefaultBackground()
        }
        navAppearance.titleTextAttributes = [.foregroundColor: UIColor.label]
        navAppearance.largeTitleTextAttributes = [.foregroundColor: UIColor.label]
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
        UINavigationBar.appearance().compactAppearance = navAppearance
        UINavigationBar.appearance().isTranslucent = !theme.prefersOpaqueChrome

        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = style
                window.tintColor = tintColor
                // Re-apply live nav bars already on screen.
                if let nav = window.rootViewController as? UINavigationController {
                    applyNavigationChrome(nav.navigationBar, theme: theme)
                }
                window.rootViewController?.children.forEach { child in
                    if let nav = child as? UINavigationController {
                        applyNavigationChrome(nav.navigationBar, theme: theme)
                    }
                    if let tab = child as? UITabBarController {
                        (tab as? ForumTabBarController)?.configureTabBarSurface()
                        tab.viewControllers?.forEach { vc in
                            if let nav = vc as? UINavigationController {
                                applyNavigationChrome(nav.navigationBar, theme: theme)
                            }
                        }
                    }
                }
            }
        }
        refreshVisibleAppFonts()
    }

    private func applyNavigationChrome(_ navigationBar: UINavigationBar, theme: ThemeStyle) {
        let appearance = UINavigationBarAppearance()
        if theme.prefersOpaqueChrome {
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = theme.chromeBackgroundColor
            appearance.shadowColor = UIColor.separator.withAlphaComponent(0.28)
        } else {
            appearance.configureWithDefaultBackground()
        }
        appearance.titleTextAttributes = [.foregroundColor: UIColor.label]
        appearance.largeTitleTextAttributes = [.foregroundColor: UIColor.label]
        navigationBar.standardAppearance = appearance
        navigationBar.scrollEdgeAppearance = appearance
        navigationBar.compactAppearance = appearance
        navigationBar.tintColor = theme.accentColor
        navigationBar.isTranslucent = !theme.prefersOpaqueChrome
    }

    func applyLanguage() {
        RuntimeLanguageBundle.shared.apply(language: appLanguage)
    }
}
