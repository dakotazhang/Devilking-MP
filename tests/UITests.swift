import XCTest
import UIKit
import CoreFoundation

final class UITests: XCTestCase {
    private func launchFixture(arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"] + arguments
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["仪表盘"].waitForExistence(timeout: 15))
        return app
    }

    func testEveryTabRendersSyntheticDataAndRespectsStatusBar() throws {
        let app = launchFixture()
        let tabs = [("01-dashboard", "仪表盘"), ("02-downloaders", "下载器"), ("03-discovery", "发现"), ("04-subscriptions", "订阅"), ("05-settings", "设置")]
        for (name, label) in tabs {
            let button = app.tabBars.buttons[label]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            button.tap()
            XCTAssertTrue(app.navigationBars[label].waitForExistence(timeout: 5))
            assertButtonsBelowStatusBar(app)
            try attachRenderedScreenshot(app, name: name)
        }
        XCTAssertFalse(app.tabBars.buttons["片库"].exists)
        XCTAssertFalse(app.tabBars.buttons["MP"].exists)
    }

    func testDiscoverySearchSeriesSelectionStaysReadOnly() throws {
        let app = launchFixture()
        app.tabBars.buttons["发现"].tap()
        XCTAssertTrue(app.staticTexts["豆瓣正在热映"].waitForExistence(timeout: 5))
        let movies = app.buttons["discovery.category.movie"]
        XCTAssertTrue(movies.waitForExistence(timeout: 5))
        movies.tap()
        XCTAssertTrue(app.buttons["discovery.media.990001"].waitForExistence(timeout: 5))
        app.buttons["discovery.category.all"].tap()

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("星河守望\n")
        let result = app.buttons["discovery.media.990005"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["discovery.media.990001"].exists)
        try attachRenderedScreenshot(app, name: "06-discovery-search")
        result.tap()
        XCTAssertTrue(app.staticTexts["media.detail.title"].waitForExistence(timeout: 5))
        assertButtonsBelowStatusBar(app)

        let picker = app.buttons["media.seasonPicker"]
        reveal(picker, in: app)
        XCTAssertTrue(picker.exists)
        picker.tap()
        let firstSeason = app.buttons.matching(identifier: "第一季").firstMatch
        XCTAssertTrue(firstSeason.waitForExistence(timeout: 5))
        firstSeason.tap()
        XCTAssertTrue(app.staticTexts["media.selectedSeason"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["media.selectedSeason"].label, "第一季 · 12 集")

        let subscribe = app.buttons["media.subscribe"]
        reveal(subscribe, in: app)
        XCTAssertTrue(subscribe.exists)
        XCTAssertFalse(subscribe.isEnabled, "A read-only app must not enable subscription creation after selecting a season")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "media.detail.readonly").firstMatch.exists)
        XCTAssertFalse(app.alerts["确认新增订阅？"].exists)
        try attachRenderedScreenshot(app, name: "07-series-readonly")

    }

    func testSubscriptionsSearchAndPausedFilter() throws {
        let app = launchFixture()
        app.tabBars.buttons["订阅"].tap()
        let filters = app.segmentedControls["subscriptions.filter"]
        XCTAssertTrue(filters.waitForExistence(timeout: 5))
        filters.buttons["已暂停"].tap()
        XCTAssertTrue(app.staticTexts["合成暂停 · 山川回声"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["合成追订 · 海港来信"].exists)
        let resume = app.buttons["subscription.action.88002"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        XCTAssertFalse(resume.isEnabled)
        try attachRenderedScreenshot(app, name: "08-subscriptions-paused")

        filters.buttons["全部"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("海港\n")
        XCTAssertTrue(app.staticTexts["合成追订 · 海港来信"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["合成暂停 · 山川回声"].exists)
        XCTAssertFalse(app.buttons["subscription.action.88001"].isEnabled)
        try attachRenderedScreenshot(app, name: "09-subscriptions-search")
    }

    func testEmptyDiscoveryRefreshRemainsUsable() throws {
        let app = launchFixture(arguments: ["--ui-fixture-empty-discovery"])
        app.tabBars.buttons["发现"].tap()
        XCTAssertTrue(app.staticTexts["暂无推荐资料"].waitForExistence(timeout: 5))
        let refresh = app.buttons["discovery.refresh"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 5))
        XCTAssertTrue(refresh.isEnabled)
        refresh.tap()
        XCTAssertTrue(refresh.isEnabled, "A completed refresh must not leave a permanent spinner or disabled button")
        let page = app.scrollViews.firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        page.swipeDown()
        XCTAssertTrue(app.staticTexts["暂无推荐资料"].waitForExistence(timeout: 5))
        XCTAssertTrue(refresh.isEnabled)
        assertButtonsBelowStatusBar(app)
        try attachRenderedScreenshot(app, name: "10-empty-discovery-refresh")
    }

    func testStationResourceSearchRequiresSelectionAndDownloadStaysReadOnly() throws {
        let app = launchFixture()
        app.tabBars.buttons["发现"].tap()
        let modes = app.segmentedControls["discovery.searchMode"]
        XCTAssertTrue(modes.waitForExistence(timeout: 5))
        modes.buttons["PT资源"].tap()
        let query = app.textFields["resources.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        query.tap()
        query.typeText("星海远航\n")
        let search = app.buttons["resources.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertFalse(search.isEnabled, "An unselected station list must never trigger all-site searches")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "resources.result.")).firstMatch.exists)
        let site = app.buttons["resources.site.1"]
        reveal(site, in: app)
        XCTAssertTrue(site.waitForExistence(timeout: 5))
        site.tap()
        // Selecting a station only changes local form state.
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "resources.result.")).firstMatch.exists)
        reveal(search, in: app)
        XCTAssertTrue(search.isEnabled)
        search.tap()
        let result = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "resources.result.")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        reveal(result, in: app)
        try attachRenderedScreenshot(app, name: "11-station-resource-results")
        result.tap()
        XCTAssertTrue(app.navigationBars["资源详情"].waitForExistence(timeout: 5))
        let downloader = app.buttons["resources.downloader"]
        reveal(downloader, in: app)
        XCTAssertTrue(downloader.waitForExistence(timeout: 5))
        downloader.tap()
        let target = app.buttons.matching(identifier: "合成主力下载器").firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        target.tap()
        XCTAssertTrue(app.buttons["resources.directory"].exists)
        let download = app.buttons["resources.download"]
        reveal(download, in: app)
        XCTAssertTrue(download.exists)
        XCTAssertFalse(download.isEnabled, "A read-only app must not create torrent downloads after choosing a destination")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "resources.readonly").firstMatch.exists)
        XCTAssertFalse(app.alerts["确认新增下载任务？"].exists)
        assertButtonsBelowStatusBar(app)
        try attachRenderedScreenshot(app, name: "12-resource-download-readonly")
    }

    func testDisplaySettingsChangeOnlyLocalPresentation() throws {
        let app = launchFixture()
        app.tabBars.buttons["设置"].tap()
        let refresh = app.buttons["settings.refreshInterval"]
        reveal(refresh, in: app)
        XCTAssertTrue(refresh.waitForExistence(timeout: 5))
        refresh.tap()
        app.buttons.matching(identifier: "关闭自动刷新").firstMatch.tap()
        let theme = app.buttons["settings.theme"]
        reveal(theme, in: app)
        theme.tap()
        app.buttons.matching(identifier: "浅色").firstMatch.tap()
        try attachRenderedScreenshot(app, name: "13-settings-light-appearance")

        let storage = app.switches["settings.module.storage"]
        reveal(storage, in: app)
        XCTAssertTrue(storage.waitForExistence(timeout: 5))
        XCTAssertEqual(storage.value as? String, "1")
        storage.tap()
        app.tabBars.buttons["仪表盘"].tap()
        XCTAssertTrue(app.staticTexts["仅手动刷新 · 默认只读"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["磁盘余量"].exists)
        XCTAssertTrue(app.buttons["dashboard.refresh"].isEnabled)
        try attachRenderedScreenshot(app, name: "14-dashboard-local-module-settings")

        app.tabBars.buttons["设置"].tap()
        reveal(storage, in: app)
        storage.tap()
        reveal(refresh, in: app)
        refresh.tap()
        app.buttons.matching(identifier: "60 秒").firstMatch.tap()
        reveal(theme, in: app)
        theme.tap()
        app.buttons.matching(identifier: "跟随系统").firstMatch.tap()
        let language = app.buttons["settings.language"]
        reveal(language, in: app)
        language.tap()
        app.buttons.matching(identifier: "English").firstMatch.tap()
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 5))
        reveal(language, in: app)
        language.tap()
        app.buttons.matching(identifier: "简体中文").firstMatch.tap()
        XCTAssertTrue(app.tabBars.buttons["设置"].waitForExistence(timeout: 5))
        app.tabBars.buttons["仪表盘"].tap()
        let diskTitle = app.staticTexts["磁盘余量"]
        reveal(diskTitle, in: app)
        XCTAssertTrue(diskTitle.exists)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<5 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            app.swipeDown()
        }
    }

    /// Check real accessibility element geometry, not a fabricated preview.
    /// Navigation minY is a fallback only when the simulator hides status-bar
    /// accessibility; it is the system's safe-area boundary for that screen.
    private func assertButtonsBelowStatusBar(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let status = app.statusBars.firstMatch
        let navigation = app.navigationBars.firstMatch
        let boundary: CGFloat
        if status.exists && status.frame.height > 0 { boundary = status.frame.maxY }
        else if navigation.exists && navigation.frame.minY > 0 { boundary = navigation.frame.minY }
        else { boundary = app.windows.firstMatch.frame.minY + 44 }
        let buttons = app.buttons.allElementsBoundByIndex.filter { $0.isHittable && $0.frame.height > 0 }
        XCTAssertFalse(buttons.isEmpty, file: file, line: line)
        for button in buttons {
            XCTAssertGreaterThanOrEqual(button.frame.minY, boundary - 1,
                                       "Control overlaps the status bar: \(button.identifier) / \(button.label)", file: file, line: line)
        }
    }

    private func attachRenderedScreenshot(_ app: XCUIApplication, name: String) throws {
        let shot = app.screenshot()
        guard let image = shot.image.cgImage, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            XCTFail("No screenshot pixel data"); return
        }
        var colors = Set<UInt32>()
        let count = CFDataGetLength(data), pixel = max(4, image.bitsPerPixel / 8)
        for index in stride(from: 0, to: max(0, count - 4), by: pixel * 31) {
            colors.insert(UInt32(bytes[index]) << 16 | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2]))
            if colors.count > 20 { break }
        }
        XCTAssertGreaterThan(colors.count, 10, "Rendered UI must not be blank")
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
