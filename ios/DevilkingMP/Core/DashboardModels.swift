import Foundation
import CoreFoundation

enum DashboardTaskFilter: String, CaseIterable, Identifiable {
    case all, downloading, seeding, verifying, stopped, errors
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "全部任务"
        case .downloading: return "下载中"
        case .seeding: return "做种中"
        case .verifying: return "校验中"
        case .stopped: return "已停止"
        case .errors: return "任务异常"
        }
    }
}

struct DashboardTaskCounts: Equatable {
    var total = 0
    var downloading = 0
    var seeding = 0
    var verifying = 0
    var stopped = 0
    var errors = 0
    var queued = 0
    var unknown = 0

    subscript(_ filter: DashboardTaskFilter) -> Int {
        switch filter {
        case .all: return total
        case .downloading: return downloading
        case .seeding: return seeding
        case .verifying: return verifying
        case .stopped: return stopped
        case .errors: return errors
        }
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(total: lhs.total + rhs.total, downloading: lhs.downloading + rhs.downloading,
             seeding: lhs.seeding + rhs.seeding, verifying: lhs.verifying + rhs.verifying,
             stopped: lhs.stopped + rhs.stopped, errors: lhs.errors + rhs.errors,
             queued: lhs.queued + rhs.queued, unknown: lhs.unknown + rhs.unknown)
    }
}

struct DashboardDiskReading: Equatable {
    /// A directory-specific observation, never an assertion of a unique disk.
    var label: String
    var freeBytes: Double
    var totalBytes: Double? = nil
}

struct DashboardSnapshot {
    var kind: ServiceKind
    var downloadRate: Double?
    var uploadRate: Double?
    var counts: DashboardTaskCounts?
    var disk: DashboardDiskReading?
    var cumulativeDownloaded: Double?
    var cumulativeUploaded: Double?
    var peerConnectivity: String?
    var warnings: [String] = []
    var updatedAt: Date = Date()
    var attemptedAt: Date = Date()
    var error: String? = nil

    func isFresh(now: Date = Date(), maximumAge: TimeInterval = 125) -> Bool {
        let age = now.timeIntervalSince(updatedAt)
        return error == nil && age >= -5 && age <= maximumAge
    }

    static func failure(kind: ServiceKind, previous: Self?, error: String, now: Date = Date()) -> Self {
        var result = previous ?? Self(kind: kind)
        result.kind = kind
        result.attemptedAt = now
        result.error = error
        return result
    }
}

/// Only freshly read services contribute. No current data is represented by nil,
/// not by a zero, and a partial sum explicitly reports its service coverage.
struct DashboardAggregate {
    var configuredCount: Int
    var currentCount: Int
    var downloadRate: Double?
    var uploadRate: Double?
    var counts: DashboardTaskCounts?
    var oldestUpdate: Date?
    var newestUpdate: Date?

    init(configured: [ServiceKind], snapshots: [ServiceKind: DashboardSnapshot], now: Date = Date()) {
        let unique = Set(configured.filter(\.isDownloader))
        let current = unique.compactMap { snapshots[$0] }.filter { $0.isFresh(now: now) }
        configuredCount = unique.count
        currentCount = current.count
        let down = current.compactMap(\.downloadRate)
        let up = current.compactMap(\.uploadRate)
        downloadRate = down.isEmpty ? nil : down.reduce(0, +)
        uploadRate = up.isEmpty ? nil : up.reduce(0, +)
        let knownCounts = current.compactMap(\.counts)
        counts = knownCounts.isEmpty ? nil : knownCounts.reduce(DashboardTaskCounts(), +)
        oldestUpdate = current.map(\.updatedAt).min()
        newestUpdate = current.map(\.updatedAt).max()
    }

    var hasPartialCoverage: Bool { currentCount < configuredCount }
}

enum DashboardParser {
    /// JSON booleans and numeric strings are not counters. Negative sentinels,
    /// NaN, infinities and impossible magnitudes stay unknown.
    static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let value = n.doubleValue
        return value.isFinite && value >= 0 && value <= 9_000_000_000_000_000 ? value : nil
    }

    static func qbCounts(_ rows: [[String: Any]]) throws -> DashboardTaskCounts {
        var result = DashboardTaskCounts()
        for row in rows {
            guard let state = row["state"] as? String, !state.isEmpty else {
                throw AppError.message("qB 任务状态缺失，未更新状态表统计。")
            }
            result.total += 1
            let localError = ["error", "missingFiles"].contains(state)
            if localError || row["has_tracker_error"] as? Bool == true || row["has_other_announce_error"] as? Bool == true {
                result.errors += 1
            }
            switch state {
            case "uploading", "stalledUP", "forcedUP": result.seeding += 1
            case "downloading", "stalledDL", "forcedDL", "metaDL", "forcedMetaDL": result.downloading += 1
            case "checkingUP", "checkingDL", "checkingResumeData": result.verifying += 1
            case "stoppedUP", "stoppedDL", "pausedUP", "pausedDL": result.stopped += 1
            case "queuedUP", "queuedDL": result.queued += 1
            case "error", "missingFiles": break
            default: result.unknown += 1
            }
        }
        return result
    }

    static func trCounts(_ rows: [[String: Any]]) throws -> DashboardTaskCounts {
        var result = DashboardTaskCounts()
        for row in rows {
            guard let status = number(row["status"]), status.rounded(.towardZero) == status,
                  let error = number(row["error"]), error.rounded(.towardZero) == error else {
                throw AppError.message("TR 任务状态或错误标记缺失，未更新状态表统计。")
            }
            result.total += 1
            if error > 0 { result.errors += 1 }
            switch Int(status) {
            case 0: result.stopped += 1
            case 1, 2: result.verifying += 1
            case 3, 5: result.queued += 1
            case 4: result.downloading += 1
            case 6: result.seeding += 1
            default: result.unknown += 1
            }
        }
        return result
    }

    static func qb(_ payload: [String: Any], kind: ServiceKind, now: Date = Date()) throws -> DashboardSnapshot {
        guard kind.isQB, payload["full_update"] as? Bool == true,
              let rows = payload["torrents"] as? [String: [String: Any]],
              let state = payload["server_state"] as? [String: Any],
              let down = number(state["dl_info_speed"]), let up = number(state["up_info_speed"]) else {
            throw AppError.message("qB 完整状态未返回，未将缺失数据计为零。")
        }
        guard rows.keys.allSatisfy({ EndpointPolicy.validTaskID($0, kind: kind) }) else {
            throw AppError.message("qB 任务清单不完整，未更新状态表统计。")
        }
        var result = DashboardSnapshot(kind: kind, downloadRate: down, uploadRate: up,
                                       counts: try qbCounts(Array(rows.values)),
                                       cumulativeDownloaded: number(state["alltime_dl"]),
                                       cumulativeUploaded: number(state["alltime_ul"]),
                                       updatedAt: now, attemptedAt: now)
        if let free = number(state["free_space_on_disk"]) {
            result.disk = DashboardDiskReading(label: "默认下载盘", freeBytes: free)
        } else { result.warnings.append("默认下载盘余量未返回") }
        if let connection = state["connection_status"] as? String {
            result.peerConnectivity = ["connected": "入站已连接", "firewalled": "入站连接受限", "disconnected": "监听未连接"][connection] ?? "连接状态未知"
        }
        if rows.values.contains(where: { $0["has_tracker_error"] as? Bool == nil || $0["has_other_announce_error"] as? Bool == nil }) {
            result.warnings.append("Tracker 错误标记未完整返回，异常数仅含已知错误")
        }
        return result
    }

    static func tr(stats: [String: Any], rows: [[String: Any]], kind: ServiceKind = .tr, now: Date = Date()) throws -> DashboardSnapshot {
        guard kind.isTR, let down = number(stats["downloadSpeed"]), let up = number(stats["uploadSpeed"]),
              let total = number(stats["torrentCount"]), total.rounded(.towardZero) == total else {
            throw AppError.message("TR 流量或任务总数不完整，未更新状态表统计。")
        }
        let cumulative = stats["cumulative-stats"] as? [String: Any] ?? [:]
        var result = DashboardSnapshot(kind: kind, downloadRate: down, uploadRate: up,
                                       counts: try trCounts(rows),
                                       cumulativeDownloaded: number(cumulative["downloadedBytes"]),
                                       cumulativeUploaded: number(cumulative["uploadedBytes"]),
                                       updatedAt: now, attemptedAt: now)
        if total != Double(rows.count) { result.warnings.append("两次读取间任务数发生变化，按后读清单计数") }
        return result
    }

    static func trDisk(_ payload: [String: Any], requestedPath: String) -> DashboardDiskReading? {
        guard payload["path"] as? String == requestedPath, let free = number(payload["size-bytes"]) else { return nil }
        let total = number(payload["total_size"])
        guard total == nil || free <= total! else { return nil }
        return DashboardDiskReading(label: "默认下载目录", freeBytes: free, totalBytes: total)
    }
}
