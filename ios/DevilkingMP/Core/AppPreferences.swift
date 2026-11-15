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
    @Published private(set) var serverGroups: [ServerGroup]
    @Published private(set) var selectedGroupID: String?
    @Published private(set) var groupConfigurationError: String?
    private struct GroupState: Codable { var groups: [ServerGroup]; var selectedID: String? }
    private static let groupStorageKey = "ui.serverGroups.v1"

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
        serverGroups = []; selectedGroupID = nil; groupConfigurationError = nil
        if defaults.object(forKey: Self.groupStorageKey) != nil {
            if let data = defaults.data(forKey: Self.groupStorageKey),
               let state = try? JSONDecoder().decode(GroupState.self, from: data),
               Self.validGroups(state.groups) {
                serverGroups = state.groups.map { ServerGroup(id: $0.id, name: $0.name, memberIDs: $0.memberIDs) }
                selectedGroupID = state.groups.contains(where: { $0.id == state.selectedID }) ? state.selectedID : nil
            } else {
                groupConfigurationError = "服务器分类无法读取，原分类配置已保留。"
            }
        }
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
    /// Forget only confirmations targeting this exact server identity, across
    /// MP connections. Directory choices and unrelated server bindings survive.
    func removeBindings(to instanceID: ServiceID) throws {
        guard instanceID.isDownloader else { return }
        let previous = boundDownloadersByConnection
        var next = previous
        for (scope, bindings) in previous {
            let remaining = bindings.filter { $0.value != instanceID.rawValue }
            if remaining.isEmpty { next.removeValue(forKey: scope) }
            else { next[scope] = remaining }
        }
        guard next != previous else { return }
        let key = "ui.boundDownloadersByConnection"
        let oldObject = defaults.object(forKey: key)
        defaults.set(next, forKey: key)
        guard defaults.synchronize(), (defaults.dictionary(forKey: key) as? [String: [String: String]]) == next else {
            if let oldObject { defaults.set(oldObject, forKey: key) }
            else { defaults.removeObject(forKey: key) }
            throw AppError.message("无法清除原下载器身份确认，请先重新核对连接。")
        }
        boundDownloadersByConnection = next
    }
    func clearResourcePreferences(for baseURL: String) {
        guard let scope = connectionScope(baseURL) else { return }
        downloadDirectoriesByConnection.removeValue(forKey: scope)
        boundDownloadersByConnection.removeValue(forKey: scope)
        defaults.set(downloadDirectoriesByConnection, forKey: "ui.downloadDirectoriesByConnection")
        defaults.set(boundDownloadersByConnection, forKey: "ui.boundDownloadersByConnection")
    }

    var selectedGroup: ServerGroup? { serverGroups.first { $0.id == selectedGroupID } }

    /// A nil selection means all servers, including newly added servers.
    func setSelectedGroupID(_ id: String?) throws {
        guard id == nil || serverGroups.contains(where: { $0.id == id }) else { throw AppError.message("分类已变化，请重新选择。") }
        try persistGroups(serverGroups, selectedID: id)
    }

    @discardableResult func saveGroup(id: String? = nil, name: String, memberIDs: [ServiceID]) throws -> String {
        guard groupConfigurationError == nil else { throw AppError.message("原分类配置无法读取，请先恢复或重置分类。") }
        let name = try ServerNamePolicy.normalized(name)
        guard memberIDs.allSatisfy(\.isDownloader) else { throw AppError.message("分类只能包含下载器。") }
        let groupID = id ?? UUID().uuidString.lowercased()
        guard UUID(uuidString: groupID) != nil, id == nil || serverGroups.contains(where: { $0.id == groupID }) else {
            throw AppError.message("分类身份已变化，请重新打开编辑页面。")
        }
        guard !serverGroups.contains(where: { $0.id != groupID && $0.name.compare(name, options: .caseInsensitive) == .orderedSame }) else {
            throw AppError.message("已有同名分类，请使用不同名称。")
        }
        let group = ServerGroup(id: groupID, name: name, memberIDs: memberIDs)
        var groups = serverGroups
        if let index = groups.firstIndex(where: { $0.id == groupID }) { groups[index] = group }
        else { groups.append(group) }
        try persistGroups(groups, selectedID: selectedGroupID)
        return groupID
    }

    func deleteGroup(_ id: String) throws {
        try persistGroups(serverGroups.filter { $0.id != id }, selectedID: selectedGroupID == id ? nil : selectedGroupID)
    }

    func removeServerFromGroups(_ instanceID: ServiceID) throws {
        let groups = serverGroups.map { ServerGroup(id: $0.id, name: $0.name, memberIDs: $0.memberIDs.filter { $0 != instanceID }) }
        try persistGroups(groups, selectedID: selectedGroupID)
    }

    /// Intersect group membership with the caller's current server list, once per ID.
    func scopedDownloaderIDs(_ all: [ServiceID]) -> [ServiceID] {
        let allowed = selectedGroup.map { Set($0.memberIDs) }
        var seen = Set<ServiceID>()
        return all.filter { $0.isDownloader && (allowed == nil || allowed!.contains($0)) && seen.insert($0).inserted }
    }

    /// Explicit local recovery; this never alters connections, credentials or permissions.
    func resetServerGroups() throws {
        try persistGroups([], selectedID: nil, allowRecovery: true)
    }

    private static func validGroups(_ groups: [ServerGroup]) -> Bool {
        Set(groups.map(\.id)).count == groups.count && groups.allSatisfy {
            UUID(uuidString: $0.id) != nil && (try? ServerNamePolicy.normalized($0.name)) != nil && $0.memberIDs.allSatisfy(\.isDownloader)
        }
    }

    private func persistGroups(_ groups: [ServerGroup], selectedID: String?, allowRecovery: Bool = false) throws {
        guard (allowRecovery || groupConfigurationError == nil), Self.validGroups(groups) else { throw AppError.message("分类配置无效，原分类未更改。") }
        let data = try JSONEncoder().encode(GroupState(groups: groups, selectedID: selectedID))
        let previous = defaults.object(forKey: Self.groupStorageKey)
        defaults.set(data, forKey: Self.groupStorageKey)
        guard defaults.synchronize(), defaults.data(forKey: Self.groupStorageKey) == data else {
            if let previous { defaults.set(previous, forKey: Self.groupStorageKey) }
            else { defaults.removeObject(forKey: Self.groupStorageKey) }
            throw AppError.message("无法保存分类，原分类未更改。")
        }
        serverGroups = groups; self.selectedGroupID = selectedID; groupConfigurationError = nil
    }

    private func connectionScope(_ baseURL: String) -> String? {
        let normalized = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalized.isEmpty else { return nil }
        return SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
