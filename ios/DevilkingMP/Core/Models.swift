import Foundation

/// Protocol capabilities are separate from the identity of a configured server.
enum ServiceProtocol: String, Codable, CaseIterable, Identifiable {
    case qbittorrent, transmission, moviepilot, emby
    var id: String { rawValue }
    var title: String { switch self { case .qbittorrent: return "qBittorrent"; case .transmission: return "Transmission"; case .moviepilot: return "MoviePilot"; case .emby: return "Emby" } }
    var subtitle: String { switch self { case .qbittorrent: return "下载与做种"; case .transmission: return "下载与长期保种"; case .moviepilot: return "订阅 · 站点 · 发现"; case .emby: return "片库 · 播放状态" } }
    var symbol: String { switch self { case .qbittorrent: return "arrow.down.circle.fill"; case .transmission: return "leaf.fill"; case .moviepilot: return "sparkles.tv.fill"; case .emby: return "play.rectangle.fill" } }
    var defaultURL: String { switch self { case .qbittorrent: return "http://192.168.1.100:8080"; case .transmission: return "http://192.168.1.100:9091"; case .moviepilot: return "http://192.168.1.100:3000"; case .emby: return "http://192.168.1.100:8096" } }
    var isDownloader: Bool { self == .qbittorrent || self == .transmission }
}

/// Stable instance identity. A display name, group or URL is never an identity.
/// Legacy values deliberately keep their original Keychain account names.
struct ServiceID: RawRepresentable, Codable, Hashable, Identifiable, CaseIterable {
    let rawValue: String
    var id: String { rawValue }
    private init(known rawValue: String) { self.rawValue = rawValue }
    init?(rawValue: String) {
        if Self.allCases.contains(where: { $0.rawValue == rawValue }) { self.rawValue = rawValue; return }
        let parts = rawValue.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, ["qb", "tr"].contains(String(parts[0])),
              let uuid = UUID(uuidString: String(parts[1])),
              uuid.uuidString.lowercased() == String(parts[1]).lowercased() else { return nil }
        self.rawValue = String(parts[0]) + ":" + uuid.uuidString.lowercased()
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let id = Self(rawValue: value) else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown server instance identity") }
        self = id
    }
    func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
    static let qb1 = Self(known: "qb1")
    static let qb2 = Self(known: "qb2")
    static let tr = Self(known: "tr")
    static let moviepilot = Self(known: "moviepilot")
    static let emby = Self(known: "emby")
    /// Compatibility slots for old files and synthetic fixtures, never the live server list.
    static let allCases: [Self] = [.qb1, .qb2, .tr, .moviepilot, .emby]
    static func make(_ protocolKind: ServiceProtocol) -> Self {
        switch protocolKind {
        case .qbittorrent: return Self(known: "qb:" + UUID().uuidString.lowercased())
        case .transmission: return Self(known: "tr:" + UUID().uuidString.lowercased())
        case .moviepilot: return .moviepilot
        case .emby: return .emby
        }
    }
    var protocolKind: ServiceProtocol {
        if self == .moviepilot { return .moviepilot }
        if self == .emby { return .emby }
        if self == .tr || rawValue.hasPrefix("tr:") { return .transmission }
        return .qbittorrent
    }
    var title: String {
        switch self {
        case .qb1: return "家庭 qB1"
        case .qb2: return "家庭 qB2"
        case .tr: return "长期保种 TR"
        default: return protocolKind.title
        }
    }
    var subtitle: String {
        switch self {
        case .qb1: return "主力下载 · 自抓发布"
        case .qb2: return "转载发布 · 备用"
        case .tr: return "片库长期保种"
        default: return protocolKind.subtitle
        }
    }
    var symbol: String { protocolKind.symbol }
    var defaultURL: String {
        if self == .qb1 { return "http://192.168.1.100:8085" }
        if self == .qb2 { return "http://192.168.1.100:8086" }
        return protocolKind.defaultURL
    }
    var isDownloader: Bool { protocolKind.isDownloader }
    var isQB: Bool { protocolKind == .qbittorrent }
    var isTR: Bool { protocolKind == .transmission }
    var isLegacy: Bool { Self.allCases.contains(self) }
}

/// Source compatibility with earlier API and fixture code; this is an instance ID.
typealias ServiceKind = ServiceID

struct ServiceProfile: Codable, Identifiable {
    let kind: ServiceID
    var baseURL: String
    var username: String
    var allowActions: Bool
    var name: String
    var enabled: Bool
    var migrationProtected: Bool
    var id: ServiceID { kind }
    var protocolKind: ServiceProtocol { kind.protocolKind }
    var displayName: String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? kind.title : value
    }
    init(kind: ServiceID, baseURL: String, username: String, allowActions: Bool = false,
         name: String? = nil, enabled: Bool = true, migrationProtected: Bool? = nil) {
        self.kind = kind; self.baseURL = baseURL; self.username = username; self.allowActions = allowActions
        self.name = name ?? kind.title; self.enabled = enabled
        self.migrationProtected = migrationProtected ?? (kind == .qb1 || kind == .tr)
    }
    private enum CodingKeys: String, CodingKey { case kind, baseURL, username, allowActions, name, enabled, migrationProtected }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(ServiceID.self, forKey: .kind)
        self.init(kind: kind, baseURL: try values.decode(String.self, forKey: .baseURL),
                  username: try values.decodeIfPresent(String.self, forKey: .username) ?? "",
                  allowActions: try values.decodeIfPresent(Bool.self, forKey: .allowActions) ?? false,
                  name: try values.decodeIfPresent(String.self, forKey: .name),
                  enabled: try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
                  migrationProtected: try values.decodeIfPresent(Bool.self, forKey: .migrationProtected))
    }
}
struct Credential: Codable { var username = ""; var password = ""; var apiKey = ""; var isEmpty: Bool { password.isEmpty && apiKey.isEmpty } }
struct ServiceSnapshot {
    var kind: ServiceKind; var online: Bool; var detail: String
    var downloadRate: Double = 0; var uploadRate: Double = 0
    var taskCount: Int?; var activeCount: Int?; var error: String?; var updatedAt = Date()
}
struct TorrentTask: Identifiable {
    var id: String; var kind: ServiceKind; var name: String; var progress: Double; var state: String
    var category: String; var tags: [String]; var size: Int64
    var downloadRate: Double; var uploadRate: Double; var ratio: Double; var seeds: Int; var peers: Int
    var error: String?; var path: String; var isComplete: Bool; var isStopped: Bool; var verification: Double?
    var rawState: String = ""
    var qualifiedID: String { kind.rawValue+":"+id }
}
struct Subscription: Identifiable {
    var id: String; var title: String; var detail: String; var state: String; var poster: String?; var progress: Double
    var mediaSource:String = ""; var mediaID:String = ""; var season:Int? = nil; var rawState:String = ""; var progressKnown:Bool = true; var mediaType:String = ""
}
struct SiteAccount: Identifiable { var id: String; var name: String; var uploaded: Double; var downloaded: Double; var ratio: Double; var seeding: Int; var enabled: Bool; var hasData:Bool = true; var status:String = "" }
struct MediaItem: Identifiable { var id: String; var title: String; var detail: String; var poster: String?; var overview: String; var kind: String; var favorite: Bool = false; var played: Bool = false }
struct PlaybackSession: Identifiable { var id: String; var title: String; var user: String; var device: String; var position: Double; var duration: Double; var paused: Bool }

enum Format {
    static func bytes(_ value: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(min(9_000_000_000_000_000_000,max(0,value.isFinite ? value : 0))), countStyle: .binary) }
    static func rate(_ value: Double) -> String { bytes(value) + "/s" }
    static func ratio(_ value: Double) -> String { value < 0 ? "∞" : String(format: "%.2f", value) }
}
enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return text } }
}

// Tolerant protocol parsing; unknown remote fields never become implied health.
extension Dictionary where Key == String, Value == Any {
    func str(_ key: String, _ fallback: String = "") -> String { if let s=self[key] as? String { return s }; if let n=self[key] as? NSNumber { return n.stringValue }; return fallback }
    func num(_ key: String) -> Double { let n=(self[key] as? NSNumber)?.doubleValue ?? Double(str(key)) ?? 0;return n.isFinite && abs(n) <= 9_000_000_000_000_000 ? n:0 }
    func bool(_ key: String) -> Bool { (self[key] as? Bool) ?? false }
    func dict(_ key: String) -> [String:Any] { self[key] as? [String:Any] ?? [:] }
    func rows(_ key: String) -> [[String:Any]] { self[key] as? [[String:Any]] ?? [] }
}

enum TaskParser {
    static func qb(_ r: [String:Any], kind: ServiceKind) -> TorrentTask {
        let s=r.str("state"); let stopped=["stoppedUP","stoppedDL","pausedUP","pausedDL"].contains(s)
        let states=["stalledUP":"做种 · 暂无请求","uploading":"正在上传","stoppedUP":"已停止做种","pausedUP":"已停止做种","stalledDL":"下载 · 等待来源","downloading":"正在下载","stoppedDL":"已停止下载","pausedDL":"已停止下载","queuedDL":"下载排队","queuedUP":"上传排队","checkingUP":"正在校验","checkingDL":"正在校验","checkingResumeData":"检查恢复数据","error":"文件错误","missingFiles":"文件缺失","metaDL":"获取元数据","forcedUP":"强制做种","forcedDL":"强制下载","moving":"正在移动"]
        let progress=r.num("progress")
        return TorrentTask(id:r.str("hash"),kind:kind,name:r.str("name"),progress:progress,state:states[s] ?? s,category:r.str("category"),tags:r.str("tags").split(separator:",").map{$0.trimmingCharacters(in:.whitespaces)},size:Int64(r.num("total_size") > 0 ? r.num("total_size"):r.num("size")),downloadRate:r.num("dlspeed"),uploadRate:r.num("upspeed"),ratio:r.num("ratio"),seeds:Int(r.num("num_seeds")),peers:Int(r.num("num_leechs")),error:["error","missingFiles"].contains(s) ? (states[s] ?? s):((r.bool("has_tracker_error") || r.bool("has_other_announce_error")) ? "Tracker 连接异常":nil),path:r.str("save_path"),isComplete:progress >= 1,isStopped:stopped,verification:s.hasPrefix("checking") ? progress:nil,rawState:s)
    }
    static func tr(_ r: [String:Any], kind: ServiceID = .tr) -> TorrentTask {
        let s=r["status"] is NSNumber ? Int(r.num("status")) : -1; let states=[0:"已停止",1:"等待校验",2:"正在校验",3:"下载排队",4:"正在下载",5:"做种排队",6:"正在做种"]
        return TorrentTask(id:r.str("hashString"),kind:kind,name:r.str("name"),progress:r.num("percentDone"),state:states[s] ?? "未知状态",category:"",tags:r["labels"] as? [String] ?? [],size:Int64(r.num("totalSize")),downloadRate:r.num("rateDownload"),uploadRate:r.num("rateUpload"),ratio:r.num("uploadRatio"),seeds:Int(r.num("peersSendingToUs")),peers:Int(r.num("peersGettingFromUs")),error:r.num("error") > 0 ? "Tracker 或本地异常（代码 \(Int(r.num("error"))))":nil,path:r.str("downloadDir"),isComplete:r.num("leftUntilDone") == 0 && r.num("percentDone") >= 1,isStopped:s == 0,verification:s == 1 || s == 2 ? r.num("recheckProgress"):nil,rawState:String(s))
    }
}
