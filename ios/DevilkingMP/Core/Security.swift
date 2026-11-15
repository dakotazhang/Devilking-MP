import Foundation
import Security

enum EndpointPolicy {
    static func validTaskID(_ value:String,kind:ServiceKind)->Bool {
        let lengths = kind.protocolKind == .transmission ? [40]:[40,64]
        return lengths.contains(value.count) && value.unicodeScalars.allSatisfy{("0123456789abcdefABCDEF").unicodeScalars.contains($0)}
    }
    static func validate(_ raw: String) throws -> URL {
        guard let c=URLComponents(string:raw.trimmingCharacters(in:.whitespacesAndNewlines)), let scheme=c.scheme?.lowercased(), ["https","http"].contains(scheme), let host=c.host?.lowercased(), !host.isEmpty, c.user == nil, c.password == nil, c.query == nil, c.fragment == nil, let url=c.url else { throw AppError.message("地址需为 HTTP/HTTPS 服务根地址，不能包含密码、查询参数或片段。") }
        if scheme == "http" && !isLAN(host) { throw AppError.message("外部地址必须使用 HTTPS；内网地址请先连接家庭 Wi‑Fi 或 WireGuard。") }
        return url
    }
    static func isLAN(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" || host.hasSuffix(".local") { return true }
        let pieces=host.split(separator:".",omittingEmptySubsequences:false)
        guard pieces.count == 4, pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy({"0123456789".contains($0)}) && ($0.count == 1 || !$0.hasPrefix("0")) }) else{return false}
        let p=pieces.compactMap{Int($0)}
        guard p.count == 4, p.allSatisfy({0...255 ~= $0}) else { return false }
        return p[0] == 10 || p[0] == 127 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && (16...31).contains(p[1]))
    }
}
final class SameOriginDelegate: NSObject, URLSessionTaskDelegate {
    private func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return scheme + "://" + host + ":" + String(port)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward credentials or read results across origins, even to another LAN host.
        guard let a=task.originalRequest?.url, let b=request.url,
              let source=origin(a), let destination=origin(b), source == destination else { completionHandler(nil); return }
        completionHandler(request)
    }
}
enum KeychainStore {
    static let service="top.devilkkkkk1.DevilkingMP.credentials"
    static func read(_ kind: ServiceKind) -> Credential {
        let q:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:kind.rawValue,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var found:CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary,&found) == errSecSuccess, let data=found as? Data, let value=try? JSONDecoder().decode(Credential.self,from:data) else { return Credential() }
        return value
    }
    static func write(_ value: Credential, kind: ServiceKind) throws {
        let data=try JSONEncoder().encode(value)
        let q:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:kind.rawValue]
        let attrs:[String:Any]=[kSecValueData as String:data,kSecAttrAccessible as String:kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let result=SecItemUpdate(q as CFDictionary,attrs as CFDictionary)
        if result == errSecItemNotFound { var add=q;attrs.forEach{add[$0.key]=$0.value}; guard SecItemAdd(add as CFDictionary,nil) == errSecSuccess else { throw AppError.message("无法保存到手机钥匙串。") } }
        else if result != errSecSuccess { throw AppError.message("无法更新手机钥匙串。") }
    }
    static func deleteVerified(_ kind: ServiceID) throws {
        let result = SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: kind.rawValue] as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw AppError.message("无法清除手机钥匙串中的登录资料，原连接配置已保留。") }
    }
    /// Legacy source compatibility; destructive UI paths use the verified result.
    static func delete(_ kind: ServiceKind) { try? deleteVerified(kind) }
}
