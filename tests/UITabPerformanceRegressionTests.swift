import XCTest

/// Synthetic-only coverage for the library size that exposed the TR tab issue.
/// These metrics include XCTest navigation/synchronization overhead; they are
/// regression evidence, not a claim about frame rate on a physical phone.
final class UITabPerformanceRegressionTests: XCTestCase {
    private func launchLargeLibrary() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture", "--ui-fixture-large-library",
                               "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.navigationBars["状态表"].waitForExistence(timeout: 15))
        let scope = app.buttons["servers.groupScope.status"]
        reveal(scope, in: app)
        XCTAssertTrue(scope.isHittable)
        scope.tap()
        let home = app.buttons.matching(NSPredicate(format: "label == %@", "家庭"))
        XCTAssertEqual(home.count, 1)
        home.element.tap()
        app.tabBars.buttons["下载器"].tap()
        assertTaskCount("5000/5000", in: app)
        return app
    }

    func testLargeTransmissionSearchAndFiltersKeepReadOnlyProtection() throws {
        let app = launchLargeLibrary()
        let tr = app.buttons["downloaders.service.tr"]
        reveal(tr, towardTopIfMissing: true, in: app)
        tr.tap()
        assertTaskCount("3500/3500", in: app)

        let seeding = app.buttons["downloaders.filter.seeding"]
        reveal(seeding, towardTopIfMissing: true, in: app)
        seeding.tap()
        let firstTR = app.buttons["downloaders.task.tr:large-tr-00000"]
        reveal(firstTR, in: app)
        XCTAssertTrue(firstTR.exists, "The stable first TR seed must remain in the seeding filter")

        let search = app.searchFields.firstMatch
        reveal(search, towardTopIfMissing: true, allowInsideNavigation: true, in: app)
        search.tap()
        search.typeText("批量合成 tr · 00000\n")
        assertTaskCount("3500/1", in: app)
        XCTAssertFalse(app.buttons["downloaders.task.qb1:large-qb1-00000"].exists)

        let stopped = app.buttons["downloaders.filter.stopped"]
        reveal(stopped, towardTopIfMissing: true, in: app)
        stopped.tap()
        XCTAssertTrue(app.staticTexts["没有匹配的任务"].waitForExistence(timeout: 5))
        XCTAssertFalse(firstTR.exists)
        let all = app.buttons["downloaders.filter.all"]
        reveal(all, towardTopIfMissing: true, in: app)
        all.tap()
        assertTaskCount("3500/1", in: app)

        reveal(firstTR, in: app)
        firstTR.tap()
        XCTAssertTrue(app.navigationBars["任务详情"].waitForExistence(timeout: 5))
        let mutation = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "启动此任务", "停止此任务")).firstMatch
        reveal(mutation, in: app)
        XCTAssertTrue(mutation.exists)
        XCTAssertFalse(mutation.isEnabled, "A large list must never weaken the default read-only guard")
        XCTAssertFalse(app.alerts["停止这个任务？"].exists)
    }

    func testFiveTabTransitionsWith5000TasksRecordsTimeCPUAndMemory() throws {
        let app = launchLargeLibrary()
        // Warm each page once so decode/first presentation is distinct from
        // repeated navigation. The five character backgrounds remain enabled.
        let labels = ["状态表", "下载器", "发现", "订阅", "设置"]
        for label in labels {
            app.tabBars.buttons[label].tap()
            XCTAssertTrue(app.tabBars.buttons[label].isSelected)
            XCTAssertTrue(app.navigationBars[label].waitForExistence(timeout: 5))
        }
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(application: app), XCTMemoryMetric(application: app)], options: options) {
            for label in labels {
                app.tabBars.buttons[label].tap()
                XCTAssertTrue(app.tabBars.buttons[label].isSelected)
                XCTAssertTrue(app.navigationBars[label].waitForExistence(timeout: 5))
            }
        }
        app.tabBars.buttons["下载器"].tap()
        assertTaskCount("5000/5000", in: app)
        let readOnly = app.staticTexts["全局只读已开启 · 可以查看，启停与限速保持锁定。"]
        reveal(readOnly, towardTopIfMissing: true, in: app)
        XCTAssertTrue(readOnly.exists)
    }

    private func assertTaskCount(_ expected: String, in app: XCUIApplication,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let count = app.staticTexts["downloaders.taskCount"]
        reveal(count, in: app, file: file, line: line)
        XCTAssertTrue(count.waitForExistence(timeout: 5), file: file, line: line)
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
            guard let element = object as? XCUIElement, let value = element.value as? String else { return false }
            // SwiftUI localizes interpolated counts, including the accessibility
            // value (5,000/5,000). Remove grouping marks only; both integers and
            // their separator must still equal the exact expected scope/count.
            let normalized = value.replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: "\u{202F}", with: "")
                .replacingOccurrences(of: "\u{00A0}", with: "")
            return normalized == expected
        }, object: count)
        let result = XCTWaiter.wait(for: [updated], timeout: 10)
        XCTAssertEqual(result, .completed,
                       "Expected exact task count \(expected); actual label=\(count.label), value=\(String(describing: count.value)). The visible count must describe the actual selected scope and search.",
                       file: file, line: line)
    }

    /// Scroll only the real page, with the keyboard already dismissed by the
    /// search action. A known edge offset uses a short, geometry-derived drag;
    /// a full swipe can otherwise oscillate around a control hidden by 6 points.
    private func reveal(_ element: XCUIElement, towardTopIfMissing: Bool = false,
                        allowInsideNavigation: Bool = false, in app: XCUIApplication,
                        file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<10 {
            let top = allowInsideNavigation ? app.navigationBars.firstMatch.frame.minY : app.navigationBars.firstMatch.frame.maxY
            let bottom = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : app.windows.firstMatch.frame.maxY
            if element.exists {
                let frame = element.frame
                if element.isHittable && frame.minY >= top && frame.maxY <= bottom { return }
                if frame.minY < top || frame.maxY > bottom {
                    guard dragTowardViewport(frame, top: top, bottom: bottom, in: app) else { break }
                } else { break } // A visible but blocked control must fail, not be tapped through an overlay.
            } else if towardTopIfMissing {
                app.swipeDown()
            } else {
                app.swipeUp()
            }
        }
        XCTAssertTrue(element.exists, file: file, line: line)
        XCTAssertTrue(element.isHittable, file: file, line: line)
        let top = allowInsideNavigation ? app.navigationBars.firstMatch.frame.minY : app.navigationBars.firstMatch.frame.maxY
        let bottom = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : app.windows.firstMatch.frame.maxY
        XCTAssertGreaterThanOrEqual(element.frame.minY, top, file: file, line: line)
        XCTAssertLessThanOrEqual(element.frame.maxY, bottom, file: file, line: line)
    }

    private func dragTowardViewport(_ target: CGRect, top: CGFloat, bottom: CGFloat,
                                    in app: XCUIApplication) -> Bool {
        let window = app.windows.firstMatch
        let windowFrame = window.frame
        let page = app.scrollViews.firstMatch
        let pageFrame = page.exists ? page.frame : windowFrame
        let viewport = pageFrame.intersection(CGRect(x: windowFrame.minX, y: top,
                                                     width: windowFrame.width, height: max(0, bottom - top)))
        guard !viewport.isEmpty, viewport.height >= 88, viewport.width >= 44 else { return false }
        let above = target.minY < top
        let hiddenDistance = above ? top - target.minY : target.maxY - bottom
        // Stay inside the observed page, away from the navigation and tab bars.
        // The minimum clears the pan threshold; the cap avoids inertial swipes.
        let distance = min(max(44, hiddenDistance + 12), viewport.height * 0.35)
        let origin = window.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: viewport.midX - windowFrame.minX,
                                              dy: viewport.midY - windowFrame.minY))
        let end = origin.withOffset(CGVector(dx: viewport.midX - windowFrame.minX,
                                            dy: viewport.midY - windowFrame.minY + (above ? distance : -distance)))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        return true
    }
}
