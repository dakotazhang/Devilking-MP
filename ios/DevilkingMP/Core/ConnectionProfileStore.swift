import Foundation

struct ConnectionProfileLoadResult {
    var profiles: [ServiceProfile]
    var error: String?
    var migrated: Bool
}

/// v1 bytes remain untouched. A malformed store is never replaced by defaults.
enum ConnectionProfileStore {
    static let storageKey = "profiles.v2"
    static let legacyStorageKey = "profiles"

    static func load(defaults: UserDefaults, legacyCredentialExists: (ServiceID) -> Bool) -> ConnectionProfileLoadResult {
        if defaults.object(forKey: storageKey) != nil {
            do {
                guard let data = defaults.data(forKey: storageKey) else { throw StoreError.invalid }
                let profiles = try JSONDecoder().decode([ServiceProfile].self, from: data)
                try validate(profiles)
                return ConnectionProfileLoadResult(profiles: profiles, error: nil, migrated: false)
            } catch {
                return failure("服务器配置无法读取，原配置已保留。管理功能保持关闭，请从备份恢复配置。")
            }
        }
        if defaults.object(forKey: legacyStorageKey) != nil {
            do {
                guard let data = defaults.data(forKey: legacyStorageKey) else { throw StoreError.invalid }
                let profiles = try JSONDecoder().decode([ServiceProfile].self, from: data)
                try validate(profiles)
                try save(profiles, defaults: defaults)
                return ConnectionProfileLoadResult(profiles: profiles, error: nil, migrated: true)
            } catch {
                return failure("旧服务器配置无法完整迁移，原配置已保留。管理功能保持关闭，请先核对备份。")
            }
        }
        // Recover only real legacy credentials. The old endpoint is unknown: keep
        // them suspended so an example address never receives saved credentials.
        let recovered = ServiceID.allCases.filter(legacyCredentialExists).map {
            ServiceProfile(kind: $0, baseURL: $0.defaultURL, username: "", allowActions: false, enabled: false)
        }
        guard !recovered.isEmpty else { return ConnectionProfileLoadResult(profiles: [], error: nil, migrated: false) }
        do {
            try save(recovered, defaults: defaults)
            return ConnectionProfileLoadResult(profiles: recovered, error: nil, migrated: true)
        } catch {
            return failure("无法保存恢复的连接配置，手机钥匙串未变更。管理功能保持关闭。")
        }
    }

    static func save(_ profiles: [ServiceProfile], defaults: UserDefaults) throws {
        try validate(profiles)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(profiles)
        let previous = defaults.object(forKey: storageKey)
        defaults.set(data, forKey: storageKey)
        guard defaults.synchronize(), defaults.data(forKey: storageKey) == data else {
            if let previous { defaults.set(previous, forKey: storageKey) }
            else { defaults.removeObject(forKey: storageKey) }
            throw AppError.message("无法保存服务器配置，原连接未被替换。")
        }
    }

    static func validate(_ profiles: [ServiceProfile]) throws {
        guard Set(profiles.map(\.id)).count == profiles.count,
              profiles.filter({ $0.protocolKind == .moviepilot }).count <= 1,
              profiles.filter({ $0.protocolKind == .emby }).count <= 1 else { throw StoreError.invalid }
        for profile in profiles {
            _ = try ServerNamePolicy.normalized(profile.displayName)
            guard !profile.baseURL.isEmpty, profile.baseURL.utf8.count <= 8192,
                  !profile.baseURL.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  profile.username.utf8.count <= 4096,
                  !profile.username.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw StoreError.invalid }
        }
    }

    private enum StoreError: Error { case invalid }
    private static func failure(_ error: String) -> ConnectionProfileLoadResult {
        ConnectionProfileLoadResult(profiles: [], error: error, migrated: false)
    }
}

enum ServerNamePolicy {
    static func normalized(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw AppError.message("名称需为 1–80 个字符，不能包含控制字符。")
        }
        return name
    }
}

/// Membership changes presentation only. The ID of every member remains intact.
struct ServerGroup: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var memberIDs: [ServiceID]

    init(id: String = UUID().uuidString.lowercased(), name: String, memberIDs: [ServiceID]) {
        self.id = id; self.name = name
        var seen = Set<ServiceID>()
        self.memberIDs = memberIDs.filter { seen.insert($0).inserted }
    }
}
