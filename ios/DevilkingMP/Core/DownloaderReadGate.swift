import Foundation

/// Bounded reads across independently configured downloader sessions.
actor DownloaderReadGate {
    private let limit:Int
    private var active=0
    private var waiters:[(UUID,CheckedContinuation<Void,Error>)]=[]
    init(limit:Int=4){self.limit=max(1,limit)}
    func read<T:Sendable>(_ operation:@escaping @Sendable () async throws -> T) async throws -> T {
        try await acquire();defer{release()};try Task.checkCancellation();return try await operation()
    }
    private func acquire() async throws {
        try Task.checkCancellation()
        if active < limit{active += 1;return}
        let id=UUID()
        try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation{(c:CheckedContinuation<Void,Error>) in waiters.append((id,c))}
        },onCancel:{Task{await self.cancel(id)}})
    }
    private func cancel(_ id:UUID){if let i=waiters.firstIndex(where:{$0.0 == id}){waiters.remove(at:i).1.resume(throwing:CancellationError())}}
    private func release(){if waiters.isEmpty{active -= 1}else{waiters.removeFirst().1.resume()}}
}

/// Canonical service root used only for endpoint equality, never server identity.
enum ConnectionEndpointIdentity {
    static func key(_ raw:String,kind:ServiceID)->String {
        guard var c=URLComponents(string:raw) else{return raw}
        c.scheme=c.scheme?.lowercased();c.host=c.host?.lowercased()
        if c.port == (c.scheme == "https" ? 443:80){c.port=nil}
        var path=c.path.trimmingCharacters(in:CharacterSet(charactersIn:"/"))
        if kind.isTR,let range=path.range(of:"transmission",options:.backwards),
           range.lowerBound == path.startIndex || path[path.index(before:range.lowerBound)] == "/" {
            let tail=String(path[range.lowerBound...])
            if ["transmission","transmission/rpc","transmission/web"].contains(tail){path=String(path[..<range.lowerBound]).trimmingCharacters(in:CharacterSet(charactersIn:"/"))}
        }
        c.path=path.isEmpty ? "":"/"+path;c.query=nil;c.fragment=nil
        return c.string ?? raw
    }
}
