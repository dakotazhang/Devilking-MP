import Foundation

enum MPBrowseCategory: String, CaseIterable, Identifiable {
    case all, movie, tv, anime
    var id: String { rawValue }
    var title: String {
        switch self { case .all: return "全部"; case .movie: return "电影"; case .tv: return "剧集"; case .anime: return "动漫" }
    }
    func includes(_ item: MPDiscoveryItem) -> Bool {
        switch self { case .all: return true; case .movie: return item.isMovie && !item.isAnime; case .tv: return item.isTV && !item.isAnime; case .anime: return item.isAnime }
    }
}

struct MPDiscoveryItem: Identifiable, Equatable {
    var mediaSource: String
    var mediaID: String
    var title: String
    var year: String
    var mediaType: String
    var poster: String?
    var backdrop: String?
    var overview: String
    var rating: Double?
    var genres: [String]
    var isAnime: Bool
    var id: String { "\(mediaSource):\(mediaID):\(canonicalType)" }
    var isTV: Bool { ["电视剧", "剧集", "tv", "series", "tvshow"].contains(mediaType.lowercased()) }
    var isMovie: Bool { ["电影", "movie", "film"].contains(mediaType.lowercased()) }
    var canonicalType: String { isTV ? "电视剧" : (isMovie ? "电影" : mediaType) }
    var typeTitle: String { isAnime ? (isTV ? "动画剧集" : "动画电影") : canonicalType }
    var hasSubscribableIdentity: Bool {
        ["themoviedb", "tmdb", "douban"].contains(mediaSource) && !mediaID.isEmpty && mediaID.count <= 20 &&
            mediaID.utf8.allSatisfy { (48...57).contains($0) } && mediaID.contains(where: { $0 != "0" }) && (isTV || isMovie)
    }
    var metadataLine: String { [year, typeTitle].filter { !$0.isEmpty }.joined(separator: " · ") }
}

struct MPDiscoverySection: Identifiable {
    var id: String
    var title: String
    var subtitle: String
    var category: MPBrowseCategory
    var items: [MPDiscoveryItem]
    var error: String? = nil
}

struct MPSeason: Identifiable, Equatable {
    var number: Int
    var name: String
    var episodeCount: Int?
    var poster: String?
    var id: Int { number }
    var title: String { name.isEmpty ? (number == 0 ? "特别篇" : "第 \(number) 季") : name }
}

struct MPDiscoveryDetail {
    var item: MPDiscoveryItem
    var seasons: [MPSeason]
}

struct MPSubscriptionRequest {
    var item: MPDiscoveryItem
    var season: Int?
    var identityKey: String { "\(item.id):\(item.isTV ? String(season ?? -1) : "movie")" }
    var isValid: Bool {
        item.hasSubscribableIdentity && (item.isTV ? (season != nil && (season ?? -1) >= 0 && (season ?? -1) <= 10000) : season == nil)
    }
}

enum MPSubscriptionFilter: String, CaseIterable, Identifiable {
    case all, active, paused
    var id: String { rawValue }
    var title: String { switch self { case .all: return "全部"; case .active: return "追订中"; case .paused: return "已暂停" } }
    static func canonicalState(_ state: String) -> String {
        let value = state.trimmingCharacters(in: .whitespacesAndNewlines)
        switch value.uppercased() {
        case "S", "已暂停", "暂停": return "S"
        case "R", "订阅中", "运行中": return "R"
        case "N", "新建", "等待": return "N"
        case "P", "待定": return "P"
        case "Q", "排队中": return "Q"
        default: return value
        }
    }
    func includes(_ state: String) -> Bool {
        let value = Self.canonicalState(state)
        switch self { case .all: return true; case .active: return ["N", "R", "P", "Q"].contains(value); case .paused: return value == "S" }
    }
    static func title(for state: String) -> String {
        switch canonicalState(state) {
        case "S": return "已暂停"; case "R": return "订阅中"; case "N": return "等待订阅"; case "P": return "待定"; case "Q": return "排队中"
        default: return "状态未知"
        }
    }
}

enum MPDiscoveryParser {
    /// Public artwork URLs never inherit the service's authentication headers or URL parameters.
    static func artwork(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        let normalized = raw.hasPrefix("/") && !raw.hasPrefix("//") ? "https://image.tmdb.org/t/p/w500" + raw : raw
        guard let parts = URLComponents(string: normalized), parts.scheme == "https", parts.host != nil,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { return nil }
        return parts.url?.absoluteString
    }

    static func item(_ row: [String: Any], defaultSource: String? = nil, defaultType: String? = nil) -> MPDiscoveryItem? {
        let source: String
        if !row.str("media_source").isEmpty { source = canonicalSource(row.str("media_source")) }
        else if !row.str("tmdb_id").isEmpty { source = "themoviedb" }
        else if !row.str("douban_id").isEmpty { source = "douban" }
        else { source = canonicalSource(defaultSource ?? "") }
        let nativeID = row.str("media_id")
        let sourceID = source == "douban" ? row.str("douban_id") : row.str("tmdb_id")
        let identifier = !nativeID.isEmpty ? nativeID : (!sourceID.isEmpty ? sourceID : row.str("id"))
        let title = row.str("title", row.str("name"))
        guard !title.isEmpty, !identifier.isEmpty else { return nil }
        let type = row.str("type", row.str("media_type", defaultType ?? ""))
        let genreNames = (row["genres"] as? [String]) ?? row.rows("genres").map { $0.str("name") }
        let genreIDs = row["genre_ids"] as? [Int] ?? row.rows("genres").compactMap { ($0["id"] as? NSNumber)?.intValue }
        let animated = genreIDs.contains(16) || genreNames.contains { ["animation", "动画", "动漫"].contains($0.lowercased()) } || ["动漫", "动画"].contains(type)
        let rawRating = (row["vote_average"] as? NSNumber)?.doubleValue ?? Double(row.str("vote_average"))
        let rating = rawRating.flatMap { $0.isFinite && $0 > 0 && $0 <= 10 ? $0 : nil }
        let date = row.str("release_date", row.str("first_air_date"))
        let year = row.str("year", date.count >= 4 ? String(date.prefix(4)) : "")
        return MPDiscoveryItem(mediaSource: source, mediaID: identifier, title: title, year: year, mediaType: type,
                               poster: artwork(row.str("poster_path", row.str("poster"))), backdrop: artwork(row.str("backdrop_path")),
                               overview: row.str("overview", row.str("description")), rating: rating, genres: genreNames, isAnime: animated)
    }

    static func detail(_ row: [String: Any], fallback: MPDiscoveryItem) -> MPDiscoveryDetail {
        var combined = row
        // A detail response cannot silently switch a discovery selection to another identity.
        combined["media_source"] = fallback.mediaSource
        combined["media_id"] = fallback.mediaID
        if combined.str("title", combined.str("name")).isEmpty { combined["title"] = fallback.title }
        combined["type"] = fallback.mediaType
        var result = item(combined) ?? fallback
        if result.poster == nil { result.poster = fallback.poster }
        if result.backdrop == nil { result.backdrop = fallback.backdrop }
        if result.year.isEmpty { result.year = fallback.year }
        if result.overview.isEmpty { result.overview = fallback.overview }
        if result.rating == nil { result.rating = fallback.rating }
        result.isAnime = result.isAnime || fallback.isAnime
        var seen = Set<Int>()
        let seasons = row.rows("seasons").compactMap { value -> MPSeason? in
            let raw = (value["season_number"] as? NSNumber)?.doubleValue ?? Double(value.str("season_number"))
            guard let rawNumber = raw, rawNumber.isFinite, rawNumber >= 0, rawNumber <= 10000,
                  rawNumber.rounded(.towardZero) == rawNumber else { return nil }
            let number = Int(rawNumber)
            guard number >= 0, number <= 10000, seen.insert(number).inserted else { return nil }
            let count = value["episode_count"] as? NSNumber
            return MPSeason(number: number, name: value.str("name"), episodeCount: count.flatMap { $0.intValue >= 0 ? $0.intValue : nil }, poster: artwork(value.str("poster_path")))
        }.sorted { $0.number < $1.number }
        return MPDiscoveryDetail(item: result, seasons: seasons)
    }

    private static func canonicalSource(_ source: String) -> String {
        source.lowercased() == "tmdb" ? "themoviedb" : source.lowercased()
    }
}
