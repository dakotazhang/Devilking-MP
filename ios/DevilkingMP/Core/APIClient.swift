import Foundation

actor APIClient {
    let profile: ServiceProfile
    private let credentials: Credential
    private let session: URLSession
    private var token=""
    private var userID=""
    private var trSession=""
    private var loggedIn=false
    private var qbVersion=""
    init(profile:ServiceProfile, credentials:Credential, session:URLSession?=nil) {
        self.profile=profile;self.credentials=credentials
        if let session=session { self.session=session }
        else {
            let cfg=URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest=18;cfg.timeoutIntervalForResource=150
            cfg.urlCache=nil;cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            cfg.waitsForConnectivity=false
            self.session=URLSession(configuration:cfg,delegate:SameOriginDelegate(),delegateQueue:nil)
        }
    }
    static func form(_ values:[String:String]) -> Data {
        var c=URLComponents();c.queryItems=values.sorted{$0.key < $1.key}.map{URLQueryItem(name:$0.key,value:$0.value)}
        return (c.percentEncodedQuery ?? "").replacingOccurrences(of:"+",with:"%2B").data(using:.utf8)!
    }
    func endpoint(_ path:String, query:[String:String]=[:]) throws -> URL {
        let base=try EndpointPolicy.validate(profile.baseURL)
        var c=URLComponents(url:base,resolvingAgainstBaseURL:false)!
        var prefix=c.path.trimmingCharacters(in:CharacterSet(charactersIn:"/"))
        if profile.kind == .tr {
            if let range=prefix.range(of:"transmission") { prefix=String(prefix[..<range.lowerBound]).trimmingCharacters(in:CharacterSet(charactersIn:"/")) }
        }
        var relative=path
        if profile.kind == .moviepilot && prefix.hasSuffix("api/v1") && relative.hasPrefix("/api/v1/") { relative=String(relative.dropFirst(7)) }
        if profile.kind == .emby && prefix.hasSuffix("emby") && relative.hasPrefix("/emby/") { relative=String(relative.dropFirst(5)) }
        c.path=(prefix.isEmpty ? "":"/"+prefix)+relative
        if !query.isEmpty { c.queryItems=query.sorted{$0.key < $1.key}.map{URLQueryItem(name:$0.key,value:$0.value)} }
        guard let url=c.url else { throw AppError.message("服务地址无效。") };return url
    }
    private func request(_ path:String, method:String="GET", query:[String:String]=[:], form:[String:String]?=nil, json:Any?=nil, headers:[String:String]=[:], timeout:TimeInterval?=nil) async throws -> (Data,HTTPURLResponse) {
        try Task.checkCancellation()
        var r=URLRequest(url:try endpoint(path,query:query));r.httpMethod=method
        if let timeout=timeout { r.timeoutInterval=timeout }
        r.setValue("application/json",forHTTPHeaderField:"Accept")
        if let form=form { r.httpBody=Self.form(form);r.setValue("application/x-www-form-urlencoded",forHTTPHeaderField:"Content-Type") }
        if let json=json { r.httpBody=try JSONSerialization.data(withJSONObject:json);r.setValue("application/json",forHTTPHeaderField:"Content-Type") }
        if (profile.kind == .qb1 || profile.kind == .qb2) && !credentials.apiKey.isEmpty { r.setValue("Bearer "+credentials.apiKey,forHTTPHeaderField:"Authorization") }
        for (k,v) in headers { r.setValue(v,forHTTPHeaderField:k) }
        let (data,response)=try await session.data(for:r)
        try Task.checkCancellation()
        guard let http=response as? HTTPURLResponse else { throw AppError.message("服务响应无效。") }
        return (data,http)
    }
    private func check(_ response:HTTPURLResponse) throws {
        if response.statusCode == 401 || response.statusCode == 403 { throw AppError.message("登录被拒绝，请核对账号、密码或 API Key。") }
        guard (200...299).contains(response.statusCode) else { throw AppError.message("服务返回 HTTP \(response.statusCode)，操作未自动重试。") }
    }
    private func decode(_ data:Data) throws -> Any {
        guard let object=try? JSONSerialization.jsonObject(with:data) else { throw AppError.message("收到非 JSON 内容，请核对服务地址和反向代理路径。") };return object
    }
    private func login() async throws {
        if loggedIn { return }
        guard !credentials.isEmpty else { throw AppError.message("请先在设置中填写此服务的登录资料。") }
        switch profile.kind {
        case .qb1,.qb2:
            let base=try EndpointPolicy.validate(profile.baseURL)
            if credentials.apiKey.isEmpty {
                let (d,h)=try await request("/api/v2/auth/login",method:"POST",form:["username":credentials.username,"password":credentials.password],headers:["Origin":origin(base),"Referer":base.absoluteString+"/"])
                try check(h)
                guard h.statusCode == 204 || String(data:d,encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines) == "Ok." else { throw AppError.message("qB 登录失败。") }
            }
            let (v,vh)=try await request("/api/v2/app/version");try check(vh)
            qbVersion=String(data:v,encoding:.utf8) ?? ""
            guard qbVersion.hasPrefix("v") else { throw AppError.message("qB 版本校验失败。") }
        case .moviepilot:
            if credentials.apiKey.isEmpty {
                let (d,h)=try await request("/api/v1/login/access-token",method:"POST",form:["username":credentials.username,"password":credentials.password]);try check(h)
                token=(try decode(d) as? [String:Any])?.str("access_token") ?? ""
                guard !token.isEmpty else { throw AppError.message("MoviePilot 未返回登录凭据。") }
            }
        case .emby:
            if !credentials.apiKey.isEmpty {
                token=credentials.apiKey
                let (d,h)=try await request("/emby/Users",headers:["X-Emby-Token":token]);try check(h)
                let users=try decode(d) as? [[String:Any]] ?? []
                userID=users.first(where:{$0.str("Name") == credentials.username})?.str("Id") ?? ""
                guard !userID.isEmpty else { throw AppError.message("使用 Emby API Key 时还需要填写匹配的用户名。") }
            } else {
                let existing=UserDefaults.standard.string(forKey:"embyDeviceID") ?? UUID().uuidString
                UserDefaults.standard.set(existing,forKey:"embyDeviceID")
                let auth="Emby Client=\"Devilking MP\", Device=\"iPhone\", DeviceId=\"\(existing)\", Version=\"1.0\""
                let (d,h)=try await request("/emby/Users/AuthenticateByName",method:"POST",json:["Username":credentials.username,"Pw":credentials.password],headers:["X-Emby-Authorization":auth]);try check(h)
                let o=try decode(d) as? [String:Any] ?? [:];token=o.str("AccessToken");userID=o.dict("User").str("Id")
                guard !token.isEmpty && !userID.isEmpty else { throw AppError.message("Emby 登录结果不完整。") }
            }
        case .tr: break
        }
        loggedIn=true
    }
    func prepareReadSession() async throws { try Task.checkCancellation(); try await login() }

    /// Preserves the success envelope and permits one bounded resource search.
    /// Mutation callers must pass both a current authorization check and a durable intent hook.
    func moviePilotResponse(_ path:String, method:String="GET", query:[String:String]=[:], json:[String:Any]?=nil,
                            timeout:TimeInterval=18, authorize:(@Sendable () async -> Bool)?=nil,
                            beforeSend:(@Sendable () async throws -> Void)?=nil) async throws -> [String:Any] {
        guard profile.kind == .moviepilot else { throw AppError.message("当前服务不是 MoviePilot。") }
        if method != "GET" {
            guard let authorize=authorize, beforeSend != nil, await authorize() else { throw AppError.message("当前只读或权限已变化，下载未提交。") }
        }
        try await login(); try Task.checkCancellation()
        if method != "GET" {
            guard let authorize=authorize, let beforeSend=beforeSend, await authorize() else { throw AppError.message("管理权限或连接已变化，下载未提交。") }
            try await beforeSend()
            try Task.checkCancellation()
            guard await authorize() else { throw AppError.message("权限已变化，请核对原管理页；未自动重试。") }
        }
        let headers=credentials.apiKey.isEmpty ? ["Authorization":"Bearer "+token]:["X-API-KEY":credentials.apiKey]
        let (data,response)=try await request(path,method:method,query:query,json:json,headers:headers,timeout:timeout)
        try check(response)
        guard let value=try decode(data) as? [String:Any], value["success"] is Bool else { throw AppError.message("MoviePilot 响应缺少业务结果，未自动重试。") }
        return value
    }
    private func origin(_ u:URL)->String { var c=URLComponents();c.scheme=u.scheme;c.host=u.host;c.port=u.port;return c.string ?? "" }
    func get(_ path:String,query:[String:String]=[:]) async throws -> Any {
        try await login();var headers=[String:String]()
        if profile.kind == .moviepilot { headers=credentials.apiKey.isEmpty ? ["Authorization":"Bearer "+token]:["X-API-KEY":credentials.apiKey] }
        if profile.kind == .emby { headers=["X-Emby-Token":token] }
        let (data,response)=try await request(path,query:query,headers:headers);try check(response)
        if profile.kind == .moviepilot {
            let value=try decode(data)
            if let o=value as? [String:Any], let success=o["success"] as? Bool {
                guard success else { throw AppError.message("MoviePilot 拒绝此请求，请在原管理页查看详细原因。") }
                return o["data"] ?? NSNull()
            };return value
        }
        return try decode(data)
    }
    func rpc(_ method:String,args:[String:Any]=[:],authorize:(@Sendable () async -> Bool)?=nil) async throws -> [String:Any] {
        let basic=Data((credentials.username+":"+credentials.password).utf8).base64EncodedString()
        for challenge in 0...1 {
            try Task.checkCancellation()
            if let authorize=authorize, !(await authorize()) { throw AppError.message("管理权限或连接已变化，操作已取消。") }
            var h=["Authorization":"Basic "+basic];if !trSession.isEmpty { h["X-Transmission-Session-Id"]=trSession }
            let (d,r)=try await request("/transmission/rpc",method:"POST",json:["method":method,"arguments":args],headers:h)
            if r.statusCode == 409 && challenge == 0, let sid=r.value(forHTTPHeaderField:"X-Transmission-Session-Id") { trSession=sid;continue }
            try check(r);let value=try decode(d) as? [String:Any] ?? [:]
            guard value.str("result") == "success" else { throw AppError.message("TR 拒绝请求，操作未自动重试。") }
            return value.dict("arguments")
        }
        throw AppError.message("TR 会话校验未完成。")
    }
    func snapshot() async throws -> ServiceSnapshot {
        switch profile.kind {
        case .qb1,.qb2:
            let v=try await get("/api/v2/transfer/info") as? [String:Any] ?? [:]
            guard v["dl_info_speed"] != nil else { throw AppError.message("qB 流量信息缺失。") }
            let limit=v.num("up_rate_limit");let label=limit > 0 ? String(format:"%.1f Mbps",limit/125000):"未限制"
            return ServiceSnapshot(kind:profile.kind,online:true,detail:"qBittorrent \(qbVersion) · 上传上限 \(label)",downloadRate:v.num("dl_info_speed"),uploadRate:v.num("up_info_speed"))
        case .tr:
            let v=try await rpc("session-stats")
            guard v["torrentCount"] != nil else { throw AppError.message("TR 状态信息缺失。") }
            return ServiceSnapshot(kind:.tr,online:true,detail:"长期保种 · 只读挂载片库",downloadRate:v.num("downloadSpeed"),uploadRate:v.num("uploadSpeed"),taskCount:Int(v.num("torrentCount")),activeCount:Int(v.num("activeTorrentCount")))
        case .moviepilot:
            let v=try await get("/api/v1/subscribe/") as? [[String:Any]]
            guard let v=v else { throw AppError.message("MoviePilot 订阅列表格式不符。") }
            return ServiceSnapshot(kind:.moviepilot,online:true,detail:"\(v.count) 个订阅",taskCount:v.count)
        case .emby:
            let v=try await get("/emby/System/Info") as? [String:Any] ?? [:]
            guard !v.str("Version").isEmpty else { throw AppError.message("Emby 系统信息缺失。") }
            return ServiceSnapshot(kind:.emby,online:true,detail:"Emby \(v.str("Version"))")
        }
    }
    func tasks() async throws -> [TorrentTask] {
        if profile.kind == .tr {
            let fields=["hashString","name","status","percentDone","totalSize","leftUntilDone","rateDownload","rateUpload","uploadRatio","error","downloadDir","labels","recheckProgress","peersSendingToUs","peersGettingFromUs"]
            let r=try await rpc("torrent-get",args:["fields":fields])
            guard let rows=r["torrents"] as? [[String:Any]], rows.allSatisfy({EndpointPolicy.validTaskID($0.str("hashString"),kind:.tr) && $0["status"] is NSNumber && (0...6).contains($0.num("status")) && $0["percentDone"] is NSNumber && (0...1).contains($0.num("percentDone")) && $0["error"] is NSNumber}) else{throw AppError.message("TR 任务数据不完整，保留上次列表。")}
            return rows.map(TaskParser.tr)
        }
        guard let data=try await get("/api/v2/sync/maindata",query:["rid":"0"]) as? [String:Any], data["full_update"] as? Bool == true,
              let map=data["torrents"] as? [String:[String:Any]] else { throw AppError.message("qB 任务列表不完整，保留上次列表。") }
        let rows=map.map { hash,row -> [String:Any] in var value=row;value["hash"]=hash;return value }
        guard rows.allSatisfy({EndpointPolicy.validTaskID($0.str("hash"),kind:profile.kind) && $0["state"] is String && $0["progress"] is NSNumber}) else { throw AppError.message("qB 任务列表格式不符，保留上次列表。") }
        return rows.map{TaskParser.qb($0,kind:profile.kind)}
    }
    func subscriptions() async throws -> [Subscription] {
        guard let rows=try await get("/api/v1/subscribe/") as? [[String:Any]] else{throw AppError.message("订阅列表数据不完整。")}
        return rows.map(Self.parseSubscription)
    }
    static func parseSubscription(_ r:[String:Any]) -> Subscription {
        let total=DashboardParser.number(r["total_episode"]), missing=DashboardParser.number(r["lack_episode"])
        let known=total != nil && missing != nil && total! > 0 && missing! <= total!
        let raw=r.str("state"), source=r.str("media_source").lowercased()
        let season=DashboardParser.number(r["season"]).flatMap { $0 <= 10000 && $0.rounded() == $0 ? Int($0):nil }
        let seasonTitle=season.map{$0 == 0 ? "特别篇":"第 \($0) 季"} ?? ""
        return Subscription(id:r.str("id"),title:r.str("name"),detail:[r.str("year"),r.str("type"),seasonTitle].filter{!$0.isEmpty}.joined(separator:" · "),state:MPSubscriptionFilter.title(for:raw),poster:MPDiscoveryParser.artwork(r.str("poster")),progress:known ? (total!-missing!)/total!:0,mediaSource:source == "tmdb" ? "themoviedb":source,mediaID:r.str("media_id"),season:season,rawState:raw,progressKnown:known,mediaType:r.str("type"))
    }
    func postMoviePilotSubscription(_ payload:[String:Any], authorize:@escaping @Sendable () async -> Bool, beforeSend:@escaping @Sendable () async throws -> Void) async throws -> [String:Any] {
        guard profile.kind == .moviepilot, await authorize() else { throw AppError.message("当前只读或权限已变化，订阅未提交。") }
        try await login()
        guard await authorize() else { throw AppError.message("管理权限或连接已变化，订阅未提交。") }
        try await beforeSend()
        guard await authorize() else { throw AppError.message("管理权限或连接已变化，请先核对订阅状态。") }
        let headers=credentials.apiKey.isEmpty ? ["Authorization":"Bearer "+token]:["X-API-KEY":credentials.apiKey]
        let (data,response)=try await request("/api/v1/subscribe/",method:"POST",json:payload,headers:headers)
        try check(response)
        guard let value=try decode(data) as? [String:Any] else { throw AppError.message("订阅提交结果无法确认，请勿重复提交。") }
        return value
    }
    func sites() async throws -> [SiteAccount] {
        guard let rows=try await get("/api/v1/site/userdata/latest") as? [[String:Any]] else{throw AppError.message("站点缓存列表数据不完整。")}
        return rows.enumerated().map{index,r in
            let known=r["err_msg"] is String && ["upload","download","ratio","seeding"].allSatisfy{r[$0] is NSNumber} && !r.str("updated_time").isEmpty
            let good=known && r.str("err_msg").isEmpty
            return SiteAccount(id:String(index),name:r.str("name"),uploaded:r.num("upload"),downloaded:r.num("download"),ratio:r.num("ratio"),seeding:Int(r.num("seeding")),enabled:good,hasData:good,status:good ? "缓存更新："+r.str("updated_day")+" "+r.str("updated_time"):(known ? "站点数据读取异常":"站点数据不完整"))
        }
    }
    func search(_ query:String) async throws -> [MediaItem] {
        let value=try await get("/api/v1/media/search",query:["title":query,"type":"media","page":"1","count":"20"])
        guard let rows=(value as? [[String:Any]]) ?? ((value as? [String:Any])?["results"] as? [[String:Any]]) else{throw AppError.message("影视资料搜索结果不完整。")}
        return rows.map{r in MediaItem(id:r.str("media_source","tmdb")+":"+r.str("media_id",r.str("tmdb_id",r.str("douban_id",r.str("title")))),title:r.str("title",r.str("name")),detail:[r.str("year"),r.str("type"),r.str("vote_average")].filter{!$0.isEmpty}.joined(separator:" · "),poster:r.str("poster_path").isEmpty ? nil:r.str("poster_path"),overview:r.str("overview"),kind:r.str("type"))}
    }
    func embyLibrary(_ query:String) async throws -> [MediaItem] {
        try await login()
        var q=["Recursive":"true","IncludeItemTypes":"Movie,Series","Limit":"60","SortBy":"DateCreated","SortOrder":"Descending","Fields":"Overview","EnableUserData":"true"]
        if !query.isEmpty { q["SearchTerm"]=query }
        guard let v=try await get("/emby/Users/\(userID)/Items",query:q) as? [String:Any], let rows=v["Items"] as? [[String:Any]] else{throw AppError.message("Emby 片库数据不完整。")}
        return rows.map { r in MediaItem(id:r.str("Id"),title:r.str("Name"),detail:[r.str("ProductionYear"),r.str("Type") == "Series" ? "剧集":"电影"].filter{!$0.isEmpty}.joined(separator:" · "),poster:"dkemby:"+r.str("Id"),overview:r.str("Overview"),kind:r.str("Type"),favorite:r.dict("UserData").bool("IsFavorite"),played:r.dict("UserData").bool("Played")) }
    }
    func embyImage(_ id:String) async throws -> Data {
        guard !id.isEmpty && id.utf8.allSatisfy({(48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)}) else{throw AppError.message("海报编号无效。")}
        try await login();let(d,r)=try await request("/emby/Items/\(id)/Images/Primary",query:["MaxHeight":"360","Quality":"80"],headers:["X-Emby-Token":token]);try check(r)
        guard r.value(forHTTPHeaderField:"Content-Type")?.hasPrefix("image/") == true && d.count <= 4_194_304 else{throw AppError.message("海报数据无效。")};return d
    }
    func embySessions() async throws -> [PlaybackSession] {
        guard let v=try await get("/emby/Sessions") as? [[String:Any]] else{throw AppError.message("Emby 播放状态数据不完整。")}
        return v.filter{!$0.dict("NowPlayingItem").isEmpty}.map{ r in let item=r.dict("NowPlayingItem"),p=r.dict("PlayState");return PlaybackSession(id:r.str("Id"),title:item.str("Name"),user:r.str("UserName"),device:r.str("DeviceName"),position:p.num("PositionTicks")/10_000_000,duration:item.num("RunTimeTicks")/10_000_000,paused:p.bool("IsPaused")) }
    }
    func subscriptionState(id:String,paused:Bool,authorize:@escaping @Sendable () async -> Bool = {true}) async throws {
        guard Int(id) != nil else { throw AppError.message("订阅编号无效。") }
        try await login()
        let headers=credentials.apiKey.isEmpty ? ["Authorization":"Bearer "+token]:["X-API-KEY":credentials.apiKey]
        guard await authorize() else{throw AppError.message("管理权限或连接已变化，操作已取消。")}
        let(d,r)=try await request("/api/v1/subscribe/status/"+id,method:"PUT",query:["state":paused ? "S":"R"],headers:headers);try check(r)
        guard (try decode(d) as? [String:Any])?.bool("success") == true else{throw AppError.message("订阅状态更新未确认，请核对原管理页。")}
    }
    func taskAction(id:String,start:Bool,authorize:@escaping @Sendable () async -> Bool = {true}) async throws {
        guard EndpointPolicy.validTaskID(id,kind:profile.kind) else{throw AppError.message("任务 Hash 无效，已阻止可能的批量操作。")}
        try await login()
        if profile.kind == .tr { _=try await rpc(start ? "torrent-start":"torrent-stop",args:["ids":[id]],authorize:authorize);return }
        let modern=qbVersion.hasPrefix("v5")
        let action=start ? (modern ? "start":"resume"):(modern ? "stop":"pause")
        let base=try EndpointPolicy.validate(profile.baseURL)
        guard await authorize() else{throw AppError.message("管理权限或连接已变化，操作已取消。")}
        let (_,r)=try await request("/api/v2/torrents/"+action,method:"POST",form:["hashes":id],headers:["Origin":origin(base),"Referer":base.absoluteString+"/"]);try check(r)
    }
    func uploadLimit(mbps:Double,authorize:@escaping @Sendable () async -> Bool = {true}) async throws {
        guard mbps.isFinite && mbps >= 0 && mbps <= 10000 else { throw AppError.message("请输入 0–10000 Mbps。") }
        try await login()
        if profile.kind == .tr {
            _=try await rpc("session-set",args:["speed-limit-up-enabled":mbps > 0,"speed-limit-up":Int(mbps*125)],authorize:authorize)
            let v=try await rpc("session-get")
            guard v.bool("speed-limit-up-enabled") == (mbps > 0) && (mbps == 0 || v.num("speed-limit-up") == Double(Int(mbps*125))) else{throw AppError.message("限速回读不一致，请到 TR 核对；没有重试写操作。")};return
        }
        let base=try EndpointPolicy.validate(profile.baseURL)
        guard await authorize() else{throw AppError.message("管理权限或连接已变化，操作已取消。")}
        let (_,r)=try await request("/api/v2/transfer/setUploadLimit",method:"POST",form:["limit":String(Int(mbps*125000))],headers:["Origin":origin(base),"Referer":base.absoluteString+"/"]);try check(r)
        let v=try await get("/api/v2/transfer/info") as? [String:Any] ?? [:]
        guard v["up_rate_limit"] != nil && abs(v.num("up_rate_limit")-mbps*125000) <= 1024 else{throw AppError.message("限速回读不一致，请到 qB 核对；没有重试写操作。")}
    }
    func embyFlag(id:String,favorite:Bool?,played:Bool?,authorize:@escaping @Sendable () async -> Bool = {true}) async throws {
        try await login();let flag=favorite ?? played ?? false
        let path=favorite != nil ? "FavoriteItems":"PlayedItems"
        guard !id.isEmpty && id.allSatisfy({$0.isHexDigit || $0.isNumber}) else{throw AppError.message("片库项目编号无效。")}
        guard await authorize() else{throw AppError.message("管理权限或连接已变化，操作已取消。")}
        let (_,r)=try await request("/emby/Users/\(userID)/\(path)/\(id)",method:flag ? "POST":"DELETE",headers:["X-Emby-Token":token]);try check(r)
    }
}
