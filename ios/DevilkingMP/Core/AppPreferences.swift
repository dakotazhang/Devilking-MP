import Foundation
import Combine
import CryptoKit

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self { case .system: return "跟随系统"; case .light: return "浅色"; case .dark: return "深色" }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    var id: String { rawValue }
    var title: String {
        switch self { case .simplifiedChinese: return "简体中文"; case .english: return "English (US)" }
    }
    var locale: Locale { Locale(identifier: self == .english ? "en_US" : rawValue) }

    /// Resolve interface keys explicitly so user-selected language also applies
    /// to reusable components receiving String values rather than literals.
    func localized(_ key: String, bundle: Bundle = .main) -> String {
        guard let path = bundle.path(forResource: rawValue, ofType: "lproj"),
              let languageBundle = Bundle(path: path) else { return key }
        return languageBundle.localizedString(forKey: key, value: key, table: nil)
    }
}

enum AppFontSize: String, CaseIterable, Identifiable {
    case system, large, extraLarge
    var id: String { rawValue }
    var title: String {
        switch self { case .system: return "跟随系统"; case .large: return "较大"; case .extraLarge: return "更大" }
    }
}

enum DashboardModule: String, CaseIterable, Identifiable {
    case traffic, tasks, storage, services
    var id: String { rawValue }
    var title: String {
        switch self { case .traffic: return "实时流量"; case .tasks: return "任务监控"; case .storage: return "磁盘余量"; case .services: return "服务器状态与入口" }
    }
}

/// Device-only presentation preferences. No service credentials or server
/// configuration are persisted here.
@MainActor final class AppPreferences: ObservableObject {
    static let allowedRefreshIntervals = [0, 15, 30, 60, 120]
    private let defaults: UserDefaults

    @Published var refreshInterval: Int {
        didSet {
            if !Self.allowedRefreshIntervals.contains(refreshInterval) { refreshInterval = 60 }
            defaults.set(refreshInterval, forKey: "ui.refreshInterval")
        }
    }
    @Published var theme: AppTheme { didSet { defaults.set(theme.rawValue, forKey: "ui.theme") } }
    @Published var language: AppLanguage { didSet { defaults.set(language.rawValue, forKey: "ui.language") } }
    @Published var fontSize: AppFontSize { didSet { defaults.set(fontSize.rawValue, forKey: "ui.fontSize") } }
    @Published var characterBackgroundsEnabled: Bool { didSet { defaults.set(characterBackgroundsEnabled, forKey: "ui.characterBackgroundsEnabled") } }
    @Published var visibleDashboardModules: Set<DashboardModule> {
        didSet { defaults.set(visibleDashboardModules.map(\.rawValue).sorted(), forKey: "ui.dashboardModules") }
    }
    @Published private var downloadDirectoriesByConnection: [String: String]
    @Published private var boundDownloadersByConnection: [String: [String: String]]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let interval = defaults.object(forKey: "ui.refreshInterval") as? Int ?? 60
        refreshInterval = Self.allowedRefreshIntervals.contains(interval) ? interval : 60
        theme = AppTheme(rawValue: defaults.string(forKey: "ui.theme") ?? "") ?? .system
        language = AppLanguage(rawValue: defaults.string(forKey: "ui.language") ?? "") ?? .simplifiedChinese
        fontSize = AppFontSize(rawValue: defaults.string(forKey: "ui.fontSize") ?? "") ?? .system
        characterBackgroundsEnabled = defaults.object(forKey: "ui.characterBackgroundsEnabled") == nil ? true : defaults.bool(forKey: "ui.characterBackgroundsEnabled")
        if let saved = defaults.stringArray(forKey: "ui.dashboardModules") {
            visibleDashboardModules = Set(saved.compactMap(DashboardModule.init(rawValue:)))
        } else { visibleDashboardModules = Set(DashboardModule.allCases) }
        downloadDirectoriesByConnection = defaults.dictionary(forKey: "ui.downloadDirectoriesByConnection") as? [String: String] ?? [:]
        boundDownloadersByConnection = defaults.dictionary(forKey: "ui.boundDownloadersByConnection") as? [String: [String: String]] ?? [:]
        // Retired language selections fall back to Chinese without resetting
        // refresh, appearance, connection or safety preferences.
        if AppLanguage(rawValue: defaults.string(forKey: "ui.language") ?? "") == nil {
            defaults.set(language.rawValue, forKey: "ui.language")
        }
    }

    func isVisible(_ module: DashboardModule) -> Bool { visibleDashboardModules.contains(module) }
    func setVisible(_ module: DashboardModule, _ enabled: Bool) {
        if enabled { visibleDashboardModules.insert(module) } else { visibleDashboardModules.remove(module) }
    }
    func text(_ key: String) -> String { language.localized(key) }

    func preferredDownloadDirectoryID(for baseURL: String) -> String? {
        guard let scope = connectionScope(baseURL) else { return nil }
        return downloadDirectoriesByConnection[scope]
    }
    func setPreferredDownloadDirectoryID(_ id: String?, for baseURL: String) {
        guard let scope = connectionScope(baseURL) else { return }
        if let id, !id.isEmpty, id.count <= 512 { downloadDirectoriesByConnection[scope] = id }
        else { downloadDirectoriesByConnection.removeValue(forKey: scope) }
        defaults.set(downloadDirectoriesByConnection, forKey: "ui.downloadDirectoriesByConnection")
    }
    func validatePreferredDownloadDirectory(validIDs: Set<String>, for baseURL: String) {
        if let selected = preferredDownloadDirectoryID(for: baseURL), !validIDs.contains(selected) {
            setPreferredDownloadDirectoryID(nil, for: baseURL)
        }
    }
    func boundDownloaderKind(for downloaderID: String, baseURL: String) -> ServiceKind? {
        guard let scope = connectionScope(baseURL), let raw = boundDownloadersByConnection[scope]?[downloaderID],
              let kind = ServiceKind(rawValue: raw), kind.isDownloader else { return nil }
        return kind
    }
    func setBoundDownloaderKind(_ kind: ServiceKind?, for downloaderID: String, baseURL: String) {
        guard let scope = connectionScope(baseURL), !downloaderID.isEmpty, downloaderID.count <= 512 else { return }
        var bindings = boundDownloadersByConnection[scope] ?? [:]
        if let kind, kind.isDownloader { bindings[downloaderID] = kind.rawValue }
        else { bindings.removeValue(forKey: downloaderID) }
        boundDownloadersByConnection[scope] = bindings
        defaults.set(boundDownloadersByConnection, forKey: "ui.boundDownloadersByConnection")
    }
    func clearResourcePreferences(for baseURL: String) {
        guard let scope = connectionScope(baseURL) else { return }
        downloadDirectoriesByConnection.removeValue(forKey: scope)
        boundDownloadersByConnection.removeValue(forKey: scope)
        defaults.set(downloadDirectoriesByConnection, forKey: "ui.downloadDirectoriesByConnection")
        defaults.set(boundDownloadersByConnection, forKey: "ui.boundDownloadersByConnection")
    }
    private func connectionScope(_ baseURL: String) -> String? {
        let normalized = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalized.isEmpty else { return nil }
        return SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
