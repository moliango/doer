import UIKit
import ObjectiveC
import CoreText

// MARK: - Progress bar gestures (FluxDO-aligned)
extension AppSettings {

    var progressGesturesEnabled: Bool {
        get { bool(forKey: "progressGesturesEnabled", defaultValue: true) }
        set {
            defaults.set(newValue, forKey: "progressGesturesEnabled")
            notifyChanged()
        }
    }

    var progressGestureSwipeLeft: ProgressGestureAction {
        get {
            ProgressGestureSettings.decodeAction(
                defaults.string(forKey: "progressGestureSwipeLeft"),
                fallback: .nextPost
            )
        }
        set {
            defaults.set(newValue.rawValue, forKey: "progressGestureSwipeLeft")
            notifyChanged()
        }
    }

    var progressGestureSwipeRight: ProgressGestureAction {
        get {
            ProgressGestureSettings.decodeAction(
                defaults.string(forKey: "progressGestureSwipeRight"),
                fallback: .previousPost
            )
        }
        set {
            defaults.set(newValue.rawValue, forKey: "progressGestureSwipeRight")
            notifyChanged()
        }
    }

    var progressGestureSwipeUp: ProgressGestureAction {
        get {
            ProgressGestureSettings.decodeAction(
                defaults.string(forKey: "progressGestureSwipeUp"),
                fallback: .jumpToUnread
            )
        }
        set {
            defaults.set(newValue.rawValue, forKey: "progressGestureSwipeUp")
            notifyChanged()
        }
    }

    var progressGestureMenuActions: [ProgressGestureAction] {
        get {
            let raw = defaults.array(forKey: "progressGestureMenuActions") as? [String]
            let decoded = ProgressGestureSettings.decodeActions(
                raw,
                fallback: ProgressGestureAction.defaultMenuActions
            )
            return Array(decoded.prefix(ProgressGestureAction.menuMaxCount))
        }
        set {
            let capped = Array(newValue.filter { $0 != .none }.prefix(ProgressGestureAction.menuMaxCount))
            defaults.set(ProgressGestureSettings.encodeActions(capped), forKey: "progressGestureMenuActions")
            notifyChanged()
        }
    }

    var clipboardTopicLinkPromptEnabled: Bool {
        get { bool(forKey: "clipboardTopicLinkPromptEnabled", defaultValue: true) }
        set {
            defaults.set(newValue, forKey: "clipboardTopicLinkPromptEnabled")
            notifyChanged()
        }
    }

    var showUserSignatures: Bool {
        get { bool(forKey: "showUserSignatures", defaultValue: true) }
        set {
            defaults.set(newValue, forKey: "showUserSignatures")
            notifyChanged()
        }
    }

    var nestedReplyViewEnabled: Bool {
        get { bool(forKey: "nestedReplyViewEnabled", defaultValue: false) }
        set {
            defaults.set(newValue, forKey: "nestedReplyViewEnabled")
            notifyChanged()
        }
    }

    var showTopicCardExcerpt: Bool {
        get { bool(forKey: "showTopicCardExcerpt", defaultValue: false) }
        set {
            defaults.set(newValue, forKey: "showTopicCardExcerpt")
            notifyChanged()
        }
    }

    var showTopicCardTags: Bool {
        get { bool(forKey: "showTopicCardTags", defaultValue: true) }
        set {
            defaults.set(newValue, forKey: "showTopicCardTags")
            notifyChanged()
        }
    }

    var showTopicCardCategory: Bool {
        get { bool(forKey: "showTopicCardCategory", defaultValue: true) }
        set {
            defaults.set(newValue, forKey: "showTopicCardCategory")
            notifyChanged()
        }
    }

    var showTopicCardCounts: Bool {
        get { bool(forKey: "showTopicCardCounts", defaultValue: true) }
        set {
            defaults.set(newValue, forKey: "showTopicCardCounts")
            notifyChanged()
        }
    }

    var defaultExpandRelatedLinks: Bool {
        get { defaults.bool(forKey: "defaultExpandRelatedLinks") }
        set {
            defaults.set(newValue, forKey: "defaultExpandRelatedLinks")
            notifyChanged()
        }
    }

    /// FluxDo: show suggested/related topics at the end of a thread.
    var showSuggestedTopics: Bool {
        get { bool(forKey: "showSuggestedTopics", defaultValue: true) }
        set {
            defaults.set(newValue, forKey: "showSuggestedTopics")
            notifyChanged()
        }
    }

    /// FluxDo-style instant markdown chrome while typing in composers.
    var composerInstantRender: Bool {
        get { bool(forKey: "composerInstantRender", defaultValue: false) }
        set {
            defaults.set(newValue, forKey: "composerInstantRender")
            notifyChanged()
        }
    }

    /// Experimental block WYSIWYG in the reply composer. Default off; existing Aa/MD path stays unchanged.
    var experimentalRichComposerEnabled: Bool {
        get { bool(forKey: "experimentalRichComposerEnabled", defaultValue: true) }
        set {
            defaults.set(newValue, forKey: "experimentalRichComposerEnabled")
            notifyChanged()
        }
    }

    /// Insert spaces between CJK and Latin/digits on composer send and preview.
    var autoPanguSpacing: Bool {
        get { bool(forKey: "autoPanguSpacing", defaultValue: true) }
        set {
            defaults.set(newValue, forKey: "autoPanguSpacing")
            notifyChanged()
        }
    }

    var customListBackgroundEnabled: Bool {
        get { defaults.bool(forKey: "customListBackgroundEnabled") }
        set {
            defaults.set(newValue, forKey: "customListBackgroundEnabled")
            notifyChanged()
        }
    }

    var githubProxyPrefix: String {
        get { defaults.string(forKey: "githubProxyPrefix") ?? "" }
        set {
            defaults.set(GitHubProxy.normalize(newValue), forKey: "githubProxyPrefix")
            notifyChanged()
        }
    }

    enum ContentFontSize: Int, CaseIterable {
        case small = 0
        case standard = 1
        case large = 2
        case extraLarge = 3

        var title: String {
            switch self {
            case .small: return String(localized: "settings.content_font.small")
            case .standard: return String(localized: "settings.content_font.standard")
            case .large: return String(localized: "settings.content_font.large")
            case .extraLarge: return String(localized: "settings.content_font.extra_large")
            }
        }

        nonisolated var basePointSize: CGFloat {
            switch self {
            case .small: return 13.67
            case .standard: return 13.94
            case .large: return 15.92
            case .extraLarge: return 17.17
            }
        }

        var legacyScalePercent: Int {
            switch self {
            case .small: return 90
            case .standard: return 100
            case .large: return 110
            case .extraLarge: return 120
            }
        }
    }

    enum ContentFontFamily: String, CaseIterable {
        case system
        case miSans
        case custom

        var title: String {
            switch self {
            case .system: return String(localized: "settings.font.system")
            case .miSans: return "MiSans"
            case .custom: return String(localized: "settings.font.custom")
            }
        }
    }

    enum ContentFontScope: Int, CaseIterable {
        case readingOnly = 0
        case global = 1
    }

    var contentFontSize: ContentFontSize {
        get {
            guard defaults.object(forKey: "contentFontSize") != nil else {
                return .standard
            }
            return ContentFontSize(rawValue: defaults.integer(forKey: "contentFontSize")) ?? .standard
        }
        set {
            defaults.set(newValue.rawValue, forKey: "contentFontSize")
            notifyChanged()
        }
    }

    var contentFontScalePercent: Int {
        get {
            guard defaults.object(forKey: "contentFontScalePercent") != nil else {
                return Self.defaultFontScalePercent
            }
            return Self.normalizedFontScalePercent(defaults.integer(forKey: "contentFontScalePercent"))
        }
        set {
            defaults.set(Self.normalizedFontScalePercent(newValue), forKey: "contentFontScalePercent")
            notifyChanged()
        }
    }

    var interfaceFontScalePercent: Int {
        get {
            guard defaults.object(forKey: "interfaceFontScalePercent") != nil else {
                return Self.defaultInterfaceFontScalePercent
            }
            return Self.normalizedFontScalePercent(defaults.integer(forKey: "interfaceFontScalePercent"))
        }
        set {
            let previousMultiplier = interfaceFontScaleMultiplier
            defaults.set(Self.normalizedFontScalePercent(newValue), forKey: "interfaceFontScalePercent")
            publishRuntimeCache()
            refreshVisibleAppFonts(previousInterfaceFontScaleMultiplier: previousMultiplier)
            notifyChanged()
        }
    }

    var contentFontFamily: ContentFontFamily {
        get {
            guard let rawValue = defaults.string(forKey: "contentFontFamily") else {
                return .system
            }
            return ContentFontFamily(rawValue: rawValue) ?? .system
        }
        set {
            if newValue == .custom,
               selectedImportedCustomContentFont == nil,
               let firstFont = importedCustomContentFonts.first {
                defaults.set(firstFont.id, forKey: selectedImportedContentFontIdKey)
            }
            defaults.set(newValue.rawValue, forKey: "contentFontFamily")
            refreshVisibleAppFonts()
            notifyChanged()
        }
    }

    var contentFontScope: ContentFontScope {
        get {
            guard defaults.object(forKey: "contentFontScope") != nil else {
                return .readingOnly
            }
            return ContentFontScope(rawValue: defaults.integer(forKey: "contentFontScope")) ?? .readingOnly
        }
        set {
            defaults.set(newValue.rawValue, forKey: "contentFontScope")
            refreshVisibleAppFonts()
            notifyChanged()
        }
    }

    var customContentFontDisplayName: String? {
        selectedImportedCustomContentFont?.displayName
            ?? defaults.string(forKey: contentFontDisplayNameKey(for: .custom))
    }

    var miSansContentFontDisplayName: String? {
        defaults.string(forKey: contentFontDisplayNameKey(for: .miSans))
    }

    var importedCustomContentFonts: [ImportedContentFont] {
        storedImportedCustomFonts().filter { importedFontFileExists($0) }
    }

    var selectedImportedCustomContentFont: ImportedContentFont? {
        let fonts = importedCustomContentFonts
        guard !fonts.isEmpty else { return nil }
        if let selectedId = defaults.string(forKey: selectedImportedContentFontIdKey),
           let selectedFont = fonts.first(where: { $0.id == selectedId }) {
            return selectedFont
        }
        return fonts.first
    }

    func contentFontSubtitle(for family: ContentFontFamily) -> String {
        switch family {
        case .system:
            return String(localized: "settings.font.system.subtitle")
        case .miSans:
            if isContentFontFamilyAvailable(.miSans) {
                return miSansContentFontDisplayName ?? String(localized: "settings.font.misans.subtitle")
            }
            return String(localized: "settings.font.misans.need_upload")
        case .custom:
            if let name = customContentFontDisplayName {
                return String(format: String(localized: "settings.font.custom.imported"), name)
            }
            return String(localized: "settings.font.custom.subtitle")
        }
    }

    func importedCustomContentFontSubtitle(for font: ImportedContentFont) -> String {
        if selectedImportedCustomContentFont?.id == font.id, contentFontFamily == .custom {
            return String(localized: "settings.font.custom.selected")
        }
        return String(localized: "settings.font.custom.available")
    }

    func selectImportedContentFont(id: String) {
        guard importedCustomContentFonts.contains(where: { $0.id == id }) else { return }
        defaults.set(id, forKey: selectedImportedContentFontIdKey)
        contentFontFamily = .custom
    }

    func isContentFontFamilyAvailable(_ family: ContentFontFamily) -> Bool {
        switch family {
        case .system:
            return true
        case .miSans:
            return activeFontName(for: .miSans) != nil
        case .custom:
            return activeFontName(for: .custom) != nil
        }
    }

    func contentFont(ofSize pointSize: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        guard let fontName = activeFontName(for: contentFontFamily),
              let font = UIFont(name: fontName, size: pointSize)
        else {
            return UIFont.doerOriginalSystemFont(ofSize: pointSize, weight: weight)
        }
        return font.applying(weight: weight)
    }

    func effectiveContentPointSize(for pointSize: CGFloat) -> CGFloat {
        let scale = CGFloat(contentFontScalePercent) / CGFloat(Self.defaultFontScalePercent)
        return max(pointSize * scale, 1)
    }

    func effectiveInterfacePointSize(for pointSize: CGFloat) -> CGFloat {
        guard activeGlobalAppFontName() == nil else {
            return pointSize
        }
        if pointSize >= 20 {
            return max(pointSize - 4, 11)
        }
        if pointSize >= 16 {
            return max(pointSize - 3, 11)
        }
        if pointSize >= 13 {
            return max(pointSize - 1.5, 11)
        }
        return pointSize
    }

    func sourceInterfacePointSize(matchingEffectivePointSize effectivePointSize: CGFloat) -> CGFloat {
        var bestPointSize = effectivePointSize
        var bestDelta = CGFloat.greatestFiniteMagnitude
        var candidate = max(effectivePointSize, 11)
        let upperBound = effectivePointSize + 6
        while candidate <= upperBound {
            let delta = abs(effectiveInterfacePointSize(for: candidate) - effectivePointSize)
            if delta < bestDelta {
                bestDelta = delta
                bestPointSize = candidate
            }
            candidate += 0.5
        }
        return bestPointSize
    }

    func contentMonospacedFont(ofSize pointSize: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        .monospacedSystemFont(ofSize: pointSize, weight: weight)
    }

    var webContentFontFamilyCSS: String {
        guard let fontName = activeFontName(for: contentFontFamily) else {
            return "-apple-system, BlinkMacSystemFont, sans-serif"
        }
        let escapedName = fontName.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escapedName)\", -apple-system, BlinkMacSystemFont, sans-serif"
    }

    func installGlobalFontSupport() {
        UIFont.installDoerAppFontOverride()
        refreshVisibleAppFonts()
    }

    func appInterfaceFont(ofSize pointSize: CGFloat, weight: UIFont.Weight, fallback: UIFont) -> UIFont {
        let scaledPointSize = scaledInterfacePointSize(for: pointSize)
        guard let fontName = activeGlobalAppFontName(),
              let font = UIFont(name: fontName, size: scaledPointSize)
        else {
            return UIFont.doerOriginalSystemFont(ofSize: scaledPointSize, weight: weight)
                .doerMarkAppFontSourcePointSize(pointSize)
        }
        return font.applying(weight: weight).doerMarkAppFontSourcePointSize(pointSize)
    }

    func appInterfaceFont(matching font: UIFont) -> UIFont {
        guard !font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) else {
            return font
        }

        let sourcePointSize = font.doerAppFontSourcePointSize ?? font.pointSize
        let pointSize = scaledInterfacePointSize(for: sourcePointSize)
        let weight = font.doerDetectedWeight
        let traits = font.fontDescriptor.symbolicTraits
        let baseFont: UIFont
        if let fontName = activeGlobalAppFontName(),
           let customFont = UIFont(name: fontName, size: pointSize) {
            baseFont = customFont.applying(weight: weight)
        } else {
            baseFont = UIFont.doerOriginalSystemFont(ofSize: pointSize, weight: weight)
        }

        guard traits.contains(.traitItalic),
              let descriptor = baseFont.fontDescriptor.withSymbolicTraits(baseFont.fontDescriptor.symbolicTraits.union(.traitItalic))
        else {
            return baseFont.doerMarkAppFontSourcePointSize(sourcePointSize)
        }
        return UIFont(descriptor: descriptor, size: pointSize).doerMarkAppFontSourcePointSize(sourcePointSize)
    }

    func tabBarItemFont(selected: Bool) -> UIFont {
        UIFont.doerOriginalSystemFont(ofSize: 10, weight: selected ? .semibold : .regular)
    }

    func activeGlobalAppFontName() -> String? {
        guard contentFontScope == .global else { return nil }
        return activeFontName(for: contentFontFamily)
    }

    private var interfaceFontScaleMultiplier: CGFloat {
        Self.interfaceFontDefaultVisualMultiplier * CGFloat(interfaceFontScalePercent) / CGFloat(Self.defaultInterfaceFontScalePercent)
    }

    private func scaledInterfacePointSize(for pointSize: CGFloat) -> CGFloat {
        max(pointSize * interfaceFontScaleMultiplier, 1)
    }

    func refreshVisibleAppFonts(previousInterfaceFontScaleMultiplier: CGFloat? = nil) {
        let baseMultiplier = previousInterfaceFontScaleMultiplier ?? interfaceFontScaleMultiplier
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                refreshAppFonts(in: window, previousInterfaceFontScaleMultiplier: baseMultiplier)
                window.setNeedsLayout()
                window.layoutIfNeeded()
            }
        }
    }

    func refreshAppFonts(in view: UIView, previousInterfaceFontScaleMultiplier: CGFloat) {
        if view is UITabBar {
            return
        }
        if let label = view as? UILabel {
            label.font = appInterfaceFont(
                matching: baseInterfaceFont(
                    for: label,
                    currentFont: label.font,
                    previousInterfaceFontScaleMultiplier: previousInterfaceFontScaleMultiplier
                )
            )
            invalidateFontLayout(for: label)
        }
        if let button = view as? UIButton, let font = button.titleLabel?.font {
            button.titleLabel?.font = appInterfaceFont(
                matching: baseInterfaceFont(
                    for: button,
                    currentFont: font,
                    previousInterfaceFontScaleMultiplier: previousInterfaceFontScaleMultiplier
                )
            )
            if let titleLabel = button.titleLabel {
                invalidateFontLayout(for: titleLabel)
            }
            invalidateFontLayout(for: button)
        }
        if let textField = view as? UITextField, let font = textField.font {
            textField.font = appInterfaceFont(
                matching: baseInterfaceFont(
                    for: textField,
                    currentFont: font,
                    previousInterfaceFontScaleMultiplier: previousInterfaceFontScaleMultiplier
                )
            )
            invalidateFontLayout(for: textField)
        }
        if let textView = view as? UITextView,
           textView.attributedText.length == textView.text.count,
           let font = textView.font {
            textView.font = appInterfaceFont(
                matching: baseInterfaceFont(
                    for: textView,
                    currentFont: font,
                    previousInterfaceFontScaleMultiplier: previousInterfaceFontScaleMultiplier
                )
            )
            invalidateFontLayout(for: textView)
        }
        for subview in view.subviews {
            refreshAppFonts(in: subview, previousInterfaceFontScaleMultiplier: previousInterfaceFontScaleMultiplier)
        }
    }

    func baseInterfaceFont(
        for view: UIView,
        currentFont: UIFont,
        previousInterfaceFontScaleMultiplier: CGFloat
    ) -> UIFont {
        if let baseFont = view.doerBaseInterfaceFont {
            return baseFont
        }
        let safePreviousMultiplier = max(previousInterfaceFontScaleMultiplier, 0.01)
        let sourcePointSize = currentFont.doerAppFontSourcePointSize ?? (currentFont.pointSize / safePreviousMultiplier)
        let baseFont = UIFont(descriptor: currentFont.fontDescriptor, size: sourcePointSize)
        view.doerBaseInterfaceFont = baseFont
        return baseFont
    }

    func invalidateFontLayout(for view: UIView) {
        view.invalidateIntrinsicContentSize()
        view.setNeedsUpdateConstraints()
        view.setNeedsLayout()
        view.superview?.setNeedsUpdateConstraints()
        view.superview?.setNeedsLayout()
    }

    @discardableResult
    func importContentFont(from sourceURL: URL, targetFamily: ContentFontFamily) throws -> ImportedContentFont {
        guard targetFamily != .system else {
            throw ContentFontImportError.invalidFont
        }

        let allowedExtensions: Set<String> = ["ttf", "otf", "ttc"]
        guard allowedExtensions.contains(sourceURL.pathExtension.lowercased()) else {
            throw ContentFontImportError.unsupportedFileType
        }

        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let metadata = try fontMetadata(from: sourceURL)
        if targetFamily == .miSans, !metadata.matchesMiSans {
            throw ContentFontImportError.notMiSans
        }

        let directory = try contentFontsDirectory()
        let destination = directory.appendingPathComponent(
            targetFamily == .custom
                ? customFontFileName(metadata: metadata, sourceURL: sourceURL)
                : fontFileName(for: targetFamily, sourceURL: sourceURL)
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        try registerFont(at: destination)

        let importedFont = ImportedContentFont(
            id: metadata.postScriptName,
            postScriptName: metadata.postScriptName,
            displayName: metadata.displayName,
            fileName: destination.lastPathComponent,
            importedAt: Date()
        )

        defaults.set(destination.lastPathComponent, forKey: contentFontFileNameKey(for: targetFamily))
        defaults.set(metadata.postScriptName, forKey: contentFontPostScriptNameKey(for: targetFamily))
        defaults.set(metadata.displayName, forKey: contentFontDisplayNameKey(for: targetFamily))
        if targetFamily == .custom {
            upsertImportedCustomFont(importedFont)
            defaults.set(importedFont.id, forKey: selectedImportedContentFontIdKey)
        }
        contentFontFamily = targetFamily
        return importedFont
    }

    @discardableResult
    func importCustomContentFonts(from sourceURLs: [URL]) throws -> [ImportedContentFont] {
        var importedFonts: [ImportedContentFont] = []
        for sourceURL in sourceURLs {
            let importedFont = try importContentFont(from: sourceURL, targetFamily: .custom)
            importedFonts.append(importedFont)
        }
        return importedFonts
    }

    struct ImportedContentFont: Codable, Equatable {
        let id: String
        let postScriptName: String
        let displayName: String
        let fileName: String
        let importedAt: Date
    }

    enum ContentFontImportError: LocalizedError {
        case invalidFont
        case unsupportedFileType
        case notMiSans

        var errorDescription: String? {
            switch self {
            case .invalidFont:
                return String(localized: "settings.font.import_invalid")
            case .unsupportedFileType:
                return String(localized: "settings.font.import_unsupported")
            case .notMiSans:
                return String(localized: "settings.font.import_not_misans")
            }
        }
    }

    struct FontMetadata {
        let postScriptName: String
        let displayName: String

        var matchesMiSans: Bool {
            let searchable = "\(postScriptName) \(displayName)".lowercased()
            return searchable.contains("misans") || searchable.contains("mi sans")
        }
    }

    func registerStoredContentFonts() {
        registerBundledMiSansIfPresent()
        registerStoredContentFont(for: .miSans)
        registerStoredContentFont(for: .custom)
        registerImportedCustomContentFonts()
    }

    func registerBundledMiSansIfPresent() {
        let candidates = [
            ("MiSans-Regular", "ttf"),
            ("MiSans", "ttf"),
            ("MiSans-Regular", "otf"),
            ("MiSans", "otf"),
        ]
        for candidate in candidates {
            guard let url = Bundle.main.url(forResource: candidate.0, withExtension: candidate.1) else {
                continue
            }
            try? registerFont(at: url)
            if defaults.string(forKey: contentFontPostScriptNameKey(for: .miSans)) == nil,
               let metadata = try? fontMetadata(from: url) {
                defaults.set(metadata.postScriptName, forKey: contentFontPostScriptNameKey(for: .miSans))
                defaults.set(metadata.displayName, forKey: contentFontDisplayNameKey(for: .miSans))
            }
            return
        }
    }

    private func registerStoredContentFont(for family: ContentFontFamily) {
        guard family != .system,
              let fileName = defaults.string(forKey: contentFontFileNameKey(for: family))
        else {
            return
        }
        let url = contentFontsDirectoryURL.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? registerFont(at: url)
    }

    func registerImportedCustomContentFonts() {
        for font in importedCustomContentFonts {
            let url = contentFontsDirectoryURL.appendingPathComponent(font.fileName)
            try? registerFont(at: url)
        }
    }

    func activeFontName(for family: ContentFontFamily) -> String? {
        switch family {
        case .system:
            return nil
        case .miSans:
            if let storedName = defaults.string(forKey: contentFontPostScriptNameKey(for: .miSans)),
               UIFont(name: storedName, size: 17) != nil {
                return storedName
            }
            let candidates = ["MiSans", "MiSans-Regular", "MiSans-Normal"]
            return candidates.first { UIFont(name: $0, size: 17) != nil }
        case .custom:
            if let font = activeImportedCustomFont() {
                return font.postScriptName
            }
            guard let storedName = defaults.string(forKey: contentFontPostScriptNameKey(for: .custom)),
                  UIFont(name: storedName, size: 17) != nil
            else { return nil }
            return storedName
        }
    }

    func activeImportedCustomFont() -> ImportedContentFont? {
        let fonts = importedCustomContentFonts
        guard !fonts.isEmpty else { return nil }
        if let selectedId = defaults.string(forKey: selectedImportedContentFontIdKey),
           let selectedFont = fonts.first(where: { $0.id == selectedId }),
           UIFont(name: selectedFont.postScriptName, size: 17) != nil {
            return selectedFont
        }
        return fonts.first { UIFont(name: $0.postScriptName, size: 17) != nil }
    }

    var contentFontsDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fonts", isDirectory: true)
    }

    func contentFontsDirectory() throws -> URL {
        let url = contentFontsDirectoryURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func fontFileName(for family: ContentFontFamily, sourceURL: URL) -> String {
        let fileExtension = sourceURL.pathExtension.isEmpty ? "ttf" : sourceURL.pathExtension.lowercased()
        switch family {
        case .system:
            return "SystemFont.\(fileExtension)"
        case .miSans:
            return "MiSansImported.\(fileExtension)"
        case .custom:
            return "CustomContentFont.\(fileExtension)"
        }
    }

    func customFontFileName(metadata: FontMetadata, sourceURL: URL) -> String {
        let fileExtension = sourceURL.pathExtension.isEmpty ? "ttf" : sourceURL.pathExtension.lowercased()
        let name = sanitizedFontFileComponent(metadata.postScriptName)
        let nonce = UUID().uuidString.prefix(8)
        return "CustomContentFont-\(name)-\(nonce).\(fileExtension)"
    }

    private func sanitizedFontFileComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let pieces = value.unicodeScalars.map { scalar -> String in
            allowed.contains(scalar) ? String(scalar) : "-"
        }
        let sanitized = pieces.joined().trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return sanitized.isEmpty ? "Imported" : sanitized
    }

    func fontMetadata(from url: URL) throws -> FontMetadata {
        if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
           let descriptor = descriptors.first,
           let postScriptName = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String {
            let displayName = (CTFontDescriptorCopyAttribute(descriptor, kCTFontDisplayNameAttribute) as? String)
                ?? postScriptName
            return FontMetadata(postScriptName: postScriptName, displayName: displayName)
        }
        guard let provider = CGDataProvider(url: url as CFURL),
              let font = CGFont(provider),
              let postScriptName = font.postScriptName as String?
        else {
            throw ContentFontImportError.invalidFont
        }
        let displayName = (font.fullName as String?) ?? postScriptName
        return FontMetadata(postScriptName: postScriptName, displayName: displayName)
    }

    func registerFont(at url: URL) throws {
        var registrationError: Unmanaged<CFError>?
        let didRegister = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &registrationError)
        if didRegister {
            return
        }
        if let error = registrationError?.takeRetainedValue() {
            let nsError = error as Error as NSError
            if nsError.domain == kCTFontManagerErrorDomain as String,
               nsError.code == CTFontManagerError.alreadyRegistered.rawValue {
                return
            }
        }
        throw ContentFontImportError.invalidFont
    }

    func contentFontFileNameKey(for family: ContentFontFamily) -> String {
        "contentFont.\(family.rawValue).fileName"
    }

    func contentFontPostScriptNameKey(for family: ContentFontFamily) -> String {
        "contentFont.\(family.rawValue).postScriptName"
    }

    func contentFontDisplayNameKey(for family: ContentFontFamily) -> String {
        "contentFont.\(family.rawValue).displayName"
    }

    var importedCustomContentFontsKey: String {
        "contentFont.custom.importedFonts"
    }

    private var selectedImportedContentFontIdKey: String {
        "contentFont.custom.selectedImportedFontId"
    }

    var legacyCustomFontMigrationKey: String {
        "contentFont.custom.importedFontsMigrated"
    }

    private func storedImportedCustomFonts() -> [ImportedContentFont] {
        guard let data = defaults.data(forKey: importedCustomContentFontsKey),
              let fonts = try? JSONDecoder().decode([ImportedContentFont].self, from: data)
        else {
            return []
        }
        return fonts
    }

    private func saveImportedCustomFonts(_ fonts: [ImportedContentFont]) {
        guard let data = try? JSONEncoder().encode(fonts) else { return }
        defaults.set(data, forKey: importedCustomContentFontsKey)
    }

    func importedFontFileExists(_ font: ImportedContentFont) -> Bool {
        let url = contentFontsDirectoryURL.appendingPathComponent(font.fileName)
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func upsertImportedCustomFont(_ font: ImportedContentFont) {
        let storedFonts = storedImportedCustomFonts()
        if let oldFont = storedFonts.first(where: { $0.id == font.id }),
           oldFont.fileName != font.fileName {
            let oldURL = contentFontsDirectoryURL.appendingPathComponent(oldFont.fileName)
            try? FileManager.default.removeItem(at: oldURL)
        }

        let fonts = storedFonts.filter { $0.id != font.id } + [font]
        saveImportedCustomFonts(fonts)
    }

    func migrateLegacyCustomContentFontIfNeeded() {
        guard !defaults.bool(forKey: legacyCustomFontMigrationKey) else { return }
        defer {
            defaults.set(true, forKey: legacyCustomFontMigrationKey)
        }
        guard storedImportedCustomFonts().isEmpty,
              let fileName = defaults.string(forKey: contentFontFileNameKey(for: .custom)),
              let postScriptName = defaults.string(forKey: contentFontPostScriptNameKey(for: .custom))
        else {
            return
        }
        let legacyFont = ImportedContentFont(
            id: postScriptName,
            postScriptName: postScriptName,
            displayName: defaults.string(forKey: contentFontDisplayNameKey(for: .custom)) ?? postScriptName,
            fileName: fileName,
            importedAt: Date(timeIntervalSince1970: 0)
        )
        guard importedFontFileExists(legacyFont) else { return }
        saveImportedCustomFonts([legacyFont])
        if defaults.string(forKey: "contentFontFamily") == ContentFontFamily.custom.rawValue {
            defaults.set(legacyFont.id, forKey: selectedImportedContentFontIdKey)
        }
    }
}
