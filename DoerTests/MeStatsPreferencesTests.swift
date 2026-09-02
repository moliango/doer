import XCTest
@testable import Doer

@MainActor
final class MeStatsPreferencesTests: XCTestCase {
    func testLegacySelectionMigratesInOrderWithGridLayout() {
        let suiteName = "MeStatsPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["likesReceived", "topicCount", "daysVisited"], forKey: "me.stats.selected")

        let preferences = MeStatsPreferences(defaults: defaults)

        XCTAssertEqual(preferences.configuration.orderedMetrics, [.likesReceived, .topicCount, .daysVisited])
        XCTAssertEqual(preferences.configuration.layout, .grid)
    }

    func testConfigurationRoundTrips() {
        let suiteName = "MeStatsPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = MeStatsPreferences(defaults: defaults)
        let configuration = MeStatsConfiguration(
            orderedMetrics: [.badges, .timeRead],
            layout: .horizontal
        )

        preferences.configuration = configuration

        let reloaded = MeStatsPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.configuration, configuration)
    }

    func testStatsEditorViewUsesDragWithoutTableEditing() {
        let editor = ProfileStatsEditorViewController(
            configuration: MeStatsConfiguration(
                orderedMetrics: [.daysVisited, .postCount, .likesReceived, .topicCount],
                layout: .grid
            )
        )
        editor.loadViewIfNeeded()

        let table = editor.view.subviews.compactMap { $0 as? UITableView }.first
        XCTAssertNotNil(table)
        XCTAssertEqual(table?.isEditing, false)
        XCTAssertEqual(table?.dragInteractionEnabled, true)
    }

    func testGridLayoutUsesFourColumnsAndWrapsAfterFour() {
        XCTAssertEqual(MeStatsLayoutGeometry.gridColumns, 4)
        XCTAssertEqual(MeStatsLayoutGeometry.gridItemHeight, 84)
        XCTAssertEqual(MeStatsLayoutGeometry.gridRowCount(for: 0), 0)
        XCTAssertEqual(MeStatsLayoutGeometry.gridRowCount(for: 4), 1)
        XCTAssertEqual(MeStatsLayoutGeometry.gridRowCount(for: 5), 2)
        XCTAssertEqual(
            MeStatsLayoutGeometry.contentHeight(for: 4, layout: .grid),
            MeStatsLayoutGeometry.gridItemHeight
        )
        XCTAssertEqual(
            MeStatsLayoutGeometry.contentHeight(for: 5, layout: .grid),
            MeStatsLayoutGeometry.gridItemHeight * 2 + MeStatsLayoutGeometry.gridSpacing
        )
        XCTAssertEqual(
            MeStatsLayoutGeometry.contentHeight(for: 4, layout: .horizontal),
            MeStatsLayoutGeometry.horizontalItemHeight
        )
    }

    func testHorizontalTilesLeaveAPeekInsteadOfFillingFourUp() {
        let container: CGFloat = 333
        let tile = MeStatsLayoutGeometry.horizontalItemWidth(in: container)
        let fourTiles = tile * 4 + MeStatsLayoutGeometry.horizontalSpacing * 3
        XCTAssertGreaterThan(fourTiles, container)
        let threeTiles = tile * 3 + MeStatsLayoutGeometry.horizontalSpacing * 2
        XCTAssertLessThan(threeTiles, container)
        XCTAssertGreaterThan(container - threeTiles, 16)
    }

    func testHideMetricRemovesItemAndRespectsMinimum() {
        var configuration = MeStatsConfiguration(
            orderedMetrics: [.daysVisited, .postCount, .likesReceived],
            layout: .grid
        )

        XCTAssertTrue(configuration.hideMetric(.likesReceived))
        XCTAssertEqual(configuration.orderedMetrics, [.daysVisited, .postCount])
        XCTAssertFalse(configuration.hideMetric(.postCount))
        XCTAssertEqual(configuration.orderedMetrics, [.daysVisited, .postCount])
    }

    func testShowAndMoveMetricsUpdateOrder() {
        var configuration = MeStatsConfiguration(
            orderedMetrics: [.daysVisited, .postCount],
            layout: .horizontal
        )

        configuration.showMetric(.badges)
        XCTAssertEqual(configuration.orderedMetrics, [.daysVisited, .postCount, .badges])
        configuration.moveMetric(at: 2, by: -1)
        XCTAssertEqual(configuration.orderedMetrics, [.daysVisited, .badges, .postCount])
        configuration.moveMetric(from: 0, to: 2)
        XCTAssertEqual(configuration.orderedMetrics, [.badges, .postCount, .daysVisited])
        XCTAssertEqual(configuration.hiddenMetrics.contains(.likesGiven), true)
    }

    func testAccountFunctionsDefaultToAllVisible() {
        let suiteName = "MeAccountFunctionPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = MeAccountFunctionPreferences(defaults: defaults)

        XCTAssertEqual(preferences.visibleFunctions, MeAccountFunction.allCases)
        XCTAssertTrue(preferences.hiddenFunctions.isEmpty)
    }

    func testAccountFunctionsVisibilityAndOrderRoundTrip() {
        let suiteName = "MeAccountFunctionPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = MeAccountFunctionPreferences(defaults: defaults)

        preferences.setVisibleFunctions([.settings, .messages, .browser])

        let reloaded = MeAccountFunctionPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.visibleFunctions, [.settings, .messages, .browser])
        XCTAssertFalse(reloaded.hiddenFunctions.contains(.settings))
        XCTAssertTrue(reloaded.hiddenFunctions.contains(.aiModelService))
    }

    func testAccountFunctionsResetRestoresDefault() {
        let suiteName = "MeAccountFunctionPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = MeAccountFunctionPreferences(defaults: defaults)
        preferences.setVisibleFunctions([.settings])

        preferences.reset()

        XCTAssertEqual(preferences.visibleFunctions, MeAccountFunction.allCases)
        XCTAssertTrue(preferences.hiddenFunctions.isEmpty)
    }
}
