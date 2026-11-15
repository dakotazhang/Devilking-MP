import Foundation

extension APIClient {
    /// A finite, read-only refresh. No peer probes, announces, scans or writes.
    func dashboard() async throws -> DashboardSnapshot {
        switch profile.kind {
        case .qb1, .qb2:
            // rid=0 requests the complete task map and server counters together;
            // do not fetch torrents/info again merely to count the same tasks.
            guard let data = try await get("/api/v2/sync/maindata", query: ["rid": "0"]) as? [String: Any] else {
                throw AppError.message("qB 仪表盘响应格式不符。")
            }
            return try DashboardParser.qb(data, kind: profile.kind)
        case .tr:
            let stats = try await rpc("session-stats")
            let data = try await rpc("torrent-get", args: ["fields": ["hashString", "status", "error"]])
            guard let rows = data["torrents"] as? [[String: Any]],
                  rows.allSatisfy({ EndpointPolicy.validTaskID($0.str("hashString"), kind: .tr) }),
                  Set(rows.map { $0.str("hashString") }).count == rows.count else {
                throw AppError.message("TR 仪表盘任务清单不完整。")
            }
            var result = try DashboardParser.tr(stats: stats, rows: rows)
            // Directory space is ancillary. A failed disk query does not erase
            // freshly read traffic, but its missing value never becomes zero.
            do {
                let settings = try await rpc("session-get", args: ["fields": ["download-dir"]])
                guard let path = settings["download-dir"] as? String, path.hasPrefix("/"),
                      !path.isEmpty, path.utf8.count <= 4096 else {
                    throw AppError.message("TR 默认目录未返回。")
                }
                let disk = try await rpc("free-space", args: ["path": path])
                guard let reading = DashboardParser.trDisk(disk, requestedPath: path) else {
                    throw AppError.message("TR 磁盘余量未返回。")
                }
                result.disk = reading
            } catch { result.warnings.append("默认下载目录余量暂不可读") }
            return result
        default:
            throw AppError.message("此服务不提供下载器仪表盘。")
        }
    }
}
