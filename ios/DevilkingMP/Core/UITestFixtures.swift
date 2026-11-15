#if DEBUG
import Foundation

/// Synthetic UI-test data only. No credentials, Keychain writes, production
/// addresses, downloads or API clients are used. This file is absent in Release.
@MainActor enum UITestFixtures {
    static func apply(to model: AppModel) {
        model.uiFixtureMode = true
        model.profiles = [ServiceKind.qb1, .qb2, .tr, .moviepilot].map {
            ServiceProfile(kind: $0, baseURL: "https://fixture.invalid/" + $0.rawValue, username: "", allowActions: false)
        }
        model.readOnlyMode = true
        model.migrationProtection = true
        model.biometricEnabled = false
        model.locked = false
        model.snapshots = snapshots()
        model.dashboardSnapshots = dashboard()
        model.tasks = [ServiceKind.qb1, .qb2, .tr].flatMap { tasks($0) }
        model.subscriptions = subscriptions()
        model.sites = sites()
        model.discoverySections = sections()
        model.discoveryResults = []
        model.discoveryLoading = false
        model.discoverySearchLoading = false
        model.discoveryError = nil
    }

    static func snapshots() -> [ServiceKind: ServiceSnapshot] {
        [
            .qb1: ServiceSnapshot(kind: .qb1, online: true, detail: "合成 qB · 上传上限 60.0 Mbps", downloadRate: 12_800_000, uploadRate: 1_200_000, taskCount: 6),
            .qb2: ServiceSnapshot(kind: .qb2, online: true, detail: "合成 qB · 备用", taskCount: 0),
            .tr: ServiceSnapshot(kind: .tr, online: true, detail: "合成长期保种", uploadRate: 400_000, taskCount: 3),
            .moviepilot: ServiceSnapshot(kind: .moviepilot, online: true, detail: "合成影视资料与订阅", taskCount: 3)
        ]
    }

    static func dashboard() -> [ServiceKind: DashboardSnapshot] {
        let free = Double(16 * 1_099_511_627_776)
        return [
            .qb1: DashboardSnapshot(kind: .qb1, downloadRate: 12_800_000, uploadRate: 1_200_000,
                                   counts: DashboardTaskCounts(total: 6, downloading: 1, seeding: 1, verifying: 1, stopped: 1, errors: 1, queued: 1),
                                   disk: DashboardDiskReading(label: "默认下载盘", freeBytes: free), cumulativeDownloaded: 1_200_000_000_000, cumulativeUploaded: 2_400_000_000_000, peerConnectivity: "入站已连接"),
            .qb2: DashboardSnapshot(kind: .qb2, downloadRate: 0, uploadRate: 0, counts: DashboardTaskCounts(),
                                   disk: DashboardDiskReading(label: "默认下载盘", freeBytes: free), cumulativeDownloaded: 0, cumulativeUploaded: 0, peerConnectivity: "入站已连接"),
            .tr: DashboardSnapshot(kind: .tr, downloadRate: 0, uploadRate: 400_000,
                                  counts: DashboardTaskCounts(total: 3, seeding: 1, verifying: 1, stopped: 1),
                                  disk: DashboardDiskReading(label: "默认下载目录", freeBytes: free), cumulativeDownloaded: 0, cumulativeUploaded: 800_000_000_000)
        ]
    }

    static func tasks(_ kind: ServiceKind) -> [TorrentTask] {
        if kind == .qb1 {
            let states = ["downloading", "stalledUP", "checkingUP", "stoppedUP", "missingFiles", "queuedDL"]
            let names = ["合成纪录片 · 正在下载", "合成电影 · 长期做种", "合成剧集 · 分片校验", "合成动画 · 已停止", "合成任务 · 文件异常", "合成电影 · 下载排队"]
            return states.enumerated().map { index, state in
                TaskParser.qb(["hash": String(repeating: String(index + 1), count: 40), "name": names[index], "state": state,
                               "progress": index == 0 ? 0.42 : (index == 2 ? 0.63 : 1.0), "total_size": 24_000_000_000,
                               "dlspeed": index == 0 ? 12_800_000 : 0, "upspeed": index == 1 ? 1_200_000 : 0,
                               "category": "合成站点", "tags": "keep,片库保种", "ratio": 2.0, "num_seeds": 18, "num_leechs": 2,
                               "save_path": "/synthetic/media"], kind: .qb1)
            }
        }
        if kind == .tr {
            return [6, 2, 0].enumerated().map { index, state in
                TaskParser.tr(["hashString": String(repeating: String(index + 7), count: 40), "name": ["合成冷种 · 做种", "合成冷种 · 校验", "合成冷种 · 已停止"][index],
                               "status": state, "percentDone": 1.0, "leftUntilDone": 0, "totalSize": 32_000_000_000,
                               "rateDownload": 0, "rateUpload": index == 0 ? 400_000 : 0, "uploadRatio": 3.0,
                               "error": 0, "downloadDir": "/synthetic/media", "labels": ["keep"], "recheckProgress": 0.38])
            }
        }
        return []
    }

    static func sections() -> [MPDiscoverySection] {
        let media = catalog()
        return [
            MPDiscoverySection(id: "fixture-showing", title: "豆瓣正在热映", subtitle: "合成资料 · 仅供界面测试", category: .movie, items: Array(media.prefix(2))),
            MPDiscoverySection(id: "fixture-movies", title: "豆瓣电影", subtitle: "发现下一部作品", category: .movie, items: [media[2], media[3]]),
            MPDiscoverySection(id: "fixture-tv", title: "豆瓣剧集", subtitle: "选择想追订的一季", category: .tv, items: [media[4], media[5]]),
            MPDiscoverySection(id: "fixture-anime", title: "豆瓣动画", subtitle: "合成动画推荐", category: .anime, items: [media[6], media[7]])
        ]
    }

    static func search(_ query: String) -> [MPDiscoveryItem] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return catalog().filter { text.isEmpty || $0.title.localizedCaseInsensitiveContains(text) || $0.overview.localizedCaseInsensitiveContains(text) }
    }

    static func detail(_ item: MPDiscoveryItem) -> MPDiscoveryDetail {
        MPDiscoveryDetail(item: item, seasons: item.isTV ? [
            MPSeason(number: 0, name: "特别篇", episodeCount: 2, poster: nil),
            MPSeason(number: 1, name: "第一季", episodeCount: 12, poster: nil),
            MPSeason(number: 2, name: "第二季", episodeCount: 10, poster: nil)
        ] : [])
    }

    static func subscriptions() -> [Subscription] {
        [
            Subscription(id: "88001", title: "合成追订 · 海港来信", detail: "2026 · 电视剧 · 第1季", state: "R", poster: nil, progress: 0.5,
                         mediaSource: "themoviedb", mediaID: "990020", season: 1, rawState: "R", progressKnown: true, mediaType: "电视剧"),
            Subscription(id: "88002", title: "合成暂停 · 山川回声", detail: "2025 · 电视剧 · 第2季", state: "S", poster: nil, progress: 0.2,
                         mediaSource: "themoviedb", mediaID: "990021", season: 2, rawState: "S", progressKnown: true, mediaType: "电视剧"),
            Subscription(id: "88003", title: "合成等待 · 秋日旅程", detail: "2026 · 电影", state: "N", poster: nil, progress: 0,
                         mediaSource: "themoviedb", mediaID: "990022", season: nil, rawState: "N", progressKnown: false, mediaType: "电影")
        ]
    }

    static func sites() -> [SiteAccount] {
        [SiteAccount(id: "fixture-site", name: "合成站点", uploaded: 2_000_000_000_000, downloaded: 300_000_000_000,
                     ratio: 6.67, seeding: 128, enabled: true, hasData: true, status: "合成缓存，非真实账号")]
    }

    private static func catalog() -> [MPDiscoveryItem] {
        let entries = [("990001", "合成电影：星海远航", "电影"), ("990002", "合成电影：风中的约定", "电影"),
                       ("990003", "合成电影：城市光影", "电影"), ("990004", "合成电影：初夏来信", "电影"),
                       ("990005", "合成剧集：星河守望", "电视剧"), ("990006", "合成剧集：山海之间", "电视剧"),
                       ("990007", "合成动画：云端花园", "电视剧"), ("990008", "合成动画：冬日物语", "电影")]
        return entries.enumerated().map { index, entry in
            MPDiscoveryItem(mediaSource: "themoviedb", mediaID: entry.0, title: entry.1, year: "2026", mediaType: entry.2,
                            poster: nil, backdrop: nil, overview: "这是一部完全虚构的测试作品，用于验证发现、搜索、剧集选季和只读订阅保护。不会搜索站点或下载任何内容。",
                            rating: 7.1 + Double(index) / 10, genres: index >= 6 ? ["动画"] : ["剧情"], isAnime: index >= 6)
        }
    }
}
#endif
