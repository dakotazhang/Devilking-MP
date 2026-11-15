import Foundation
import CoreFoundation

extension APIClient {
    /// Bounded metadata reads. This does not search tracker resources or enqueue downloads.
    func discoverySections() async throws -> [MPDiscoverySection] {
        guard profile.kind == .moviepilot else { throw AppError.message("此服务不提供影视发现。") }
        let sources: [(String, String, String, MPBrowseCategory, String)] = [
            ("douban_showing", "豆瓣正在热映", "正在上映的新作品", .movie, "电影"),
            ("douban_movies", "豆瓣电影", "发现下一部想看的电影", .movie, "电影"),
            ("douban_tvs", "豆瓣剧集", "随时选择下一部追剧", .tv, "电视剧"),
            ("douban_tv_animation", "豆瓣动画", "动画与番剧推荐", .anime, "电视剧")
        ]
        var sections = [MPDiscoverySection]()
        for (source, title, subtitle, category, type) in sources {
            if Task.isCancelled { throw CancellationError() }
            do {
                let value = try await get("/api/v1/recommend/" + source, query: ["page": "1", "count": "12"])
                let rows = try Self.discoveryRows(value)
                var items = try Self.discoveryItems(rows, defaultSource: "douban", defaultType: type)
                if category == .anime { items = items.map { var item = $0; item.isAnime = true; return item } }
                sections.append(MPDiscoverySection(id: source, title: title, subtitle: subtitle, category: category, items: items))
            } catch {
                if Task.isCancelled { throw CancellationError() }
                sections.append(MPDiscoverySection(id: source, title: title, subtitle: subtitle, category: category, items: [], error: Self.discoveryError(error)))
            }
        }
        return sections
    }

    func searchDiscovery(_ query: String) async throws -> [MPDiscoveryItem] {
        guard profile.kind == .moviepilot else { throw AppError.message("此服务不提供影视搜索。") }
        let title = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 512 else { throw AppError.message("请输入有效片名，长度不超过 512 字节。") }
        let value = try await get("/api/v1/media/search", query: ["title": title, "type": "media", "page": "1", "count": "30"])
        return try Self.discoveryItems(Self.discoveryRows(value))
    }

    func mediaDetail(_ item: MPDiscoveryItem) async throws -> MPDiscoveryDetail {
        guard profile.kind == .moviepilot, item.hasSubscribableIdentity else { throw AppError.message("作品的媒体来源、编号或类型不完整。") }
        let source = Self.canonicalDiscoverySource(item.mediaSource)
        guard let row = try await get("/api/v1/media/" + item.mediaID, query: ["media_source": source, "type_name": item.canonicalType]) as? [String: Any] else {
            throw AppError.message("作品详情响应不完整。")
        }
        // A different response identity must fail closed; never relabel another work as this selection.
        guard Self.canonicalDiscoverySource(row.str("media_source")) == source,
              row.str("media_id") == item.mediaID,
              let parsed = MPDiscoveryParser.item(row), parsed.canonicalType == item.canonicalType else {
            throw AppError.message("作品详情的媒体身份不一致，请重新搜索后核对。")
        }
        var detail = row
        if item.isTV {
            let value = try await get("/api/v1/media/seasons", query: ["media_source": source, "media_id": item.mediaID, "type_name": item.canonicalType])
            let seasons = try Self.discoveryRows(value)
            detail["seasons"] = seasons
        }
        return MPDiscoveryParser.detail(detail, fallback: item)
    }

    /// Unknown or malformed responses throw; only an explicit null/empty id means no subscription.
    func existingSubscription(_ request: MPSubscriptionRequest) async throws -> Subscription? {
        guard profile.kind == .moviepilot, request.isValid else { throw AppError.message("订阅的作品身份或剧集季号无效。") }
        var query = ["media_source": Self.canonicalDiscoverySource(request.item.mediaSource), "mtype": request.item.canonicalType,
                     "title": request.item.title, "year": request.item.year]
        if request.item.isTV, let season = request.season { query["season"] = String(season) }
        guard let row = try await get("/api/v1/subscribe/media/" + request.item.mediaID, query: query) as? [String: Any] else {
            throw AppError.message("尚未确认是否已有订阅，请刷新后核对。")
        }
        guard row.keys.contains("id") else { throw AppError.message("订阅查重响应缺少编号，已停止提交。") }
        if row["id"] is NSNull || row.str("id").isEmpty { return nil }
        guard Self.subscriptionID(row["id"]) != nil, !row.str("name").isEmpty,
              row.str("type") == request.item.canonicalType else { throw AppError.message("已有订阅的类型或编号无法确认。") }
        if request.item.isTV {
            guard let season = Self.exactInteger(row["season"]), season == request.season else {
                throw AppError.message("已有订阅的剧集季号无法确认。")
            }
        }
        return Self.parseSubscription(row)
    }

    /// The only discovery mutation: one confirmed subscription POST, with no automatic retry.
    func createSubscription(_ request: MPSubscriptionRequest,
                            authorize: @escaping @Sendable () async -> Bool,
                            beforeSend: @escaping @Sendable () async throws -> Void) async throws -> String {
        // Deny before login or any other network activity when the app is read-only.
        guard await authorize() else { throw AppError.message("当前只读或权限已变化，订阅未提交。") }
        guard profile.kind == .moviepilot, request.isValid else { throw AppError.message("订阅的作品身份或剧集季号无效。") }
        if let existing = try await existingSubscription(request) { return existing.id }
        var payload: [String: Any] = ["name": request.item.title, "year": request.item.year,
                                     "type": request.item.canonicalType,
                                     "media_source": Self.canonicalDiscoverySource(request.item.mediaSource),
                                     "media_id": request.item.mediaID]
        if request.item.isTV, let season = request.season { payload["season"] = season }
        let response = try await postMoviePilotSubscription(payload, authorize: authorize, beforeSend: beforeSend)
        guard response["success"] as? Bool == true,
              let data = response["data"] as? [String: Any], let id = Self.subscriptionID(data["id"]) else {
            throw AppError.message("订阅提交结果尚未确认，请只读核对，勿重复提交。")
        }
        return id
    }

    private static func discoveryRows(_ value: Any) throws -> [[String: Any]] {
        guard let rows = value as? [[String: Any]], rows.count <= 200 else { throw AppError.message("影视资料列表格式不完整。") }
        return rows
    }

    private static func discoveryItems(_ rows: [[String: Any]], defaultSource: String? = nil, defaultType: String? = nil) throws -> [MPDiscoveryItem] {
        var result = [MPDiscoveryItem](), seen = Set<String>()
        for row in rows {
            guard let item = MPDiscoveryParser.item(row, defaultSource: defaultSource, defaultType: defaultType) else {
                throw AppError.message("影视资料缺少名称或媒体身份。")
            }
            if seen.insert(item.id).inserted { result.append(item) }
        }
        return result
    }

    private static func canonicalDiscoverySource(_ value: String) -> String { value.lowercased() == "tmdb" ? "themoviedb" : value.lowercased() }
    private static func subscriptionID(_ raw: Any?) -> String? {
        let value: String
        if let raw = raw as? NSNumber {
            guard CFGetTypeID(raw) != CFBooleanGetTypeID() else { return nil }
            value = raw.stringValue
        } else if let raw = raw as? String { value = raw }
        else { return nil }
        guard !value.isEmpty, value.utf8.count <= 20, value.utf8.allSatisfy({ (48...57).contains($0) }), value.contains(where: { $0 != "0" }) else { return nil }
        return value
    }
    private static func exactInteger(_ value: Any?) -> Int? {
        guard let value = value, !(value is NSNull) else { return nil }
        if let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() { return nil }
        guard let number = Double(String(describing: value)),
              number.isFinite, number >= 0, number <= 10000, number.rounded(.towardZero) == number else { return nil }
        return Int(number)
    }
    private static func discoveryError(_ error: Error) -> String {
        if let error = error as? AppError { return error.localizedDescription }
        if let error = error as? URLError, error.code == .timedOut { return "连接超时，可稍后下拉重新读取。" }
        return "此栏目暂时无法读取，其他栏目仍可查看。"
    }
}
