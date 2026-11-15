import XCTest
import SwiftUI
@testable import DevilkingMP

final class AppPreferencesTests: XCTestCase {
    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "DevilkingMP-AppPreferencesTests-\(UUID().uuidString)")!
    }

    @MainActor func testFreshPreferencesPreserveConservativeRefreshAndAllModules() {
        let preferences = AppPreferences(defaults: isolatedDefaults())
        XCTAssertEqual(preferences.refreshInterval, 60)
        XCTAssertEqual(preferences.theme, .system)
        XCTAssertEqual(preferences.language, .simplifiedChinese)
        XCTAssertEqual(preferences.fontSize, .system)
        XCTAssertEqual(preferences.visibleDashboardModules, Set(DashboardModule.allCases))
    }

    @MainActor func testPresentationPreferencesSurviveRelaunch() {
        let defaults = isolatedDefaults()
        let first = AppPreferences(defaults: defaults)
        first.refreshInterval = 0
        first.theme = .light
        first.language = .english
        first.fontSize = .large
        first.setVisible(.storage, false)
        let second = AppPreferences(defaults: defaults)
        XCTAssertEqual(second.refreshInterval, 0)
        XCTAssertEqual(second.theme, .light)
        XCTAssertEqual(second.language, .english)
        XCTAssertEqual(second.fontSize, .large)
        XCTAssertFalse(second.isVisible(.storage))
        XCTAssertTrue(second.isVisible(.traffic))
    }

    @MainActor func testInvalidPersistedRefreshCannotCreateBusyPolling() {
        let defaults = isolatedDefaults()
        defaults.set(5, forKey: "ui.refreshInterval")
        defaults.set("unknown", forKey: "ui.theme")
        defaults.set("unknown", forKey: "ui.language")
        defaults.set("unknown", forKey: "ui.fontSize")
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.refreshInterval, 60)
        XCTAssertEqual(preferences.theme, .system)
        XCTAssertEqual(preferences.language, .simplifiedChinese)
        XCTAssertEqual(preferences.fontSize, .system)
        preferences.refreshInterval = -1
        XCTAssertEqual(preferences.refreshInterval, 60)
        XCTAssertEqual(AppPreferences(defaults: defaults).refreshInterval, 60)
    }

    @MainActor func testRetiredLanguageFallsBackWithoutResettingOtherPreferences() {
        let defaults = isolatedDefaults()
        defaults.set("zh-Hant", forKey: "ui.language")
        defaults.set(30, forKey: "ui.refreshInterval")
        defaults.set("dark", forKey: "ui.theme")
        defaults.set(true, forKey: "readOnlyMode")
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(AppLanguage.allCases, [.simplifiedChinese, .english])
        XCTAssertEqual(preferences.language, .simplifiedChinese)
        XCTAssertEqual(defaults.string(forKey: "ui.language"), "zh-Hans")
        XCTAssertEqual(preferences.refreshInterval, 30)
        XCTAssertEqual(preferences.theme, .dark)
        XCTAssertTrue(defaults.bool(forKey: "readOnlyMode"))
    }

    @MainActor func testDirectoryPreferencesAreConnectionScopedAndRevalidated() {
        let defaults = isolatedDefaults()
        let preferences = AppPreferences(defaults: defaults)
        let first = "https://moviepilot-one.example"
        let second = "https://moviepilot-two.example"
        preferences.setPreferredDownloadDirectoryID("directory-a", for: first)
        XCTAssertEqual(preferences.preferredDownloadDirectoryID(for: first + "/"), "directory-a")
        XCTAssertNil(preferences.preferredDownloadDirectoryID(for: second))
        preferences.validatePreferredDownloadDirectory(validIDs: ["directory-b"], for: first)
        XCTAssertNil(preferences.preferredDownloadDirectoryID(for: first))
        XCTAssertNil(AppPreferences(defaults: defaults).preferredDownloadDirectoryID(for: first))
    }

    @MainActor func testDownloaderBindingNeverCrossesConnectionsOrAllowsNonDownloaderRole() {
        let defaults = isolatedDefaults()
        let preferences = AppPreferences(defaults: defaults)
        let first = "https://moviepilot-one.example"
        let second = "https://moviepilot-two.example"
        preferences.setBoundDownloaderKind(.qb1, for: "main", baseURL: first)
        XCTAssertEqual(AppPreferences(defaults: defaults).boundDownloaderKind(for: "main", baseURL: first), .qb1)
        XCTAssertNil(preferences.boundDownloaderKind(for: "main", baseURL: second))
        preferences.setBoundDownloaderKind(.moviepilot, for: "other", baseURL: first)
        XCTAssertNil(preferences.boundDownloaderKind(for: "other", baseURL: first))
        preferences.setPreferredDownloadDirectoryID("directory-a", for: first)
        preferences.clearResourcePreferences(for: first)
        XCTAssertNil(preferences.boundDownloaderKind(for: "main", baseURL: first))
        XCTAssertNil(preferences.preferredDownloadDirectoryID(for: first))
    }

    @MainActor func testPresentationSettingsDoNotRewriteOperationSafetyPreferences() {
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: "readOnlyMode")
        defaults.set(true, forKey: "migrationProtection")
        let preferences = AppPreferences(defaults: defaults)
        preferences.refreshInterval = 15
        preferences.theme = .dark
        preferences.language = .english
        for module in DashboardModule.allCases { preferences.setVisible(module, false) }
        XCTAssertTrue(defaults.bool(forKey: "readOnlyMode"))
        XCTAssertTrue(defaults.bool(forKey: "migrationProtection"))
        XCTAssertTrue(AppPreferences(defaults: defaults).visibleDashboardModules.isEmpty)
    }

    func testFontPreferenceNeverShrinksAccessibilityText() {
        XCTAssertEqual(AppFontSize.large.dynamicTypeSize(system: .accessibility3), .accessibility3)
        XCTAssertEqual(AppFontSize.extraLarge.dynamicTypeSize(system: .accessibility3), .accessibility3)
        XCTAssertEqual(AppFontSize.large.dynamicTypeSize(system: .large), .xLarge)
        XCTAssertNil(AppTheme.system.colorScheme)
        XCTAssertEqual(AppTheme.light.colorScheme, .light)
        XCTAssertEqual(AppTheme.dark.colorScheme, .dark)
    }

    func testActualLanguageResourcesLoadFromAppBundle() {
        let bundle = Bundle(for: AppModel.self)
        XCTAssertEqual(AppLanguage.english.localized("设置", bundle: bundle), "Settings")
        XCTAssertEqual(AppLanguage.simplifiedChinese.localized("服务器设置", bundle: bundle), "服务器设置")
        XCTAssertEqual(AppLanguage.english.localized("A server-supplied title", bundle: bundle), "A server-supplied title")
        XCTAssertEqual(AppLanguage.english.locale.identifier, "en_US")
        XCTAssertEqual(AppLanguage.english.title, "English (US)")
    }
}
