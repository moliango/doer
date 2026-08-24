import UIKit
import ObjectiveC
import CoreText

// MARK: - General
extension AppSettings {

    var autoOpenLastForum: Bool {
        get { defaults.bool(forKey: "autoOpenLastForum") }
        set {
            defaults.set(newValue, forKey: "autoOpenLastForum")
            notifyChanged()
        }
    }

    var lastOpenedForumId: Int64? {
        get {
            guard defaults.object(forKey: "lastOpenedForumId") != nil else { return nil }
            return Int64(defaults.integer(forKey: "lastOpenedForumId"))
        }
        set {
            if let value = newValue {
                defaults.set(Int(value), forKey: "lastOpenedForumId")
            } else {
                defaults.removeObject(forKey: "lastOpenedForumId")
            }
            notifyChanged()
        }
    }

    var hasShownAutoOpenPrompt: Bool {
        get { defaults.bool(forKey: "hasShownAutoOpenPrompt") }
        set {
            defaults.set(newValue, forKey: "hasShownAutoOpenPrompt")
            notifyChanged()
        }
    }

    var clearImageCacheOnLaunch: Bool {
        get { defaults.bool(forKey: "clearImageCacheOnLaunch") }
        set {
            defaults.set(newValue, forKey: "clearImageCacheOnLaunch")
            notifyChanged()
        }
    }

    func makePreferencesBackupData(
        miniProgramStore: MiniProgramStore = .shared,
        pluginStateStore: PluginStateStore = PluginStateStore(),
        notionConfigStore: NotionConfigStore = .shared,
        newAPIDirectoryURL: URL = NewAPICheckInStore.defaultDirectoryURL(),
        newAPICredentialVault: NewAPICheckInCredentialVault = NewAPICheckInKeychainVault(),
        newAPICustomPages: [NewAPICheckInCustomPage] = NewAPICheckInCustomPageStore.shared.all()
    ) throws -> Data {
        let file = PreferencesBackupFile(
            format: Self.preferencesBackupFormat,
            version: 2,
            exportedAt: Date(),
            preferences: PreferencesBackupPayload(
                appearanceMode: appearanceMode.rawValue,
                appLanguage: appLanguage.rawValue,
                themeStyle: themeStyle.rawValue,
                miniProgramsEnabled: miniProgramsEnabled,
                pluginDockEnabled: pluginDockEnabled,
                pluginDockSide: pluginDockSide.rawValue,
                pluginDockVerticalPosition: pluginDockVerticalPosition,
                autoCheckForUpdates: autoCheckForUpdates,
                xiaohongshuCardsStaggered: xiaohongshuCardsStaggered,
                // Persist raw preference (not theme-gated effective value).
                chatTopicDetailEnabled: bool(forKey: "chatTopicDetailEnabled", defaultValue: true),
                themeTaxonomyColorsEnabled: themeTaxonomyColorsEnabled,
                homeCategoryDrawerSwipeEnabled: homeCategoryDrawerSwipeEnabled,
                autoOpenLastForum: autoOpenLastForum,
                lastOpenedForumId: lastOpenedForumId,
                hasShownAutoOpenPrompt: hasShownAutoOpenPrompt,
                readingComfortMode: readingComfortMode,
                hideScrollIndicators: hideScrollIndicators,
                contentFontSize: contentFontSize.rawValue,
                contentFontScalePercent: contentFontScalePercent,
                contentFontFamily: contentFontFamily.rawValue,
                contentFontScope: contentFontScope.rawValue,
                interfaceFontScalePercent: interfaceFontScalePercent,
                homeIncomingTopicsBannerFloatingEnabled: homeIncomingTopicsBannerFloatingEnabled,
                openExternalLinksInAppBrowser: openExternalLinksInAppBrowser,
                contentImageCarouselEnabled: contentImageCarouselEnabled,
                defaultExpandRelatedLinks: defaultExpandRelatedLinks,
                showSuggestedTopics: showSuggestedTopics,
                composerInstantRender: composerInstantRender,
                clipboardTopicLinkPromptEnabled: clipboardTopicLinkPromptEnabled,
                showUserSignatures: showUserSignatures,
                nestedReplyViewEnabled: nestedReplyViewEnabled,
                showTopicCardExcerpt: showTopicCardExcerpt,
                showTopicCardTags: showTopicCardTags,
                showTopicCardCategory: showTopicCardCategory,
                showTopicCardCounts: showTopicCardCounts,
                progressGesturesEnabled: progressGesturesEnabled,
                progressGestureSwipeLeft: progressGestureSwipeLeft.rawValue,
                progressGestureSwipeRight: progressGestureSwipeRight.rawValue,
                progressGestureSwipeUp: progressGestureSwipeUp.rawValue,
                progressGestureMenuActions: progressGestureMenuActions.map(\.rawValue),
                localNotificationFilter: localNotificationFilter.rawValue,
                avatarLoadingProfile: avatarLoadingProfile.rawValue,
                bottomBarAutoHideEnabled: bottomBarAutoHideEnabled,
                forumDynamicTabItems: forumDynamicTabItems.map(\.rawValue),
                homePinnedCategoryIds: homePinnedCategoryIds,
                dohEnabled: dohEnabled,
                dohProvider: dohProvider.rawValue,
                dohCustomURL: dohCustomURL,
                clearImageCacheOnLaunch: clearImageCacheOnLaunch,
                avatarCacheSizeLimit: avatarCacheSizeLimit.rawValue,
                meStats: MeStatsPreferences().configuration,
                meAccountFunctions: MeAccountFunctionPreferences().configuration,
                userProfileTabs: UserProfileTabPreferences().visibleSections.map(\.rawValue)
            ),
            // Custom mini-programs may omit icons; local logos are embedded when available.
            miniProgramCatalog: miniProgramStore.makeCatalogExportPayload(),
            newAPICheckIn: try NewAPICheckInStore.makeExportPayload(
                directoryURL: newAPIDirectoryURL,
                credentialVault: newAPICredentialVault,
                customPages: newAPICustomPages
            ),
            pluginState: pluginStateStore.makeExportPayload(),
            notion: notionConfigStore.makeExportPayload()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(file)
    }

    func importPreferencesBackupData(
        _ data: Data,
        miniProgramStore: MiniProgramStore = .shared,
        pluginStateStore: PluginStateStore = PluginStateStore(),
        notionConfigStore: NotionConfigStore = .shared,
        newAPIDirectoryURL: URL = NewAPICheckInStore.defaultDirectoryURL(),
        newAPICredentialVault: NewAPICheckInCredentialVault = NewAPICheckInKeychainVault(),
        newAPICustomPagesStore: NewAPICheckInCustomPageStore = .shared
    ) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(PreferencesBackupFile.self, from: data)
        guard file.format == Self.preferencesBackupFormat else {
            throw PreferencesBackupError.invalidFile
        }

        let preferences = file.preferences
        if let rawValue = preferences.appearanceMode,
           let value = AppearanceMode(rawValue: rawValue) {
            appearanceMode = value
        }
        if let rawValue = preferences.appLanguage,
           let value = AppLanguage.storedValue(rawValue) {
            appLanguage = value
        }
        if let rawValue = preferences.themeStyle,
           let value = ThemeStyle(rawValue: rawValue) {
            themeStyle = value
        }
        if let value = preferences.miniProgramsEnabled {
            miniProgramsEnabled = value
        }
        if let value = preferences.pluginDockEnabled {
            pluginDockEnabled = value
        }
        if let rawValue = preferences.pluginDockSide,
           let value = PluginDockSide(rawValue: rawValue) {
            pluginDockSide = value
        }
        if let value = preferences.pluginDockVerticalPosition {
            pluginDockVerticalPosition = value
        }
        if let value = preferences.autoCheckForUpdates {
            autoCheckForUpdates = value
        }
        if let value = preferences.xiaohongshuCardsStaggered {
            xiaohongshuCardsStaggered = value
        }
        if let value = preferences.chatTopicDetailEnabled {
            // Persist raw key so default/on-off is preserved even if theme changes later.
            defaults.set(value, forKey: "chatTopicDetailEnabled")
        }
        if let value = preferences.themeTaxonomyColorsEnabled {
            themeTaxonomyColorsEnabled = value
        }
        if let value = preferences.homeCategoryDrawerSwipeEnabled {
            homeCategoryDrawerSwipeEnabled = value
        }
        if let value = preferences.autoOpenLastForum {
            autoOpenLastForum = value
        }
        if let value = preferences.lastOpenedForumId {
            lastOpenedForumId = value
        }
        if let value = preferences.hasShownAutoOpenPrompt {
            hasShownAutoOpenPrompt = value
        }
        if let value = preferences.readingComfortMode {
            readingComfortMode = value
        }
        if let value = preferences.hideScrollIndicators {
            hideScrollIndicators = value
        }
        if let rawValue = preferences.contentFontSize,
           let value = ContentFontSize(rawValue: rawValue) {
            if preferences.contentFontScalePercent == nil {
                contentFontSize = .standard
                contentFontScalePercent = value.legacyScalePercent
            } else {
                contentFontSize = value
            }
        }
        if let value = preferences.contentFontScalePercent {
            contentFontScalePercent = value
        }
        if let rawValue = preferences.contentFontFamily,
           let value = ContentFontFamily(rawValue: rawValue) {
            contentFontFamily = isContentFontFamilyAvailable(value) ? value : .system
        }
        if let rawValue = preferences.contentFontScope,
           let value = ContentFontScope(rawValue: rawValue) {
            contentFontScope = value
        }
        if let value = preferences.interfaceFontScalePercent {
            interfaceFontScalePercent = value
        }
        if let value = preferences.homeIncomingTopicsBannerFloatingEnabled {
            homeIncomingTopicsBannerFloatingEnabled = value
        }
        if let value = preferences.openExternalLinksInAppBrowser {
            openExternalLinksInAppBrowser = value
        }
        if let value = preferences.contentImageCarouselEnabled {
            contentImageCarouselEnabled = value
        }
        if let value = preferences.defaultExpandRelatedLinks {
            defaultExpandRelatedLinks = value
        }
        if let value = preferences.showSuggestedTopics {
            showSuggestedTopics = value
        }
        if let value = preferences.composerInstantRender {
            composerInstantRender = value
        }
        if let value = preferences.clipboardTopicLinkPromptEnabled {
            clipboardTopicLinkPromptEnabled = value
        }
        if let value = preferences.showUserSignatures {
            showUserSignatures = value
        }
        if let value = preferences.nestedReplyViewEnabled {
            nestedReplyViewEnabled = value
        }
        if let value = preferences.showTopicCardExcerpt {
            showTopicCardExcerpt = value
        }
        if let value = preferences.showTopicCardTags {
            showTopicCardTags = value
        }
        if let value = preferences.showTopicCardCategory {
            showTopicCardCategory = value
        }
        if let value = preferences.showTopicCardCounts {
            showTopicCardCounts = value
        }
        if let value = preferences.progressGesturesEnabled {
            progressGesturesEnabled = value
        }
        if let rawValue = preferences.progressGestureSwipeLeft {
            progressGestureSwipeLeft = ProgressGestureSettings.decodeAction(rawValue, fallback: .nextPost)
        }
        if let rawValue = preferences.progressGestureSwipeRight {
            progressGestureSwipeRight = ProgressGestureSettings.decodeAction(rawValue, fallback: .previousPost)
        }
        if let rawValue = preferences.progressGestureSwipeUp {
            progressGestureSwipeUp = ProgressGestureSettings.decodeAction(rawValue, fallback: .jumpToUnread)
        }
        if let rawValues = preferences.progressGestureMenuActions {
            progressGestureMenuActions = ProgressGestureSettings.decodeActions(
                rawValues,
                fallback: ProgressGestureAction.defaultMenuActions
            )
        }
        if let rawValue = preferences.localNotificationFilter,
           let value = LocalNotificationFilter(rawValue: rawValue) {
            localNotificationFilter = value
        }
        if let rawValue = preferences.avatarLoadingProfile,
           let value = AvatarLoadingProfile(rawValue: rawValue) {
            avatarLoadingProfile = value
        }
        if let value = preferences.bottomBarAutoHideEnabled {
            bottomBarAutoHideEnabled = value
        }
        if let rawValues = preferences.forumDynamicTabItems {
            forumDynamicTabItems = rawValues.compactMap(ForumDynamicTabItem.storedValue)
        }
        if let values = preferences.homePinnedCategoryIds {
            homePinnedCategoryIds = values
        }
        if let value = preferences.dohEnabled {
            dohEnabled = value
        }
        if let rawValue = preferences.dohProvider,
           let value = DoHProvider(rawValue: rawValue) {
            dohProvider = value
        }
        if let value = preferences.dohCustomURL {
            dohCustomURL = value
        }
        if let value = preferences.clearImageCacheOnLaunch {
            clearImageCacheOnLaunch = value
        }
        if let rawValue = preferences.avatarCacheSizeLimit,
           let value = AvatarCacheSizeLimit(rawValue: rawValue) {
            avatarCacheSizeLimit = value
        }
        if let catalog = file.miniProgramCatalog {
            miniProgramStore.importCatalogExportPayload(catalog)
        }
        if let newAPI = file.newAPICheckIn {
            try NewAPICheckInStore.importExportPayload(
                newAPI,
                directoryURL: newAPIDirectoryURL,
                credentialVault: newAPICredentialVault,
                customPagesStore: newAPICustomPagesStore
            )
        }
        if let pluginState = file.pluginState {
            pluginStateStore.importExportPayload(pluginState)
        }
        if let notion = file.notion {
            notionConfigStore.importExportPayload(notion)
        }
        if let meStats = preferences.meStats, !meStats.orderedMetrics.isEmpty {
            MeStatsPreferences().configuration = meStats
        }
        if let functions = preferences.meAccountFunctions {
            MeAccountFunctionPreferences().configuration = functions
        }
        if let tabs = preferences.userProfileTabs {
            let sections = tabs.compactMap(UserProfileSection.init(rawValue:))
            if !sections.isEmpty {
                UserProfileTabPreferences().setVisibleSections(sections)
            }
        }
        applyLanguage()
        applyAppearance()
        notifyChanged()
    }

    enum PreferencesBackupError: LocalizedError {
        case invalidFile

        var errorDescription: String? {
            switch self {
            case .invalidFile:
                return String(localized: "settings.data.backup_invalid")
            }
        }
    }

    private static let preferencesBackupFormat = "dexo.preferences.backup"

    struct PreferencesBackupFile: Codable {
        let format: String
        let version: Int
        let exportedAt: Date
        let preferences: PreferencesBackupPayload
        /// Optional so older backups without a mini-program catalog still import.
        let miniProgramCatalog: MiniProgramCatalogExportPayload?
        let newAPICheckIn: NewAPICheckInExportPayload?
        let pluginState: PluginStateExportPayload?
        let notion: NotionConfigExportPayload?

        init(
            format: String,
            version: Int,
            exportedAt: Date,
            preferences: PreferencesBackupPayload,
            miniProgramCatalog: MiniProgramCatalogExportPayload? = nil,
            newAPICheckIn: NewAPICheckInExportPayload? = nil,
            pluginState: PluginStateExportPayload? = nil,
            notion: NotionConfigExportPayload? = nil
        ) {
            self.format = format
            self.version = version
            self.exportedAt = exportedAt
            self.preferences = preferences
            self.miniProgramCatalog = miniProgramCatalog
            self.newAPICheckIn = newAPICheckIn
            self.pluginState = pluginState
            self.notion = notion
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            format = try container.decode(String.self, forKey: .format)
            version = try container.decode(Int.self, forKey: .version)
            exportedAt = try container.decode(Date.self, forKey: .exportedAt)
            preferences = try container.decode(PreferencesBackupPayload.self, forKey: .preferences)
            miniProgramCatalog = try container.decodeIfPresent(
                MiniProgramCatalogExportPayload.self,
                forKey: .miniProgramCatalog
            )
            newAPICheckIn = try container.decodeIfPresent(
                NewAPICheckInExportPayload.self,
                forKey: .newAPICheckIn
            )
            pluginState = try container.decodeIfPresent(
                PluginStateExportPayload.self,
                forKey: .pluginState
            )
            notion = try container.decodeIfPresent(
                NotionConfigExportPayload.self,
                forKey: .notion
            )
        }
    }

    struct PreferencesBackupPayload: Codable {
        let appearanceMode: Int?
        let appLanguage: String?
        let themeStyle: Int?
        let miniProgramsEnabled: Bool?
        let pluginDockEnabled: Bool?
        let pluginDockSide: String?
        let pluginDockVerticalPosition: Double?
        let autoCheckForUpdates: Bool?
        let xiaohongshuCardsStaggered: Bool?
        let chatTopicDetailEnabled: Bool?
        let themeTaxonomyColorsEnabled: Bool?
        let homeCategoryDrawerSwipeEnabled: Bool?
        let autoOpenLastForum: Bool?
        let lastOpenedForumId: Int64?
        let hasShownAutoOpenPrompt: Bool?
        let readingComfortMode: Bool?
        let hideScrollIndicators: Bool?
        let contentFontSize: Int?
        let contentFontScalePercent: Int?
        let contentFontFamily: String?
        let contentFontScope: Int?
        let interfaceFontScalePercent: Int?
        let homeIncomingTopicsBannerFloatingEnabled: Bool?
        let openExternalLinksInAppBrowser: Bool?
        let contentImageCarouselEnabled: Bool?
        let defaultExpandRelatedLinks: Bool?
        let showSuggestedTopics: Bool?
        let composerInstantRender: Bool?
        let clipboardTopicLinkPromptEnabled: Bool?
        let showUserSignatures: Bool?
        let nestedReplyViewEnabled: Bool?
        let showTopicCardExcerpt: Bool?
        let showTopicCardTags: Bool?
        let showTopicCardCategory: Bool?
        let showTopicCardCounts: Bool?
        let progressGesturesEnabled: Bool?
        let progressGestureSwipeLeft: String?
        let progressGestureSwipeRight: String?
        let progressGestureSwipeUp: String?
        let progressGestureMenuActions: [String]?
        let localNotificationFilter: String?
        let avatarLoadingProfile: Int?
        let bottomBarAutoHideEnabled: Bool?
        let forumDynamicTabItems: [String]?
        let homePinnedCategoryIds: [Int]?
        let dohEnabled: Bool?
        let dohProvider: Int?
        let dohCustomURL: String?
        let clearImageCacheOnLaunch: Bool?
        let avatarCacheSizeLimit: Int?
        let meStats: MeStatsConfiguration?
        let meAccountFunctions: MeAccountFunctionConfiguration?
        let userProfileTabs: [String]?
    }
}
