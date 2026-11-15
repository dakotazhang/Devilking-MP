import Foundation

struct ResourceDownloadRecord: Codable, Equatable {
    var createdAt: Date
    var confirmedDownloadID: String?
}

/// Only hashed intent identity and the eventual downloader task ID persist.
/// Restricted enclosure/page URLs, Cookies and raw search responses never do.
struct ResourceDownloadLedger {
    private let defaults: UserDefaults
    private let storageKey="resourceDownloadIntents.v1"
    init(defaults:UserDefaults) { self.defaults=defaults }
    func key(profile:ServiceProfile,request:MPResourceDownloadRequest,target:ServiceProfile) -> String {
        let resource=[profile.baseURL.trimmingCharacters(in:CharacterSet(charactersIn:"/")),profile.username,request.item.id].joined(separator:"\n")
        let destination=[request.downloader.bindingID,
                   target.kind.rawValue,target.baseURL.trimmingCharacters(in:CharacterSet(charactersIn:"/")),target.username,
                   request.directory?.id ?? "moviepilot-default"].joined(separator:"\n")
        return MPResourceParser.digest(resource)+"."+MPResourceParser.digest(destination)
    }
    private func read() throws -> [String:ResourceDownloadRecord] {
        guard defaults.object(forKey:storageKey) != nil else { return [:] }
        guard let data=defaults.data(forKey:storageKey),let rows=try? JSONDecoder().decode([String:ResourceDownloadRecord].self,from:data) else {
            throw AppError.message("下载提交记录无法读取，请先在原 MoviePilot 核对，禁止重复提交。")
        }
        return rows
    }
    private func resourcePrefix(_ key:String) throws -> String {
        let parts=key.split(separator:".")
        guard parts.count == 2,parts.allSatisfy({ $0.count == 64 && $0.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) }) else {
            throw AppError.message("下载意图身份无效，禁止提交。")
        }
        return String(parts[0])+"."
    }
    func record(_ key:String) throws -> ResourceDownloadRecord? {
        let rows=try read(),prefix=try resourcePrefix(key)
        return rows[key] ?? rows.first(where: { $0.key.hasPrefix(prefix) })?.value
    }
    func prepare(_ key:String) throws {
        var rows=try read()
        let prefix=try resourcePrefix(key)
        guard !rows.keys.contains(where: { $0.hasPrefix(prefix) }) else { throw AppError.message("该资源已有下载提交记录；更换目录或下载器也不能重复提交，请先只读核对原管理页。") }
        rows[key]=ResourceDownloadRecord(createdAt:Date(),confirmedDownloadID:nil)
        try write(rows)
    }
    func confirm(_ key:String,id:String) throws {
        var rows=try read()
        guard let existing=rows[key],existing.confirmedDownloadID == nil,!id.isEmpty else { throw AppError.message("下载意图不存在或已确认，请先核对原管理页。") }
        rows[key]=ResourceDownloadRecord(createdAt:existing.createdAt,confirmedDownloadID:id)
        try write(rows)
    }
    private func write(_ rows:[String:ResourceDownloadRecord]) throws {
        let data=try JSONEncoder().encode(rows);defaults.set(data,forKey:storageKey)
        guard defaults.synchronize(),defaults.data(forKey:storageKey) == data else { throw AppError.message("无法持久保存下载意图，本次未继续发送。") }
    }
}
