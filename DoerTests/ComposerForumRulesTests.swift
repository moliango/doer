import XCTest
@testable import Doer

final class ComposerForumRulesTests: XCTestCase {
    func testCustomFieldsKeepPositiveIntsFromMixedJSON() throws {
        let json = """
        {
          "min_post_length": "200",
          "reply_cost": 5,
          "enable_unassign_on_close": false,
          "ignored": "nope"
        }
        """.data(using: .utf8)!
        let fields = try JSONDecoder().decode(DiscourseCustomFields.self, from: json)
        XCTAssertEqual(fields.int(forKeys: ["min_post_length"]), 200)
        XCTAssertEqual(fields.int(forKeys: ["reply_cost"]), 5)
        XCTAssertNil(fields.int(forKeys: ["enable_unassign_on_close"]))
        XCTAssertNil(fields.int(forKeys: ["ignored"]))
    }

    func testCategoryDecodesWardenAndReplyCostFields() throws {
        let json = """
        {
          "id": 4,
          "name": "开发调优",
          "color": "32c3c3",
          "slug": "develop",
          "topic_count": 1,
          "custom_fields": {
            "min_first_post_length": 300,
            "min_post_length": 120,
            "reply_cost": 8
          }
        }
        """.data(using: .utf8)!
        let category = try JSONDecoder().decode(DiscourseCategory.self, from: json)
        let rules = ComposerForumRules.resolve(category: category)
        XCTAssertEqual(rules.minFirstPostLength, 300)
        XCTAssertEqual(rules.minReplyLength, 120)
        XCTAssertEqual(rules.replyCost, 8)
    }

    func testChildInheritsParentMinAndCostWhenMissing() {
        let parent = DiscourseCategory(
            id: 1,
            name: "开发",
            slug: "dev",
            customFields: DiscourseCustomFields(values: [
                "min_post_length": 80,
                "reply_cost": 3,
            ])
        )
        let child = DiscourseCategory(id: 2, name: "调优", slug: "tune", parentCategoryId: 1)
        let rules = ComposerForumRules.resolve(category: child, parent: parent)
        XCTAssertEqual(rules.minFirstPostLength, 80)
        XCTAssertEqual(rules.minReplyLength, 80)
        XCTAssertEqual(rules.replyCost, 3)
    }

    func testVisibleLengthCollapsesWhitespaceAndCountsCJK() {
        XCTAssertEqual(ComposerWardenPolicy.visibleLength(of: "  你好  world  "), 8)
        XCTAssertEqual(ComposerWardenPolicy.visibleLength(of: "\n\n"), 0)
        XCTAssertEqual(ComposerWardenPolicy.visibleLength(of: "abc"), 3)
    }

    func testProgressRemainingAndHintVisibility() {
        let short = ComposerWardenPolicy.progress(raw: "hi", minimum: 10)
        XCTAssertEqual(short.current, 2)
        XCTAssertEqual(short.remaining, 8)
        XCTAssertFalse(short.meetsMinimum)
        XCTAssertTrue(short.shouldShowHint)

        let enough = ComposerWardenPolicy.progress(raw: "abcdefghij", minimum: 10)
        XCTAssertTrue(enough.meetsMinimum)
        XCTAssertEqual(enough.remaining, 0)

        let none = ComposerWardenPolicy.progress(raw: "", minimum: 0)
        XCTAssertTrue(none.meetsMinimum)
        XCTAssertFalse(none.shouldShowHint)
    }

    func testReplyCostConfirmOnlyForPositiveReply() {
        XCTAssertTrue(ComposerReplyCostPolicy.shouldConfirm(cost: 5, isReply: true))
        XCTAssertFalse(ComposerReplyCostPolicy.shouldConfirm(cost: 5, isReply: false))
        XCTAssertFalse(ComposerReplyCostPolicy.shouldConfirm(cost: 0, isReply: true))
    }

    func testFilterHintCopyAndSettingGate() {
        XCTAssertEqual(
            TopicFilterHintPolicy.bannerTitle(
                showHint: true,
                isFilteringByOP: true,
                filterUsername: "alice",
                isFilteringTopLevel: false
            ),
            String(localized: "topic.filter_hint.op", defaultValue: "正在查看题主")
        )
        XCTAssertEqual(
            TopicFilterHintPolicy.bannerTitle(
                showHint: true,
                isFilteringByOP: false,
                filterUsername: "bob",
                isFilteringTopLevel: true
            ),
            String(
                format: String(localized: "topic.filter_hint.user %@", defaultValue: "正在查看 %@"),
                "bob"
            )
        )
        XCTAssertEqual(
            TopicFilterHintPolicy.bannerTitle(
                showHint: true,
                isFilteringByOP: false,
                filterUsername: nil,
                isFilteringTopLevel: true
            ),
            String(localized: "topic.filter_hint.top_level", defaultValue: "正在查看顶层回复")
        )
        XCTAssertNil(
            TopicFilterHintPolicy.bannerTitle(
                showHint: false,
                isFilteringByOP: true,
                filterUsername: "alice",
                isFilteringTopLevel: true
            )
        )
        XCTAssertNil(
            TopicFilterHintPolicy.bannerTitle(
                showHint: true,
                isFilteringByOP: false,
                filterUsername: nil,
                isFilteringTopLevel: false
            )
        )
    }
}
