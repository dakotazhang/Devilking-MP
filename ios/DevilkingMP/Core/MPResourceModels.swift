import Foundation
import CoreFoundation
import CryptoKit

struct MPResourceSite: Identifiable, Equatable {
    var id: String
    var name: String
}

struct MPResourceDownloader: Identifiable, Equatable {
    var id: String
    var name: String
    var type: String
    var targetBaseURL: String? = nil
    var isDefault: Bool = false
    var bindingID: String { MPResourceParser.digest([id,type,targetBaseURL ?? "unknown"].joined(separator:"\n")) }
    var canBind: Bool { targetBaseURL != nil && !compatibleKinds.isEmpty }
    var compatibleKinds: [ServiceKind] {
        switch type.lowercased() { case "qbittorrent": return [.qb1, .qb2]; case "transmission": return [.tr]; default: return [] }
    }
}

struct MPResourceDirectory: Identifiable, Equatable {
    var id: String
    var name: String
    var savePath: String
    var storage: String = "local"
}

/// A search result lives only in memory. Restricted URLs and site credentials
/// are neither display fields nor Codable state, and never enter the intent ledger.
struct MPResourceItem: Identifiable, CustomStringConvertible, CustomDebugStringConvertible {
    var id: String
    var title: String
    var subtitle: String = ""
    var siteID: String
    var siteName: String
    var size: Double? = nil
    var seeders: Int? = nil
    var peers: Int? = nil
    var downloadFactor: Double? = nil
    var uploadFactor: Double? = nil
    var freeUntil: String? = nil
    var hasHR: Bool? = nil
    var payload: MPResourcePayload? = nil
    /// Runtime-only provenance. Never Codable or part of a server request.
    var connectionToken: UUID? = nil
    var canDownload: Bool { payload != nil && id.hasPrefix("resource:") }
    var description: String { "MPResourceItem(redacted)" }
    var debugDescription: String { description }
}

struct MPResourcePayload: CustomStringConvertible, CustomDebugStringConvertible {
    var media: [String: Any]
    var torrent: [String: Any]
    var description: String { "MPResourcePayload(redacted)" }
    var debugDescription: String { description }
}

struct MPResourceDownloadRequest {
    var item: MPResourceItem
    var downloader: MPResourceDownloader
    var directory: MPResourceDirectory? = nil
    var isValid: Bool {
        item.canDownload && !downloader.id.isEmpty && downloader.id == downloader.name &&
        downloader.canBind && (directory == nil || !(directory?.savePath.isEmpty ?? true))
    }
}

enum MPResourceParser {
    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func positiveID(_ raw: Any?) -> String? {
        guard let raw=raw, !(raw is NSNull) else { return nil }
        if let number=raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        let value=String(describing:raw)
        guard !value.isEmpty, value.utf8.count <= 20, value.utf8.allSatisfy({ (48...57).contains($0) }),
              value.contains(where: { $0 != "0" }) else { return nil }
        return value
    }
    static func number(_ raw: Any?) -> Double? {
        guard let raw=raw, !(raw is NSNull) else { return nil }
        if let number=raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        guard let value=Double(String(describing:raw)), value.isFinite, value >= 0, value <= 9_000_000_000_000_000 else { return nil }
        return value
    }
    static func integer(_ raw: Any?) -> Int? {
        guard let value=number(raw), value.rounded(.towardZero) == value, value <= Double(Int.max) else { return nil }
        return Int(value)
    }
    /// Display strings never echo an embedded passkey, Cookie, magnet or API URL.
    static func display(_ value: String, fallback: String = "") -> String {
        let value=value.trimmingCharacters(in:.whitespacesAndNewlines)
        let lower=value.lowercased()
        guard value.utf8.count <= 4096, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" }),
              !["http://", "https://", "magnet:", "passkey=", "authkey=", "cookie:", "api_key=", "token="].contains(where:lower.contains) else { return fallback }
        return value
    }
    private static func stableResource(_ torrent: [String: Any]) -> String? {
        // Signed enclosure links rotate; the station's stable detail identity does not.
        for key in ["page_url", "enclosure"] {
            guard let c=URLComponents(string:torrent.str(key)) else { continue }
            if c.scheme?.lowercased() == "magnet" {
                if let xt=c.queryItems?.first(where: { $0.name.lowercased() == "xt" })?.value,
                   xt.lowercased().hasPrefix("urn:btih:") {
                    let hash=String(xt.dropFirst(9)).lowercased()
                    if hash.count == 40 && hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) { return "btih:"+hash }
                }
                continue
            }
            guard ["http", "https"].contains(c.scheme?.lowercased() ?? ""), c.host != nil else { continue }
            for name in ["id", "tid", "torrent_id", "torrentid"] {
                if let raw=c.queryItems?.first(where:{ $0.name.lowercased() == name })?.value, let value=positiveID(raw) { return "detail:"+value }
            }
            let parts=c.path.split(separator:"/").map(String.init)
            if parts.count >= 2, ["details", "detail", "torrent", "torrents"].contains(parts[parts.count-2].lowercased()),
               let value=positiveID(parts.last) { return "detail:"+value }
        }
        return nil
    }
    static func item(_ row: [String: Any]) -> MPResourceItem? {
        guard let torrent=row["torrent_info"] as? [String:Any], let siteID=positiveID(torrent["site"]) else { return nil }
        let title=display(torrent.str("title")), name=display(torrent.str("site_name"),fallback:"已连接站点")
        guard !title.isEmpty else { return nil }
        let stable=stableResource(torrent)
        var payload: MPResourcePayload? = nil
        if let media=row["media_info"] as? [String:Any], let selected=MPDiscoveryParser.item(media),
           selected.hasSubscribableIdentity, stable != nil,
           let enclosure=URLComponents(string:torrent.str("enclosure")),
           ["http","https","magnet"].contains(enclosure.scheme?.lowercased() ?? "") {
            // These are the backend schema's download fields, not arbitrary search context.
            let mediaKeys:Set<String>=["media_source","media_id","type","title","year","season","tmdb_id","douban_id","imdb_id","tvdb_id","bangumi_id","library_category","category","seasons"]
            let torrentKeys:Set<String>=["site","site_name","site_cookie","site_ua","site_proxy","title","description","media_source","media_id","enclosure","page_url","size","seeders","peers","pubdate","labels","category"]
            payload=MPResourcePayload(media:media.filter{mediaKeys.contains($0.key)},torrent:torrent.filter{torrentKeys.contains($0.key)})
        }
        let identity=stable.map { "resource:"+digest(siteID+"\n"+$0) } ?? "display:"+digest(siteID+"\n"+title+"\n"+torrent.str("size"))
        return MPResourceItem(id:identity,title:title,subtitle:display(torrent.str("description")),siteID:siteID,siteName:name,
                              size:number(torrent["size"]),seeders:integer(torrent["seeders"]),peers:integer(torrent["peers"]),
                              downloadFactor:number(torrent["downloadvolumefactor"]),uploadFactor:number(torrent["uploadvolumefactor"]),
                              freeUntil:display(torrent.str("freedate")).isEmpty ? nil:display(torrent.str("freedate")),hasHR:torrent["hit_and_run"] as? Bool,payload:payload)
    }
    static func directory(_ row: [String:Any]) -> MPResourceDirectory? {
        let path=row.str("save_path"), storage=row.str("storage","local")
        guard !path.isEmpty, path.utf8.count <= 4096, !path.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains),
              !path.contains("@"), !path.contains("?"), !path.contains("#") else { return nil }
        let name=display(row.str("name"),fallback:"MoviePilot 预设目录")
        return MPResourceDirectory(id:digest(storage+"\n"+path),name:name.isEmpty ? "MoviePilot 预设目录":name,savePath:path,storage:storage)
    }
    static func downloader(_ row: [String:Any]) -> MPResourceDownloader? {
        let name=display(row.str("name")),type=row.str("type").lowercased()
        guard !name.isEmpty, name.utf8.count <= 256, ["qbittorrent","transmission"].contains(type) else { return nil }
        let config=row.dict("config"), host=config.str("host")
        var endpoint:String?=nil
        if !host.isEmpty, var c=URLComponents(string:host.contains("://") ? host:"http://"+host),
           ["http","https"].contains(c.scheme ?? ""), c.host != nil {
            c.user=nil;c.password=nil;c.query=nil;c.fragment=nil
            if let port=integer(config["port"]), (1...65535).contains(port) { c.port=port }
            endpoint=c.string
        }
        return MPResourceDownloader(id:name,name:name,type:type,targetBaseURL:endpoint,isDefault:row.bool("default"))
    }
}
