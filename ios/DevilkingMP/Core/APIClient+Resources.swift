import Foundation

extension APIClient {
    func resourceSites() async throws -> [MPResourceSite] {
        let value=try await get("/api/v1/site/",query:["page":"1","count":"200"])
        guard let rows=value as? [[String:Any]],rows.count <= 200 else { throw AppError.message("已连接站点列表不完整。") }
        var seen=Set<String>(),result=[MPResourceSite]()
        for row in rows where row["is_active"] as? Bool == true {
            guard let id=MPResourceParser.positiveID(row["id"]),seen.insert(id).inserted else { throw AppError.message("站点编号不完整或重复。") }
            let name=MPResourceParser.display(row.str("name"))
            guard !name.isEmpty else { throw AppError.message("站点名称无法显示，请在 MoviePilot 核对。") }
            result.append(MPResourceSite(id:id,name:name))
        }
        return result
    }

    func resourceDownloaders() async throws -> [MPResourceDownloader] {
        let clients=try await get("/api/v1/download/clients")
        guard let enabled=clients as? [[String:Any]], enabled.count <= 100 else { throw AppError.message("MoviePilot 下载器列表不完整。") }
        let value=try await get("/api/v1/system/settings/describe/Downloaders",query:["include_value":"true","show_secrets":"false"])
        guard let setting=value as? [String:Any],let rows=setting["value"] as? [[String:Any]],rows.count <= 100 else { throw AppError.message("MoviePilot 下载器身份无法核对，禁止猜测目标。") }
        var result=[MPResourceDownloader](),seen=Set<String>()
        for client in enabled {
            guard let row=rows.first(where: { $0.str("name") == client.str("name") && $0.str("type").lowercased() == client.str("type").lowercased() && $0["enabled"] as? Bool == true }),
                  let item=MPResourceParser.downloader(row),seen.insert(item.id).inserted else { throw AppError.message("下载器身份未知或名称重复，请在 MoviePilot 核对。") }
            result.append(item)
        }
        return result
    }

    func resourceDirectories() async throws -> [MPResourceDirectory] {
        let value=try await get("/api/v1/download/paths")
        guard let rows=value as? [[String:Any]],rows.count <= 200 else { throw AppError.message("MoviePilot 预设目录列表不完整。") }
        var seen=Set<String>(),result=[MPResourceDirectory]()
        for row in rows {
            guard let item=MPResourceParser.directory(row) else { throw AppError.message("预设目录格式无效，请在 MoviePilot 核对。") }
            if seen.insert(item.id).inserted { result.append(item) }
        }
        return result
    }

    /// One user-initiated synchronous search against explicitly selected connected sites.
    /// Never read the shared /search/last cache or schedule subscription / download work.
    func searchResources(query: String, sites: [String], media: MPDiscoveryItem? = nil, season: Int? = nil) async throws -> [MPResourceItem] {
        guard profile.kind == .moviepilot else { throw AppError.message("此服务不提供 PT 资源搜索。") }
        let keyword=query.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !keyword.isEmpty,keyword.utf8.count <= 512,!sites.isEmpty,sites.count <= 200,
              sites.allSatisfy({ MPResourceParser.positiveID($0) != nil }) else { throw AppError.message("请输入片名并明确选择已连接的 PT 站点。") }
        let current=try await resourceSites(),selected=Set(sites)
        guard selected.isSubset(of:Set(current.map(\.id))) else { throw AppError.message("所选站点已变化，请重新选择。") }
        var path="/api/v1/search/title",params=["keyword":keyword,"page":"0","sites":selected.sorted().joined(separator:",")]
        if let media=media {
            guard media.hasSubscribableIdentity else { throw AppError.message("所选作品的媒体身份不完整。") }
            if media.isTV { guard let season=season,(0...10000).contains(season) else { throw AppError.message("请先选择剧集季号。") } }
            path="/api/v1/search/media/"+media.mediaID
            params=["media_source":media.mediaSource,"mtype":media.canonicalType,"area":"title","sites":selected.sorted().joined(separator:",")]
            if media.isTV,let season=season { params["season"]=String(season) }
        }
        let response=try await moviePilotResponse(path,query:params,timeout:125)
        if response["success"] as? Bool == false {
            if response.str("message") == "未搜索到任何资源" { return [] }
            throw AppError.message("MoviePilot 未完成资源搜索，请到原管理页核对；未自动重搜。")
        }
        guard response["success"] as? Bool == true, let rows=response["data"] as? [[String:Any]],rows.count <= 5000 else { throw AppError.message("PT 资源搜索结果不完整。") }
        var result=[MPResourceItem](),seen=Set<String>()
        for row in rows {
            guard let item=MPResourceParser.item(row),selected.contains(item.siteID) else { throw AppError.message("返回资源缺少站点身份或超出本次范围。") }
            if seen.insert(item.id).inserted { result.append(item) }
        }
        return result
    }

    /// Exactly one mutation. A returned download_id means MP accepted a task,
    /// not that data is complete, free, or verified by its tracker.
    func downloadResource(_ request: MPResourceDownloadRequest,
                          authorize: @escaping @Sendable () async -> Bool,
                          beforeSend: @escaping @Sendable () async throws -> Void) async throws -> String {
        guard await authorize() else { throw AppError.message("当前只读、目标未授权或迁移保护已开启，下载未提交。") }
        guard profile.kind == .moviepilot,request.isValid,let source=request.item.payload else { throw AppError.message("资源或目标下载器身份不完整。") }
        guard let canonical=MPResourceParser.item(["media_info":source.media,"torrent_info":source.torrent]),canonical.canDownload,
              canonical.id == request.item.id,canonical.siteID == request.item.siteID,canonical.title == request.item.title else {
            throw AppError.message("确认的资源与实际提交身份不一致，请重新搜索。")
        }
        // Revalidate actual server configuration after confirmation; never POST
        // to a renamed downloader or a preset path removed in the meantime.
        let sites=try await resourceSites()
        guard sites.contains(where: { $0.id == request.item.siteID }) else { throw AppError.message("资源来源站点已停用或移除，请重新搜索。") }
        let downloaders=try await resourceDownloaders()
        guard downloaders.contains(request.downloader) else { throw AppError.message("MoviePilot 下载器配置已变化，请重新选择。") }
        if let directory=request.directory {
            let directories=try await resourceDirectories()
            guard directories.contains(directory) else { throw AppError.message("MoviePilot 预设目录已变化，请重新选择。") }
        }
        guard await authorize() else { throw AppError.message("管理权限或连接已变化，下载未提交。") }
        var body:[String:Any]=["media_in":source.media,"torrent_in":source.torrent,"downloader":request.downloader.name]
        if let directory=request.directory { body["save_path"]=directory.savePath }
        let response=try await moviePilotResponse("/api/v1/download/",method:"POST",json:body,timeout:75,authorize:authorize,beforeSend:beforeSend)
        guard response["success"] as? Bool == true, let data=response["data"] as? [String:Any],
              let id=data["download_id"] as? String,!id.isEmpty,id.utf8.count <= 128,
              id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw AppError.message("下载提交结果尚未确认，请只读核对原管理页，勿重复提交。")
        }
        return id
    }
}
