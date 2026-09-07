import XCTest
@testable import Doer

@MainActor
final class TopicTaxonomyPresentationTests: XCTestCase {
    func testFontAwesomeCategoryIconNormalizesDiscourseNames() {
        XCTAssertEqual(DiscourseFontAwesomeIcon.glyph(for: "code"), "\u{f121}")
        XCTAssertEqual(DiscourseFontAwesomeIcon.glyph(for: "fa-code"), "\u{f121}")
        XCTAssertEqual(DiscourseFontAwesomeIcon.glyph(for: "fas fa-code"), "\u{f121}")
        XCTAssertEqual(DiscourseFontAwesomeIcon.glyph(for: "book-open-reader"), "\u{f5da}")
        XCTAssertEqual(DiscourseFontAwesomeIcon.glyph(for: "square-share-nodes"), "\u{f1e1}")
        XCTAssertEqual(DiscourseFontAwesomeIcon.glyph(for: "hard-drive"), "\u{f0a0}")
        XCTAssertNil(DiscourseFontAwesomeIcon.glyph(for: "not-a-real-icon"))
    }

    func testLinuxDoTagCatalogUsesFluxDoIconsAndNormalizesLatinNames() throws {
        let ai = try XCTUnwrap(TopicTagIconCatalog.presentation(for: "人工智能"))
        let aff = try XCTUnwrap(TopicTagIconCatalog.presentation(for: "AFF"))
        let vps = try XCTUnwrap(TopicTagIconCatalog.presentation(for: "VPS"))

        XCTAssertEqual(ai.iconName, "brain")
        XCTAssertEqual(ai.colorHex.lowercased(), "bd93f9")
        XCTAssertEqual(aff.iconName, "arrow-pointer")
        XCTAssertEqual(vps.iconName, "server")
        XCTAssertNil(TopicTagIconCatalog.presentation(for: "未配置标签"))
    }

    func testWeChatTelegramListSubtitleRendersTagIcon() throws {
        XCTAssertEqual(TopicTagVisualStyle.iconName(for: "抽奖"), "shuffle")
        XCTAssertEqual(TopicTagVisualStyle.iconName(for: "未知标签"), "tag")
        let subtitle = try XCTUnwrap(
            TopicListTagSubtitle.make(
                categoryName: "开发调优",
                tags: ["抽奖"],
                font: .systemFont(ofSize: 13),
                categoryColor: .secondaryLabel
            )
        )
        XCTAssertTrue(subtitle.string.contains("开发调优"))
        XCTAssertTrue(subtitle.string.contains("抽奖"))
        XCTAssertFalse(subtitle.string.contains("#抽奖"))
        XCTAssertGreaterThan(subtitle.length, "开发调优 · 抽奖".utf16.count)
    }

    func testCurrentLinuxDoCategoryAndFluxDoTagIconsExistInBundledFontMap() {
        let currentCategoryIcons = [
            "code", "seedling", "square-share-nodes", "hard-drive", "book",
            "briefcase", "book-open-reader", "newspaper", "rss", "piggy-bank",
            "droplet", "comments", "bullhorn", "award", "users", "clone",
        ]

        XCTAssertTrue(currentCategoryIcons.allSatisfy { DiscourseFontAwesomeIcon.glyph(for: $0) != nil })
        XCTAssertNil(DiscourseFontAwesomeIcon.glyph(for: "hurricane"))
        XCTAssertEqual(TopicTagIconCatalog.allPresentations.count, 52)
        XCTAssertTrue(
            TopicTagIconCatalog.allPresentations.values.allSatisfy {
                DiscourseFontAwesomeIcon.glyph(for: $0.iconName) != nil
            }
        )
    }

    func testResolveByCategoryIdUsesLinuxDoCatalogNameAndColor() throws {
        let presentation = try XCTUnwrap(
            TopicCategoryBadgePresentation.resolve(
                categoryId: 11,
                baseURL: "https://linux.do"
            )
        )
        XCTAssertEqual(presentation.name, "搞七捻三")
        XCTAssertEqual(presentation.colorHex.lowercased(), "3ab54a")
        XCTAssertNil(
            TopicCategoryBadgePresentation.resolve(
                categoryId: 11,
                baseURL: "https://example.com"
            )
        )
    }

    func testLinuxDoBundledCategorySeedProvidesOfficialIconBeforeSiteRefresh() throws {
        let category = makeCategory(id: 32, name: "读书成诗")
        let presentation = try XCTUnwrap(
            TopicCategoryBadgePresentation.resolve(
                category: category,
                parent: nil,
                baseURL: "https://linux.do"
            )
        )

        XCTAssertEqual(presentation.iconSource, .fontAwesome("book-open-reader"))
        XCTAssertNil(LinuxDoCategoryCatalog.category(id: 32, baseURL: "https://example.com"))

        let wormhole = try XCTUnwrap(LinuxDoCategoryCatalog.category(id: 110, baseURL: "https://linux.do"))
        XCTAssertEqual(
            try XCTUnwrap(
                TopicCategoryBadgePresentation.resolve(
                    category: wormhole,
                    parent: nil,
                    baseURL: "https://linux.do"
                )
            ).iconSource,
            .logo("//linuxdo-uploads.s3.ldstatic.com/original/4X/a/6/0/a60b29099b83d51a949bccd708cbdacee40ada80.png")
        )
    }

    func testTaxonomySessionStoreSharesServerCategoriesAndDeduplicatesRefreshes() async throws {
        DiscourseTaxonomySessionStore.resetForTesting()
        let category = makeCategory(id: 4, name: "开发调优", icon: "code")

        XCTAssertTrue(DiscourseTaxonomySessionStore.beginRefresh(for: "https://linux.do"))
        XCTAssertFalse(DiscourseTaxonomySessionStore.beginRefresh(for: "https://linux.do/"))
        let waiter = Task {
            await DiscourseTaxonomySessionStore.waitForRefresh(for: "https://linux.do/")
        }
        await Task.yield()
        DiscourseTaxonomySessionStore.replace(categories: [category], for: "https://linux.do")
        DiscourseTaxonomySessionStore.endRefresh(for: "https://linux.do")
        let sharedCategories = await waiter.value

        XCTAssertEqual(sharedCategories.map(\.id), [4])
        XCTAssertEqual(
            try XCTUnwrap(
                DiscourseTaxonomySessionStore.category(id: 4, for: "https://linux.do")
            ).icon,
            "code"
        )
        XCTAssertNil(DiscourseTaxonomySessionStore.category(id: 4, for: "https://example.com"))
    }

    func testCategoryPresentationPrefersOwnIconOverLogoAndParent() throws {
        let category = makeCategory(
            id: 4,
            name: "开发调优",
            icon: "code",
            uploadedLogo: "/uploads/category-logo.png"
        )
        let parent = makeCategory(id: 1, name: "开发", icon: "terminal")

        let presentation = try XCTUnwrap(
            TopicCategoryBadgePresentation.resolve(
                category: category,
                parent: parent,
                displayName: "开发调优"
            )
        )

        XCTAssertEqual(presentation.name, "开发调优")
        XCTAssertEqual(presentation.iconSource, .fontAwesome("code"))
    }

    func testCategoryPresentationFallsBackFromLogoToParentIcon() throws {
        let categoryWithLogo = makeCategory(
            id: 4,
            name: "开发调优",
            icon: "unknown-icon",
            uploadedLogo: "/uploads/category-logo.png"
        )
        let childWithoutVisual = makeCategory(id: 5, name: "软件开发", parentCategoryId: 1)
        let parent = makeCategory(id: 1, name: "开发", icon: "terminal")

        let logoPresentation = try XCTUnwrap(
            TopicCategoryBadgePresentation.resolve(category: categoryWithLogo, parent: parent)
        )
        let parentPresentation = try XCTUnwrap(
            TopicCategoryBadgePresentation.resolve(category: childWithoutVisual, parent: parent)
        )

        XCTAssertEqual(logoPresentation.iconSource, .logo("/uploads/category-logo.png"))
        XCTAssertEqual(parentPresentation.iconSource, .fontAwesome("terminal"))
    }

    func testCategoryPresentationFallsBackToLockOrDot() throws {
        let restricted = makeCategory(id: 6, name: "内部", readRestricted: true)
        let regular = makeCategory(id: 7, name: "普通")

        XCTAssertEqual(
            try XCTUnwrap(TopicCategoryBadgePresentation.resolve(category: restricted, parent: nil)).iconSource,
            .lock
        )
        XCTAssertEqual(
            try XCTUnwrap(TopicCategoryBadgePresentation.resolve(category: regular, parent: nil)).iconSource,
            .dot
        )
    }

    private func makeCategory(
        id: Int,
        name: String,
        icon: String? = nil,
        uploadedLogo: String? = nil,
        parentCategoryId: Int? = nil,
        readRestricted: Bool = false
    ) -> DiscourseCategory {
        DiscourseCategory(
            id: id,
            name: name,
            slug: "category-\(id)",
            color: "0E8A92",
            parentCategoryId: parentCategoryId,
            uploadedLogo: uploadedLogo,
            readRestricted: readRestricted,
            icon: icon
        )
    }
}
