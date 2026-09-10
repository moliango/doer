import Combine
import XCTest
@testable import Doer

@MainActor
final class AccountScopedStoreTests: XCTestCase {
    private let updateDefaultsKeys = [
        "autoCheckForUpdates",
    ]
    private let pluginDockDefaultsKeys = [
        "pluginDockEnabled",
        "pluginDockSide",
        "pluginDockVerticalPosition",
    ]

    func testAutomaticUpdateCheckDefaultsToEnabled() {
        withPreservedUpdateDefaults {
            UserDefaults.standard.removeObject(forKey: "autoCheckForUpdates")

            XCTAssertTrue(AppSettings.shared.autoCheckForUpdates)
        }
    }

    func testAutomaticUpdateCheckNotifiesOnlyWhenValueChanges() {
        withPreservedUpdateDefaults {
            UserDefaults.standard.removeObject(forKey: "autoCheckForUpdates")
            var notificationCount = 0
            let token = AppSettings.shared.objectWillChange.sink {
                notificationCount += 1
            }
            defer { token.cancel() }

            AppSettings.shared.autoCheckForUpdates = true
            XCTAssertEqual(notificationCount, 0)

            AppSettings.shared.autoCheckForUpdates = false
            XCTAssertEqual(notificationCount, 1)

            AppSettings.shared.autoCheckForUpdates = false
            XCTAssertEqual(notificationCount, 1)

            AppSettings.shared.autoCheckForUpdates = true
            XCTAssertEqual(notificationCount, 2)
        }
    }

    func testAutomaticUpdateCheckPreferencesBackupRoundTrip() throws {
        try withPreservedUpdateDefaults {
            AppSettings.shared.autoCheckForUpdates = false
            let backup = try AppSettings.shared.makePreferencesBackupData()

            AppSettings.shared.autoCheckForUpdates = true
            try AppSettings.shared.importPreferencesBackupData(backup)

            XCTAssertFalse(AppSettings.shared.autoCheckForUpdates)
        }
    }

    func testPluginDockDefaultsAndStoredValues() {
        withPreservedPluginDockDefaults {
            let defaults = UserDefaults.standard
            pluginDockDefaultsKeys.forEach(defaults.removeObject(forKey:))

            XCTAssertTrue(AppSettings.shared.pluginDockEnabled)
            XCTAssertEqual(AppSettings.shared.pluginDockSide, .right)
            XCTAssertEqual(AppSettings.shared.pluginDockVerticalPosition, 0.72, accuracy: 0.0001)

            AppSettings.shared.pluginDockEnabled = false
            AppSettings.shared.pluginDockSide = .left
            AppSettings.shared.pluginDockVerticalPosition = 0.35

            XCTAssertFalse(AppSettings.shared.pluginDockEnabled)
            XCTAssertEqual(AppSettings.shared.pluginDockSide, .left)
            XCTAssertEqual(AppSettings.shared.pluginDockVerticalPosition, 0.35, accuracy: 0.0001)
        }
    }

    func testPluginDockVerticalPositionIsNormalized() {
        withPreservedPluginDockDefaults {
            AppSettings.shared.pluginDockVerticalPosition = -1
            XCTAssertEqual(AppSettings.shared.pluginDockVerticalPosition, 0, accuracy: 0.0001)

            AppSettings.shared.pluginDockVerticalPosition = 2
            XCTAssertEqual(AppSettings.shared.pluginDockVerticalPosition, 1, accuracy: 0.0001)

            AppSettings.shared.pluginDockVerticalPosition = .nan
            XCTAssertEqual(AppSettings.shared.pluginDockVerticalPosition, 0.72, accuracy: 0.0001)

            AppSettings.shared.pluginDockVerticalPosition = .infinity
            XCTAssertEqual(AppSettings.shared.pluginDockVerticalPosition, 0.72, accuracy: 0.0001)
        }
    }

    func testPluginDockSideAndPositionDoNotNotifyForEquivalentValues() {
        withPreservedPluginDockDefaults {
            AppSettings.shared.pluginDockSide = .right
            AppSettings.shared.pluginDockVerticalPosition = 0.72
            var notificationCount = 0
            let token = AppSettings.shared.objectWillChange.sink {
                notificationCount += 1
            }
            defer { token.cancel() }

            AppSettings.shared.pluginDockSide = .right
            AppSettings.shared.pluginDockVerticalPosition = 0.72001
            XCTAssertEqual(notificationCount, 0)

            AppSettings.shared.pluginDockSide = .left
            AppSettings.shared.pluginDockVerticalPosition = 0.4
            XCTAssertEqual(notificationCount, 2)
        }
    }

    func testReadingAndNotificationPreferencesBackupRoundTrip() throws {
        let settings = AppSettings.shared
        let originalClipboard = settings.clipboardTopicLinkPromptEnabled
        let originalFilter = settings.localNotificationFilter
        let originalExcerpt = settings.showTopicCardExcerpt
        let originalSignatures = settings.showUserSignatures
        let originalGestures = settings.progressGesturesEnabled
        defer {
            settings.clipboardTopicLinkPromptEnabled = originalClipboard
            settings.localNotificationFilter = originalFilter
            settings.showTopicCardExcerpt = originalExcerpt
            settings.showUserSignatures = originalSignatures
            settings.progressGesturesEnabled = originalGestures
        }

        settings.clipboardTopicLinkPromptEnabled = false
        settings.localNotificationFilter = .mentionsOnly
        settings.showTopicCardExcerpt = true
        settings.showUserSignatures = false
        settings.progressGesturesEnabled = false
        let backup = try settings.makePreferencesBackupData()

        settings.clipboardTopicLinkPromptEnabled = true
        settings.localNotificationFilter = .all
        settings.showTopicCardExcerpt = false
        settings.showUserSignatures = true
        settings.progressGesturesEnabled = true
        try settings.importPreferencesBackupData(backup)

        XCTAssertFalse(settings.clipboardTopicLinkPromptEnabled)
        XCTAssertEqual(settings.localNotificationFilter, .mentionsOnly)
        XCTAssertTrue(settings.showTopicCardExcerpt)
        XCTAssertFalse(settings.showUserSignatures)
        XCTAssertFalse(settings.progressGesturesEnabled)
    }

    func testPluginDockPreferencesBackupRoundTrip() throws {
        try withPreservedPluginDockDefaults {
            AppSettings.shared.pluginDockEnabled = false
            AppSettings.shared.pluginDockSide = .left
            AppSettings.shared.pluginDockVerticalPosition = 0.31
            let backup = try AppSettings.shared.makePreferencesBackupData()

            AppSettings.shared.pluginDockEnabled = true
            AppSettings.shared.pluginDockSide = .right
            AppSettings.shared.pluginDockVerticalPosition = 0.9
            try AppSettings.shared.importPreferencesBackupData(backup)

            XCTAssertFalse(AppSettings.shared.pluginDockEnabled)
            XCTAssertEqual(AppSettings.shared.pluginDockSide, .left)
            XCTAssertEqual(AppSettings.shared.pluginDockVerticalPosition, 0.31, accuracy: 0.0001)
        }
    }

    func testBrowserNavigationClassifiesWebKitInternalSchemesWithoutExternalPrompt() throws {
        XCTAssertEqual(
            BrowserNavigationURLClassifier.classify(try XCTUnwrap(URL(string: "about:blank"))),
            .internalWebKit
        )
        XCTAssertEqual(
            BrowserNavigationURLClassifier.classify(try XCTUnwrap(URL(string: "data:text/html,ready"))),
            .internalWebKit
        )
        XCTAssertEqual(
            BrowserNavigationURLClassifier.classify(try XCTUnwrap(URL(string: "blob:https://linux.do/id"))),
            .internalWebKit
        )
        XCTAssertEqual(
            BrowserNavigationURLClassifier.classify(try XCTUnwrap(URL(string: "https://linux.do/oauth"))),
            .web
        )
        XCTAssertEqual(
            BrowserNavigationURLClassifier.classify(try XCTUnwrap(URL(string: "mailto:test@example.com"))),
            .externalApp
        )
    }

    func testBrowserHistoryIsAccountScopedAndBaseURLIsNormalized() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sam = BrowserHistoryStore(
            baseURL: "HTTPS://LINUX.DO/",
            username: "Sam",
            directoryURL: directory
        )
        try sam.recordVisit(url: URL(string: "https://linux.do/t/one/1")!, title: "One")

        let sameAccount = BrowserHistoryStore(
            baseURL: "https://linux.do",
            username: "sam",
            directoryURL: directory
        )
        let alex = BrowserHistoryStore(
            baseURL: "https://linux.do",
            username: "alex",
            directoryURL: directory
        )

        XCTAssertEqual(sameAccount.history.map(\.title), ["One"])
        XCTAssertTrue(alex.history.isEmpty)
    }

    func testRepeatVisitMovesToFrontAndHistoryIsBounded() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserHistoryStore(
            baseURL: "https://linux.do",
            username: "sam",
            directoryURL: directory,
            maxHistoryCount: 3
        )

        try store.recordVisit(url: URL(string: "https://linux.do/1")!, title: "One", visitedAt: Date(timeIntervalSince1970: 1))
        try store.recordVisit(url: URL(string: "https://linux.do/2")!, title: "Two", visitedAt: Date(timeIntervalSince1970: 2))
        try store.recordVisit(url: URL(string: "https://linux.do/3")!, title: "Three", visitedAt: Date(timeIntervalSince1970: 3))
        try store.recordVisit(url: URL(string: "https://linux.do/4")!, title: "Four", visitedAt: Date(timeIntervalSince1970: 4))
        try store.recordVisit(url: URL(string: "https://linux.do/2")!, title: "Two Updated", visitedAt: Date(timeIntervalSince1970: 5))

        XCTAssertEqual(store.history.map(\.urlString), [
            "https://linux.do/2",
            "https://linux.do/4",
            "https://linux.do/3",
        ])
        XCTAssertEqual(store.history.first?.title, "Two Updated")
    }

    func testBookmarksAreUniqueByNormalizedURL() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserHistoryStore(
            baseURL: "https://linux.do",
            username: "sam",
            directoryURL: directory
        )

        try store.addBookmark(url: URL(string: "https://LINUX.do/t/one/1#post_2")!, title: "One")
        try store.addBookmark(url: URL(string: "https://linux.do/t/one/1")!, title: "One Updated")

        XCTAssertEqual(store.bookmarks.count, 1)
        XCTAssertEqual(store.bookmarks.first?.title, "One Updated")
        XCTAssertEqual(store.bookmarks.first?.urlString, "https://linux.do/t/one/1")
    }

    func testBookmarkRenamePersistsWithoutChangingIdentity() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserHistoryStore(
            baseURL: "https://linux.do",
            username: "sam",
            directoryURL: directory
        )
        try store.addBookmark(url: URL(string: "https://linux.do/t/one/1")!, title: "Original")
        let bookmark = try XCTUnwrap(store.bookmarks.first)

        try store.renameBookmark(bookmark, title: "  Renamed  ")

        let reloaded = BrowserHistoryStore(
            baseURL: "https://linux.do",
            username: "sam",
            directoryURL: directory
        )
        XCTAssertEqual(reloaded.bookmarks.first?.title, "Renamed")
        XCTAssertEqual(reloaded.bookmarks.first?.urlString, bookmark.urlString)
        XCTAssertEqual(reloaded.bookmarks.first?.timestamp, bookmark.timestamp)
    }

    func testCorruptStorageLoadsEmptyAndNextWriteReplacesIt() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: BrowserHistoryStore.storageURL(in: directory), options: .atomic)

        let store = BrowserHistoryStore(
            baseURL: "https://linux.do",
            username: "sam",
            directoryURL: directory
        )
        XCTAssertTrue(store.history.isEmpty)

        try store.recordVisit(url: URL(string: "https://linux.do/latest")!, title: "Latest")

        let reloaded = BrowserHistoryStore(
            baseURL: "https://linux.do",
            username: "sam",
            directoryURL: directory
        )
        XCTAssertEqual(reloaded.history.map(\.title), ["Latest"])
    }

    func testExportHistoryIsAccountScoped() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sam = ExportHistoryStore(
            baseURL: "https://linux.do",
            username: "sam",
            directoryURL: directory
        )
        let record = TopicExportRecord(
            topicId: 17,
            title: "Topic",
            format: .markdown,
            filePath: "/tmp/topic.md",
            postCount: 1,
            timestamp: Date(timeIntervalSince1970: 1),
            errorMessage: nil
        )
        try sam.add(record)

        let sameAccount = ExportHistoryStore(
            baseURL: "HTTPS://LINUX.DO/",
            username: "Sam",
            directoryURL: directory
        )
        let alex = ExportHistoryStore(
            baseURL: "https://linux.do",
            username: "alex",
            directoryURL: directory
        )

        XCTAssertEqual(sameAccount.records.map(\.topicId), [17])
        XCTAssertTrue(alex.records.isEmpty)
    }

    func testTopicExportGeneratesReadableMarkdownAndEscapedHTML() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = TopicExportService(
            baseURL: "https://linux.do",
            username: "sam",
            directoryURL: directory
        )
        let post = try decodePost(
            cooked: "<p>Hello &amp; <strong>world</strong></p>",
            username: "sam & alex"
        )

        let markdownURL = try service.export(
            topicId: 17,
            title: "A & <B>",
            posts: [post],
            format: .markdown,
            range: .loadedPosts
        )
        let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("Hello & world"))
        XCTAssertFalse(markdown.contains("<strong>"))

        let htmlURL = try service.export(
            topicId: 17,
            title: "A & <B>",
            posts: [post],
            format: .html,
            range: .loadedPosts
        )
        let html = try String(contentsOf: htmlURL, encoding: .utf8)
        XCTAssertTrue(html.contains("<title>A &amp; &lt;B&gt;</title>"))
        XCTAssertTrue(html.contains("sam &amp; alex"))
        XCTAssertTrue(html.contains("<strong>world</strong>"))
    }

    private func decodePost(cooked: String, username: String) throws -> DiscourseTopicDetail.Post {
        let object: [String: Any] = [
            "id": 1,
            "username": username,
            "created_at": "2026-07-10T00:00:00.000Z",
            "cooked": cooked,
            "post_number": 1,
            "reply_count": 0,
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(DiscourseTopicDetail.Post.self, from: data)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("doer-store-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func withPreservedPluginDockDefaults<T>(_ operation: () throws -> T) rethrows -> T {
        let defaults = UserDefaults.standard
        let storedValues = Dictionary(uniqueKeysWithValues: pluginDockDefaultsKeys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            for key in pluginDockDefaultsKeys {
                if let value = storedValues[key] ?? nil {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        return try operation()
    }

    private func withPreservedUpdateDefaults<T>(_ operation: () throws -> T) rethrows -> T {
        let defaults = UserDefaults.standard
        let storedValues = Dictionary(uniqueKeysWithValues: updateDefaultsKeys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            for key in updateDefaultsKeys {
                if let value = storedValues[key] ?? nil {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        return try operation()
    }
}

@MainActor
final class ObservableInfrastructureTests: XCTestCase {
    func testObservablePublisherIsScopedToTheChangedInstance() {
        let first = DoerObservableObject()
        let second = DoerObservableObject()
        var firstUpdateCount = 0
        var secondUpdateCount = 0
        let firstToken = first.objectWillChange.sink { firstUpdateCount += 1 }
        let secondToken = second.objectWillChange.sink { secondUpdateCount += 1 }
        defer {
            firstToken.cancel()
            secondToken.cancel()
        }

        first.notifyChanged()

        XCTAssertEqual(firstUpdateCount, 1)
        XCTAssertEqual(secondUpdateCount, 0)
    }

    func testObservableViewControllerOnlyUpdatesForRegisteredObjects() async {
        let observed = DoerObservableObject()
        let unrelated = DoerObservableObject()
        let controller = TrackingObservableViewController()
        controller.observe(observed)
        controller.observe(observed)

        controller.startObserving()
        XCTAssertEqual(controller.updateCount, 1)

        unrelated.notifyChanged()
        await flushMainQueue()
        XCTAssertEqual(controller.updateCount, 1)

        observed.notifyChanged()
        XCTAssertEqual(controller.updateCount, 1, "UISwitch callbacks must not rebuild synchronously")
        await flushMainQueue()
        XCTAssertEqual(controller.updateCount, 2)
    }

    func testObservableViewControllerStopsUpdatingAfterDisappearing() async {
        let observed = DoerObservableObject()
        let controller = TrackingObservableViewController()
        controller.observe(observed)
        controller.startObserving()

        controller.viewWillDisappear(false)
        observed.notifyChanged()
        await flushMainQueue()

        XCTAssertEqual(controller.updateCount, 1)
    }

    private func flushMainQueue() async {
        let flushed = expectation(description: "main queue flushed")
        DispatchQueue.main.async {
            flushed.fulfill()
        }
        await fulfillment(of: [flushed], timeout: 1)
    }

    func testNotifyChangedPublishesOnMainThread() async {
        let observable = DoerObservableObject()
        let published = expectation(description: "objectWillChange published")
        var publishedOnMainThread = false
        let token = observable.objectWillChange.sink {
            publishedOnMainThread = Thread.isMainThread
            published.fulfill()
        }
        defer { token.cancel() }

        await Task.detached {
            await observable.notifyChanged()
        }.value
        await fulfillment(of: [published], timeout: 1)

        XCTAssertTrue(publishedOnMainThread)
    }
}

@MainActor
private final class TrackingObservableViewController: ObservableViewController {
    private(set) var updateCount = 0

    override func updateUI() {
        updateCount += 1
    }
}
