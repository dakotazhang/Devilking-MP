import XCTest
import UIKit
import CoreFoundation

final class UITests: XCTestCase {
    private func launchFixture(arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"] + arguments
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["状态表"].waitForExistence(timeout: 15))
        return app
    }

    func testEveryTabRendersSyntheticDataAndRespectsStatusBar() throws {
        let app = launchFixture()
        let tabs = [("01-dashboard", "状态表", "rem"), ("02-downloaders", "下载器", "emilia"), ("03-discovery", "发现", "ram"), ("04-subscriptions", "订阅", "beatrice"), ("05-settings", "设置", "echidna")]
        for (name, label, character) in tabs {
            let button = app.tabBars.buttons[label]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            button.tap()
            XCTAssertTrue(app.navigationBars[label].waitForExistence(timeout: 5))
            let header = app.descendants(matching: .any).matching(identifier: "character.header." + character).firstMatch
            if character == "rem" {
                XCTAssertTrue(header.waitForExistence(timeout: 5))
                XCTAssertGreaterThan(header.frame.height, 100)
                assertHomeTitleInsideVisibleHeader(in: app, header: header)
            } else {
                XCTAssertFalse(header.exists, "Only the status page reserves a character header; other pages use a background")
            }
            if label == "设置" {
                let about = app.buttons["settings.about"]
                let servers = app.buttons["settings.servers"]
                XCTAssertTrue(about.isHittable, "About belongs on the initial settings screen")
                XCTAssertLessThan(about.frame.maxY, servers.frame.minY)
                let importConnection = app.buttons["从文件导入连接配置"]
                let privacyDetail = app.staticTexts["App 直连你配置的服务器，无中转后台、统计 SDK 或广告。使用内网地址时，请先连接自己的 VPN。MP 资料与站点请求由你的服务端处理。"]
                XCTAssertTrue(importConnection.exists)
                XCTAssertTrue(privacyDetail.exists)
                XCTAssertGreaterThan(importConnection.frame.minY, privacyDetail.frame.maxY,
                                     "The complete connection-import card belongs after privacy at the bottom")
            }
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
        XCTAssertTrue(app.staticTexts["数据刷新频率"].isHittable, "Refresh interval must have a visible row label, not only the selected value")
        refresh.tap()
        app.buttons.matching(identifier: "关闭自动刷新").firstMatch.tap()
        let theme = app.buttons["settings.theme"]
        reveal(theme, in: app)
        XCTAssertTrue(app.staticTexts["外观主题"].isHittable)
        theme.tap()
        app.buttons.matching(identifier: "浅色").firstMatch.tap()
        try attachRenderedScreenshot(app, name: "13-settings-light-appearance")

        let storage = app.switches["settings.module.storage"]
        reveal(storage, in: app)
        XCTAssertTrue(storage.waitForExistence(timeout: 5))
        XCTAssertEqual(storage.value as? String, "1")
        storage.tap()
        app.tabBars.buttons["状态表"].tap()
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
        XCTAssertTrue(app.staticTexts["应用语言"].isHittable)
        language.tap()
        app.buttons.matching(identifier: "English (US)").firstMatch.tap()
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 5))
        reveal(language, in: app)
        XCTAssertTrue(app.staticTexts["App language"].isHittable)
        language.tap()
        app.buttons.matching(identifier: "简体中文").firstMatch.tap()
        XCTAssertTrue(app.tabBars.buttons["设置"].waitForExistence(timeout: 5))
        app.tabBars.buttons["状态表"].tap()
        let diskTitle = app.staticTexts["磁盘余量"]
        reveal(diskTitle, in: app)
        XCTAssertTrue(diskTitle.exists)
    }

    func testCharacterBackgroundTogglePreservesForegroundPostersAndControls() throws {
        let app = launchFixture()
        let header = app.descendants(matching: .any).matching(identifier: "character.header.rem").firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(header.frame.height, 100)
        assertHomeTitleInsideVisibleHeader(in: app, header: header)
        let enabledDashboard = app.screenshot()
        app.tabBars.buttons["发现"].tap()
        let poster = app.buttons["discovery.media.990001"]
        XCTAssertTrue(poster.waitForExistence(timeout: 5))
        let renderedPoster = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "discovery.media.990001", "合成海报已载入")).firstMatch
        XCTAssertTrue(renderedPoster.waitForExistence(timeout: 5), "The synthetic poster must be decoded and rendered, not a placeholder")
        try attachRenderedScreenshot(app, name: "15-background-with-foreground-posters")
        app.tabBars.buttons["订阅"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "合成海报已载入")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["subscription.action.88001"].isEnabled)
        app.tabBars.buttons["设置"].tap()
        let toggle = app.switches["settings.characterBackgrounds"]
        reveal(toggle, in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.tap()
        app.tabBars.buttons["状态表"].tap()
        XCTAssertTrue(app.buttons["dashboard.refresh"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["dashboard.refresh"].isEnabled)
        XCTAssertFalse(header.exists, "Turning backgrounds off must also remove the reserved character area")
        XCTAssertFalse(app.staticTexts["character.homeTitle"].exists)
        let disabledDashboard = app.screenshot()
        XCTAssertGreaterThan(changedPixelFraction(enabledDashboard, disabledDashboard), 0.005,
                             "Turning off character backgrounds must visibly remove the decorative layer")
        assertButtonsBelowStatusBar(app)
        try attachRenderedScreenshot(app, name: "16-background-disabled-dashboard")
        app.tabBars.buttons["发现"].tap()
        XCTAssertTrue(poster.waitForExistence(timeout: 5))
        XCTAssertTrue(renderedPoster.waitForExistence(timeout: 5))
        poster.tap()
        XCTAssertTrue(app.staticTexts["media.detail.title"].waitForExistence(timeout: 5))
        let subscribe = app.buttons["media.subscribe"]
        reveal(subscribe, in: app)
        XCTAssertFalse(subscribe.isEnabled)
    }

    func testGroupsFilterStatusAndTasksWithAutoRefreshDisabled() throws {
        let app = launchFixture(arguments: ["--ui-fixture-slow-tasks"])
        app.tabBars.buttons["设置"].tap()
        let interval = app.buttons["settings.refreshInterval"]
        reveal(interval, in: app)
        XCTAssertTrue(interval.waitForExistence(timeout: 5))
        interval.tap()
        app.buttons.matching(identifier: "关闭自动刷新").firstMatch.tap()
        app.tabBars.buttons["状态表"].tap()
        selectGroup("家庭", scopeID: "servers.groupScope.status", in: app)
        XCTAssertTrue(app.buttons["dashboard.server.qb1"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["dashboard.server.qb:11111111-1111-4111-8111-111111111111"].exists)
        try attachRenderedScreenshot(app, name: "17-home-group-status")

        // Switching to tasks preserves the status page's selected group.
        app.tabBars.buttons["下载器"].tap()
        XCTAssertTrue(app.buttons["downloaders.service.qb1"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["downloaders.service.qb:11111111-1111-4111-8111-111111111111"].exists)
        let homeTaskID = "downloaders.task.qb1:" + String(repeating: "1", count: 40)
        XCTAssertTrue(app.buttons[homeTaskID].waitForExistence(timeout: 5))
        let reading = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == false"), object: app.buttons["downloaders.refresh"])
        XCTAssertEqual(XCTWaiter.wait(for: [reading], timeout: 5), .completed)
        // Change scope while the bounded fixture read may still be finishing.
        selectGroup("刷流", scopeID: "servers.groupScope.downloaders", in: app)
        let fleetQBID = "qb:11111111-1111-4111-8111-111111111111"
        let fleetTRID = "tr:22222222-2222-4222-8222-222222222222"
        XCTAssertTrue(app.buttons["downloaders.service." + fleetQBID].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["downloaders.service." + fleetTRID].exists)
        XCTAssertFalse(app.buttons["downloaders.service.qb1"].exists)
        XCTAssertFalse(app.buttons[homeTaskID].exists)
        let fleetTaskID = "downloaders.task." + fleetQBID + ":" + String(repeating: "1", count: 40)
        XCTAssertTrue(app.buttons[fleetTaskID].waitForExistence(timeout: 10))
        let refresh = app.buttons["downloaders.refresh"]
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: refresh)
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 15), .completed,
                       "The newly selected scope must finish its read even when auto-refresh is off")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "合成刷流 qB 列表读取于")).firstMatch.exists)
        try attachRenderedScreenshot(app, name: "18-fleet-group-tasks")

        let task = app.buttons[fleetTaskID]
        reveal(task, in: app)
        XCTAssertTrue(task.label.contains("合成站点"), "qB's existing category remains visible alongside its labels")
        XCTAssertTrue(task.label.contains("合成标签 qB · 片库保种 · keep · IYUU"),
                      "Ordinary labels keep their order and maintenance labels do not occupy the front")

        let seedingFilter = app.buttons["downloaders.filter.seeding"]
        reveal(seedingFilter, in: app, towardTop: true)
        seedingFilter.tap()
        let trSeed = app.buttons["downloaders.task." + fleetTRID + ":" + String(repeating: "7", count: 40)]
        reveal(trSeed, in: app)
        XCTAssertTrue(trSeed.label.contains("正在做种"))
        XCTAssertTrue(trSeed.label.contains("合成标签 TR · 长期保种 · keep · IYUU"),
                      "TR's existing labels must also be shown for complete seeding tasks")
        try attachRenderedScreenshot(app, name: "22-tr-seeding-existing-labels")

        let verifyingFilter = app.buttons["downloaders.filter.verifying"]
        reveal(verifyingFilter, in: app, towardTop: true)
        verifyingFilter.tap()
        let qbChecking = app.buttons["downloaders.task." + fleetQBID + ":" + String(repeating: "3", count: 40)]
        reveal(qbChecking, in: app)
        XCTAssertTrue(qbChecking.label.contains("合成标签 qB · 片库保种 · keep · IYUU"))
        let trChecking = app.buttons["downloaders.task." + fleetTRID + ":" + String(repeating: "8", count: 40)]
        reveal(trChecking, in: app)
        XCTAssertTrue(trChecking.label.contains("合成标签 TR · 长期保种 · keep · IYUU"))
        let allFilter = app.buttons["downloaders.filter.all"]
        reveal(allFilter, in: app, towardTop: true)
        allFilter.tap()

        // A task-detail read never enables a write in this fixture.
        reveal(task, in: app)
        task.tap()
        XCTAssertTrue(app.navigationBars["任务详情"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["合成刷流 qB"].exists)
        XCTAssertTrue(app.staticTexts["keep、IYUU、合成标签 qB、片库保种、合成标签 qB"].exists,
                      "Details preserve the complete original labels, including values deduplicated only for the compact list")
        let startStop = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "启动此任务", "停止此任务")).firstMatch
        reveal(startStop, in: app)
        XCTAssertFalse(startStop.isEnabled)
    }

    func testConnectionLifecycleKeepsCredentialsAndGroupsDoNotRemoveServers() throws {
        let app = launchFixture()
        app.tabBars.buttons["设置"].tap()
        XCTAssertFalse(app.staticTexts["dk(dakotazhang)"].exists, "Author information belongs only to About")
        let serverSettings = app.buttons["settings.servers"]
        reveal(serverSettings, in: app)
        serverSettings.tap()
        XCTAssertTrue(app.navigationBars["服务器设置"].waitForExistence(timeout: 5))
        let homeConnection = app.buttons["servers.connection.qb1"]
        reveal(homeConnection, in: app)
        XCTAssertTrue(homeConnection.waitForExistence(timeout: 5))
        homeConnection.tap()
        let toggle = app.buttons["server.toggleConnection"]
        reveal(toggle, in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.label, "断开连接")
        let clearCredentials = app.buttons["server.clearCredentials"]
        reveal(clearCredentials, in: app)
        XCTAssertTrue(clearCredentials.exists)
        reveal(toggle, in: app)
        toggle.tap()
        XCTAssertEqual(toggle.label, "连接")
        reveal(clearCredentials, in: app)
        XCTAssertTrue(clearCredentials.exists,
                      "Disconnect must retain credentials; clearing them is a separate action")
        reveal(toggle, in: app)
        toggle.tap()
        XCTAssertEqual(toggle.label, "断开连接")
        XCTAssertTrue(app.buttons["server.clearCredentials"].exists)
        try attachRenderedScreenshot(app, name: "19-reconnected-credentials-retained")
        app.navigationBars.firstMatch.buttons["取消"].tap()
        XCTAssertTrue(app.navigationBars["服务器设置"].waitForExistence(timeout: 5))
        app.navigationBars["服务器设置"].buttons.element(boundBy: 0).tap()

        let groups = app.buttons["settings.groups"]
        reveal(groups, in: app)
        groups.tap()
        XCTAssertTrue(app.navigationBars["服务器分组"].waitForExistence(timeout: 5))
        let deleteHome = app.buttons.matching(NSPredicate(format: "label == %@", "删除分组：家庭")).firstMatch
        reveal(deleteHome, in: app)
        XCTAssertTrue(deleteHome.waitForExistence(timeout: 5))
        deleteHome.tap()
        XCTAssertTrue(app.alerts["删除这个分组？"].waitForExistence(timeout: 5))
        app.alerts["删除这个分组？"].buttons["删除分组"].tap()
        XCTAssertFalse(deleteHome.exists)
        app.navigationBars["服务器分组"].buttons.element(boundBy: 0).tap()
        reveal(serverSettings, in: app)
        serverSettings.tap()
        XCTAssertTrue(homeConnection.waitForExistence(timeout: 5), "Deleting a group must retain its server connections")
        let fleetConnection = app.buttons["servers.connection.qb:11111111-1111-4111-8111-111111111111"]
        XCTAssertTrue(fleetConnection.exists)
        try attachRenderedScreenshot(app, name: "20-servers-retained-after-group-delete")
        app.navigationBars["服务器设置"].buttons.element(boundBy: 0).tap()
        let about = app.buttons["settings.about"]
        reveal(about, in: app, towardTop: true)
        about.tap()
        XCTAssertTrue(app.navigationBars["关于"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["dk(dakotazhang)"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["口袋蕾姆"].exists)
        try attachRenderedScreenshot(app, name: "21-about-pocket-rem")

        // A new draft has no usable example endpoint. Changing its protocol
        // must discard draft credentials before any connection can be saved.
        app.navigationBars["关于"].buttons.element(boundBy: 0).tap()
        reveal(serverSettings, in: app)
        serverSettings.tap()
        XCTAssertTrue(app.navigationBars["服务器设置"].waitForExistence(timeout: 5))
        let serverRows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "servers.connection."))
        let serverCountBeforeDraft = serverRows.count
        let addServer = app.buttons["settings.addServer"]
        reveal(addServer, in: app)
        addServer.tap()
        XCTAssertTrue(app.navigationBars["添加服务器"].waitForExistence(timeout: 5))
        let draftAddress = app.textFields["server.address"]
        let draftUsername = app.textFields["server.username"]
        let draftPassword = app.secureTextFields["server.password"]
        let saveDraft = app.buttons["server.save"]
        guard revealDraftControl(draftAddress, in: app) else { return }
        assertEmptyField(draftAddress)
        draftAddress.tap()
        draftAddress.typeText("https://draft.example.invalid")
        XCTAssertEqual(draftAddress.value as? String, "https://draft.example.invalid")
        guard dismissDraftKeyboard(in: app) else { return }
        guard revealDraftControl(draftUsername, in: app) else { return }
        draftUsername.tap()
        draftUsername.typeText("synthetic-qb-user")
        XCTAssertEqual(draftUsername.value as? String, "synthetic-qb-user")
        guard dismissDraftKeyboard(in: app) else { return }
        guard revealDraftControl(draftPassword, in: app) else { return }
        draftPassword.tap()
        draftPassword.typeText("synthetic-qb-password")
        let passwordValue = draftPassword.value as? String ?? ""
        XCTAssertFalse(passwordValue.isEmpty || passwordValue == draftPassword.placeholderValue,
                       "The draft must contain the synthetic password before changing type")
        guard dismissDraftKeyboard(in: app) else { return }
        let draftType = app.buttons["server.type"]
        guard revealDraftControl(draftType, minimumHeight: 44, towardTopIfMissing: true, in: app) else { return }
        draftType.tap()
        let transmissionOptions = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "server.type.option.transmission", "Transmission"))
        let transmission = transmissionOptions.firstMatch
        XCTAssertTrue(transmission.waitForExistence(timeout: 5))
        XCTAssertEqual(transmissionOptions.count, 1)
        XCTAssertTrue(transmission.isHittable)
        transmission.tap()
        XCTAssertEqual(draftType.value as? String, "Transmission", "The actual draft protocol must change")
        guard revealDraftControl(draftAddress, in: app) else { return }
        assertEmptyField(draftAddress)
        guard revealDraftControl(draftUsername, in: app) else { return }
        assertEmptyField(draftUsername)
        guard revealDraftControl(draftPassword, in: app) else { return }
        assertEmptyField(draftPassword)
        guard revealDraftControl(saveDraft, requiresHittable: false, in: app) else { return }
        XCTAssertFalse(saveDraft.isEnabled, "An empty new endpoint must prevent saving or connecting")
        app.navigationBars["添加服务器"].buttons["取消"].tap()
        XCTAssertTrue(app.navigationBars["服务器设置"].waitForExistence(timeout: 5))
        XCTAssertEqual(serverRows.count, serverCountBeforeDraft,
                       "Canceling a draft must not create a server or submit a network request")
    }

    private func assertHomeTitleInsideVisibleHeader(in app: XCUIApplication, header: XCUIElement,
                                                    file: StaticString = #filePath, line: UInt = #line) {
        let title = app.staticTexts["character.homeTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertEqual(title.label, "口袋蕾姆", "Read the real title Text, not a container label", file: file, line: line)
        XCTAssertGreaterThanOrEqual(title.frame.width, 80, file: file, line: line)
        XCTAssertGreaterThanOrEqual(title.frame.height, 24, file: file, line: line)
        XCTAssertGreaterThanOrEqual(title.frame.minX, header.frame.minX, file: file, line: line)
        XCTAssertLessThanOrEqual(title.frame.maxX, header.frame.maxX, file: file, line: line)
        XCTAssertGreaterThanOrEqual(title.frame.minY, header.frame.minY, file: file, line: line)
        XCTAssertLessThanOrEqual(title.frame.maxY, header.frame.maxY,
                                 "The title must not be clipped below the 128pt header", file: file, line: line)
        XCTAssertGreaterThanOrEqual(title.frame.minY, app.navigationBars["状态表"].frame.maxY, file: file, line: line)
        XCTAssertTrue(header.frame.insetBy(dx: -0.5, dy: -0.5).contains(title.frame),
                      "The rendered Text bounds must be fully inside the visible header", file: file, line: line)
    }

    /// Finish each field through the real keyboard accessory before any Form
    /// scrolling, so a whole-app swipe cannot land on the keyboard instead.
    private func dismissDraftKeyboard(in app: XCUIApplication,
                                      file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return true }
        let done = app.buttons["server.dismissKeyboard"]
        guard done.waitForExistence(timeout: 5) else {
            XCTFail("The draft keyboard must expose its Done button", file: file, line: line)
            return false
        }
        XCTAssertTrue(done.isHittable, file: file, line: line)
        guard done.isHittable else { return false }
        done.tap()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: keyboard)
        let result = XCTWaiter.wait(for: [hidden], timeout: 5)
        XCTAssertEqual(result, .completed, "Dismiss the keyboard before scrolling the draft form", file: file, line: line)
        return result == .completed
    }

    /// A Form row may report hittable even underneath the navigation bar or
    /// keyboard accessory. Only these new-draft controls use the stricter path.
    private func revealDraftControl(_ element: XCUIElement, minimumHeight: CGFloat = 1,
                                    towardTopIfMissing: Bool = false, requiresHittable: Bool = true,
                                    in app: XCUIApplication,
                                    file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let navigation = app.navigationBars["添加服务器"]
        guard navigation.waitForExistence(timeout: 5) else {
            XCTFail("The draft navigation bar is missing", file: file, line: line); return false
        }
        for _ in 0..<12 {
            let bounds = draftVisibleBounds(navigationBar: navigation, in: app)
            if element.exists {
                let frame = element.frame
                if frame.height >= minimumHeight && frame.minY >= bounds.top
                    && frame.maxY <= bounds.bottom && (!requiresHittable || element.isHittable) { break }
                if frame.minY < bounds.top { app.swipeDown() }
                else if frame.maxY > bounds.bottom { app.swipeUp() }
                else { break } // A genuinely unreachable visible control must fail below.
            } else if towardTopIfMissing {
                app.swipeDown()
            } else {
                app.swipeUp()
            }
        }
        guard element.exists else {
            XCTFail("The draft control is missing", file: file, line: line); return false
        }
        let bounds = draftVisibleBounds(navigationBar: navigation, in: app)
        let frame = element.frame
        let hittable = !requiresHittable || element.isHittable
        XCTAssertGreaterThanOrEqual(frame.height, minimumHeight, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minY, bounds.top,
                                    "The draft control must be fully below the navigation bar", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, bounds.bottom,
                                 "The draft control must be fully above the keyboard and its toolbar", file: file, line: line)
        if requiresHittable { XCTAssertTrue(hittable, file: file, line: line) }
        return frame.height >= minimumHeight && frame.minY >= bounds.top && frame.maxY <= bounds.bottom && hittable
    }

    private func draftVisibleBounds(navigationBar: XCUIElement, in app: XCUIApplication) -> (top: CGFloat, bottom: CGFloat) {
        let margin: CGFloat = 10
        let top = navigationBar.frame.maxY + margin
        var bottom = app.windows.firstMatch.frame.maxY - margin
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            bottom = min(bottom, keyboard.frame.minY - margin)
            let doneToolbar = app.toolbars.containing(.button, identifier: "server.dismissKeyboard").firstMatch
            if doneToolbar.exists { bottom = min(bottom, doneToolbar.frame.minY - margin) }
            let done = app.buttons["server.dismissKeyboard"]
            if done.exists { bottom = min(bottom, done.frame.minY - margin) }
        }
        return (top, bottom)
    }

    private func assertEmptyField(_ field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(field.exists, file: file, line: line)
        guard let value = field.value as? String else {
            XCTFail("The input field did not expose its text value", file: file, line: line)
            return
        }
        // UIKit may expose either an empty string or the placeholder for an
        // empty input. Secure fields expose bullets for nonempty contents.
        XCTAssertTrue(value.isEmpty || value == field.placeholderValue,
                      "The input must have no draft contents", file: file, line: line)
    }

    private func selectGroup(_ name: String, scopeID: String, in app: XCUIApplication) {
        let scope = app.buttons[scopeID]
        reveal(scope, in: app)
        XCTAssertTrue(scope.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: scopeID).count, 1,
                       "Each page must expose a unique scope control")
        XCTAssertGreaterThanOrEqual(scope.frame.height, 44)
        XCTAssertTrue(scope.isHittable, "The scope control must be a reachable real menu button")
        scope.tap()
        let choice = app.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
    }

    private func raster(_ screenshot: XCUIScreenshot, region: CGRect? = nil) -> [UInt8] {
        guard let original = screenshot.image.cgImage else { return [] }
        let source: CGImage
        if let region {
            let scale = CGFloat(original.width) / screenshot.image.size.width
            guard let crop = original.cropping(to: CGRect(x: region.minX * scale, y: region.minY * scale,
                                                         width: region.width * scale, height: region.height * scale)) else { return [] }
            source = crop
        } else { source = original }
        let width = 64, height = min(256, max(1, Int(Double(source.height) / Double(source.width) * 64)))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.draw(source, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        }
        return pixels
    }

    private func changedPixelFraction(_ first: XCUIScreenshot, _ second: XCUIScreenshot) -> Double {
        let left = raster(first), right = raster(second)
        guard !left.isEmpty, left.count == right.count else { return 0 }
        var changed = 0
        for index in stride(from: 0, to: left.count - 3, by: 4) {
            let delta = (0..<3).map { abs(Int(left[index + $0]) - Int(right[index + $0])) }.max() ?? 0
            if delta > 10 { changed += 1 }
        }
        return Double(changed) / Double(left.count / 4)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false) {
        for _ in 0..<(towardTop ? 8 : 5) {
            if element.exists && element.isHittable { return }
            if towardTop { app.swipeDown() } else { app.swipeUp() }
        }
        for _ in 0..<(towardTop ? 5 : 8) {
            if element.exists && element.isHittable { return }
            if towardTop { app.swipeUp() } else { app.swipeDown() }
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
