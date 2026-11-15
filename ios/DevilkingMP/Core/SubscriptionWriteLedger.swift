import Foundation
import CryptoKit

/// Persisted before a subscription can reach the network. An uncertain intent
/// is never automatically retried, including after an application relaunch.
struct SubscriptionWriteRecord: Codable, Equatable {
    var createdAt: Date
    var confirmedID: String?
}

struct SubscriptionWriteLedger {
    private let defaults: UserDefaults
    private let storageKey = "subscriptionWriteIntents.v1"
    init(defaults: UserDefaults) { self.defaults = defaults }
    func key(profile: ServiceProfile, request: MPSubscriptionRequest) -> String {
        var canonical = request
        if canonical.item.mediaSource == "tmdb" { canonical.item.mediaSource = "themoviedb" }
        let value = profile.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "\n" + profile.username + "\n" + canonical.identityKey
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func read() throws -> [String: SubscriptionWriteRecord] {
        guard defaults.object(forKey: storageKey) != nil else { return [:] }
        guard let data = defaults.data(forKey: storageKey) else { throw AppError.message("订阅提交记录格式损坏，请先在原 MoviePilot 核对，当前不允许重复提交。") }
        do { return try JSONDecoder().decode([String: SubscriptionWriteRecord].self, from: data) }
        catch { throw AppError.message("订阅提交记录无法读取，请先在原 MoviePilot 核对，当前不允许重复提交。") }
    }
    func record(_ key: String) throws -> SubscriptionWriteRecord? { try read()[key] }
    func prepare(_ key: String) throws {
        var rows = try read()
        guard rows[key] == nil else { throw AppError.message("这项订阅已有提交记录，请先在原 MoviePilot 核对。") }
        rows[key] = SubscriptionWriteRecord(createdAt: Date(), confirmedID: nil)
        try write(rows)
    }
    func confirm(_ key: String, id: String) throws {
        var rows = try read()
        rows[key] = SubscriptionWriteRecord(createdAt: rows[key]?.createdAt ?? Date(), confirmedID: id)
        try write(rows)
    }
    private func write(_ rows: [String: SubscriptionWriteRecord]) throws {
        let data = try JSONEncoder().encode(rows)
        defaults.set(data, forKey: storageKey)
        // Flush before network dispatch; a failure blocks rather than losing the intent.
        guard defaults.synchronize(), defaults.data(forKey: storageKey) == data else {
            throw AppError.message("无法保存订阅提交记录，本次未继续发送。")
        }
    }
}
