import ObjectiveC
import CoreText
import UIKit

/// Cross-thread snapshot for hot reads (UITableView diffing queue, UIFont swizzle).
/// Never hop to MainActor `AppSettings.shared` from those paths — that re-entered
/// settings getters and blew the stack (EXC_BAD_ACCESS code=2 on integer(forKey:)).
enum AppSettingsRuntimeCache {
    struct Snapshot: Sendable {
        var themeStyleRaw: Int = 0
        var appearanceModeRaw: Int = 0
        var interfaceFontScalePercent: Int = AppSettings.defaultInterfaceFontScalePercent
        var contentFontScopeRaw: Int = 0
        var globalFontPostScriptName: String?
    }

    nonisolated private static let lock = NSLock()
    nonisolated(unsafe) private static var snapshot = Snapshot()
    nonisolated(unsafe) private static var isSeeded = false

    nonisolated static var current: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    nonisolated static func replace(_ value: Snapshot) {
        lock.lock()
        snapshot = value
        isSeeded = true
        lock.unlock()
    }

    nonisolated static func update(_ body: (inout Snapshot) -> Void) {
        lock.lock()
        body(&snapshot)
        isSeeded = true
        lock.unlock()
    }

    nonisolated static var hasSeed: Bool {
        lock.lock(); defer { lock.unlock() }
        return isSeeded
    }

    nonisolated static var themeStyle: AppSettings.ThemeStyle {
        AppSettings.ThemeStyle(rawValue: current.themeStyleRaw) ?? .systemDefault
    }

    nonisolated static var interfaceFontScaleMultiplier: CGFloat {
        let percent = current.interfaceFontScalePercent
        return AppSettings.interfaceFontDefaultVisualMultiplier
            * CGFloat(percent)
            / CGFloat(AppSettings.defaultInterfaceFontScalePercent)
    }

    nonisolated static func interfaceFont(
        ofSize pointSize: CGFloat,
        weight: UIFont.Weight,
        fallback: UIFont
    ) -> UIFont {
        let snap = current
        let scaled = max(pointSize * interfaceFontScaleMultiplier, 1)
        // ContentFontScope.global.rawValue == 1
        if snap.contentFontScopeRaw == 1,
           let name = snap.globalFontPostScriptName,
           !name.isEmpty,
           let font = UIFont(name: name, size: scaled) {
            return font.applying(weight: weight).doerMarkAppFontSourcePointSize(pointSize)
        }
        return UIFont.doerOriginalSystemFont(ofSize: scaled, weight: weight)
            .doerMarkAppFontSourcePointSize(pointSize)
    }

    nonisolated static func interfaceFont(matching font: UIFont) -> UIFont {
        guard !font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) else {
            return font
        }
        let sourcePointSize = font.doerAppFontSourcePointSize ?? font.pointSize
        let pointSize = max(sourcePointSize * interfaceFontScaleMultiplier, 1)
        let weight = font.doerDetectedWeight
        let traits = font.fontDescriptor.symbolicTraits
        let snap = current
        let baseFont: UIFont
        if snap.contentFontScopeRaw == 1,
           let name = snap.globalFontPostScriptName,
           !name.isEmpty,
           let custom = UIFont(name: name, size: pointSize) {
            baseFont = custom.applying(weight: weight)
        } else {
            baseFont = UIFont.doerOriginalSystemFont(ofSize: pointSize, weight: weight)
        }
        guard traits.contains(.traitItalic),
              let descriptor = baseFont.fontDescriptor.withSymbolicTraits(
                baseFont.fontDescriptor.symbolicTraits.union(.traitItalic)
              )
        else {
            return baseFont.doerMarkAppFontSourcePointSize(sourcePointSize)
        }
        return UIFont(descriptor: descriptor, size: pointSize)
            .doerMarkAppFontSourcePointSize(sourcePointSize)
    }
}

final class AppSettings: DoerObservableObject {
    /// Font swizzles read this without touching `shared` during singleton creation.
    nonisolated(unsafe) private static var isCreatingShared = false
    nonisolated(unsafe) private static var sharedInstanceHint: AppSettings?

    /// True only after `shared` finished initializing.
    nonisolated static var isSharedAvailable: Bool {
        !isCreatingShared && sharedInstanceHint != nil
    }

    static let shared: AppSettings = {
        isCreatingShared = true
        defer { isCreatingShared = false }
        return AppSettings()
    }()
    nonisolated static let topicTitleReferencePointSize: CGFloat = 15
    nonisolated static let minimumFontScalePercent = 30
    nonisolated static let maximumFontScalePercent = 150
    nonisolated static let fontScaleStepPercent = 5
    nonisolated static let defaultFontScalePercent = 100
    nonisolated static let defaultInterfaceFontScalePercent = 100
    nonisolated static let legacyInterfaceFontDefaultPercent = 85
    /// Default visual size for a 15pt source interface label. Deliberately kept
    /// independent from `ContentFontSize.standard.basePointSize`: the official app
    /// keeps menus/buttons on the system size and only scales the reading text.
    nonisolated static let interfaceFontDefaultVisualPointSize: CGFloat = 13.94
    nonisolated static let interfaceFontReferencePointSize: CGFloat = 15
    nonisolated static let interfaceFontDefaultVisualMultiplier: CGFloat =
        interfaceFontDefaultVisualPointSize / interfaceFontReferencePointSize

    let defaults = UserDefaults.standard

    private override init() {
        super.init()
        // Seed cross-thread cache before any work that may touch UIFont/String.
        seedRuntimeCacheFromDefaults()
        migrateFontScaleSettingsIfNeeded()
        migrateLegacyCustomContentFontIfNeeded()
        registerStoredContentFonts()
        applyLanguage()
        publishRuntimeCache()
        // Publish only after init side-effects finish so UIFont overrides never
        // re-enter a half-built singleton (stack overflow / EXC_BAD_ACCESS).
        Self.sharedInstanceHint = self
    }

    override func notifyChanged() {
        publishRuntimeCache()
        super.notifyChanged()
    }

    /// Cheap defaults-only seed (safe during early init / any queue).
    private func seedRuntimeCacheFromDefaults() {
        var snap = AppSettingsRuntimeCache.Snapshot()
        snap.themeStyleRaw = defaults.integer(forKey: "themeStyle")
        snap.appearanceModeRaw = defaults.integer(forKey: "appearanceMode")
        if defaults.object(forKey: "interfaceFontScalePercent") != nil {
            snap.interfaceFontScalePercent = Self.normalizedFontScalePercent(
                defaults.integer(forKey: "interfaceFontScalePercent")
            )
        }
        if defaults.object(forKey: "contentFontScope") != nil {
            snap.contentFontScopeRaw = defaults.integer(forKey: "contentFontScope")
        }
        AppSettingsRuntimeCache.replace(snap)
    }

    /// Full snapshot including resolved global font name.
    func publishRuntimeCache() {
        var snap = AppSettingsRuntimeCache.Snapshot()
        snap.themeStyleRaw = defaults.integer(forKey: "themeStyle")
        snap.appearanceModeRaw = defaults.integer(forKey: "appearanceMode")
        snap.interfaceFontScalePercent = interfaceFontScalePercent
        snap.contentFontScopeRaw = contentFontScope.rawValue
        if contentFontScope == .global {
            snap.globalFontPostScriptName = activeFontName(for: contentFontFamily)
        } else {
            snap.globalFontPostScriptName = nil
        }
        AppSettingsRuntimeCache.replace(snap)
    }

    static func normalizedFontScalePercent(_ value: Int) -> Int {
        min(max(value, minimumFontScalePercent), maximumFontScalePercent)
    }

    private func migrateFontScaleSettingsIfNeeded() {
        if defaults.object(forKey: "contentFontScalePercent") == nil,
           defaults.object(forKey: "contentFontSize") != nil {
            let legacySize = ContentFontSize(rawValue: defaults.integer(forKey: "contentFontSize")) ?? .standard
            defaults.set(legacySize.legacyScalePercent, forKey: "contentFontScalePercent")
            defaults.set(ContentFontSize.standard.rawValue, forKey: "contentFontSize")
        }
        migrateInterfaceFontScaleBaselineIfNeeded()
    }

    private func migrateInterfaceFontScaleBaselineIfNeeded() {
        let migrationKey = "interfaceFontScaleBaselineV2"
        guard !defaults.bool(forKey: migrationKey) else { return }
        if defaults.object(forKey: "interfaceFontScalePercent") != nil {
            let oldValue = Self.normalizedFontScalePercent(defaults.integer(forKey: "interfaceFontScalePercent"))
            let migratedValue = Int((CGFloat(oldValue) / CGFloat(Self.legacyInterfaceFontDefaultPercent) * CGFloat(Self.defaultInterfaceFontScalePercent)).rounded())
            defaults.set(Self.normalizedFontScalePercent(migratedValue), forKey: "interfaceFontScalePercent")
        }
        defaults.set(true, forKey: migrationKey)
    }
}
