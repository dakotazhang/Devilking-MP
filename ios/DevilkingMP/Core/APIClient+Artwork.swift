import Foundation

/// Artwork references are not browser navigation targets. Every accepted public
/// image is fetched through the configured MP's authenticated, controlled proxy.
enum MPArtworkPolicy {
    static let maximumBytes=8*1024*1024
    static func publicImage(_ value:String)->String? {
        guard value.utf8.count <= 8192,let parts=URLComponents(string:value),parts.scheme?.lowercased() == "https",
              let host=parts.host,!host.isEmpty,!EndpointPolicy.isLAN(host),host.lowercased() != "localhost",
              parts.user == nil,parts.password == nil,parts.fragment == nil,
              !parts.path.isEmpty else { return nil }
        guard [".jpg",".jpeg",".png",".webp",".gif",".avif",".heic",".heif"].contains(where:parts.path.lowercased().hasSuffix) else { return nil }
        let transforms:Set<String>=["width","height","w","h","q","quality","format","fit","size"]
        guard (parts.queryItems ?? []).allSatisfy({ item in
            transforms.contains(item.name.lowercased()) && (item.value?.utf8.count ?? 0) <= 64 &&
            (item.value?.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [44,45,95].contains($0) }) ?? false)
        }) else { return nil }
        return parts.url?.absoluteString
    }
    static func reference(_ raw:String)->String? {
        guard !raw.isEmpty,raw.utf8.count <= 16384,!raw.contains("\n"),!raw.contains("\r") else { return nil }
        // MP browser image references may contain a resource token outside the
        // nested URL. Drop it; the app authenticates with its own current header.
        if let parts=URLComponents(string:raw) {
            let path=parts.path.hasPrefix("/") ? parts.path:"/"+parts.path
            let key:String?
            if path == "/api/v1/system/cache/image" { key="url" }
            else if ["/api/v1/system/img/0","/api/v1/system/img/1"].contains(path) { key="imgurl" }
            else { key=nil }
            if let key=key {
                guard parts.user == nil,parts.password == nil,
                      let target=parts.queryItems?.first(where:{$0.name == key})?.value else { return nil }
                return publicImage(target)
            }
        }
        if raw.hasPrefix("/") && !raw.hasPrefix("//") {
            guard !raw.hasPrefix("/api/"),!raw.contains(".."),!raw.contains("?"),!raw.contains("#") else { return nil }
            return publicImage("https://image.tmdb.org/t/p/w500"+raw)
        }
        return publicImage(raw)
    }
    static func validateImage(_ data:Data,mime:String?) throws -> Data {
        let type=(mime ?? "").lowercased().split(separator:";").first.map(String.init) ?? ""
        guard acceptsMIME(type),
              !data.isEmpty,data.count <= maximumBytes else { throw AppError.message("MoviePilot 未返回有效海报图片，可点击重试。") }
        let bytes=[UInt8](data.prefix(16))
        let jpeg=bytes.starts(with:[0xff,0xd8,0xff])
        let png=bytes.starts(with:[0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a])
        let gif=bytes.starts(with:Array("GIF87a".utf8)) || bytes.starts(with:Array("GIF89a".utf8))
        let webp=bytes.count >= 12 && Array(bytes[0..<4]) == Array("RIFF".utf8) && Array(bytes[8..<12]) == Array("WEBP".utf8)
        let isobmff=bytes.count >= 12 && Array(bytes[4..<8]) == Array("ftyp".utf8) && ["avif","avis","heic","heix","hevc","mif1"].contains(String(bytes:bytes[8..<12],encoding:.ascii) ?? "")
        guard jpeg || png || gif || webp || isobmff else { throw AppError.message("海报响应不是图片内容，可点击重试。") }
        return data
    }
    static func acceptsMIME(_ type:String?)->Bool {
        let value=(type ?? "").lowercased().split(separator:";").first.map(String.init) ?? ""
        return ["image/jpeg","image/jpg","image/png","image/webp","image/gif","image/avif","image/heic","image/heif"].contains(value)
    }
}

extension APIClient {
    func moviePilotArtwork(_ reference:String) async throws -> Data {
        guard profile.kind == .moviepilot,let target=MPArtworkPolicy.reference(reference) else { throw AppError.message("海报地址无效或不属于受支持的图片引用。") }
        // No external URLSession request, Cookie or Authorization forwarding.
        return try await authenticatedMoviePilotImage("/api/v1/system/cache/image",query:["url":target])
    }
}
