import XCTest
import Foundation
@testable import DevilkingMP

private final class MultiServerHTTP: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (status, headers, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

/// All traffic is intercepted locally. No household or seedbox endpoint is used.
final class MultiServerAPIRegressionTests: XCTestCase {
    private let fixtureHash = String(repeating: "a", count: 40)
    override func tearDown() { MultiServerHTTP.handler = nil; super.tearDown() }
    private func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
    private func client(_ id: ServiceID, host: String, prefix: String = "", apiKey: String = "") -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MultiServerHTTP.self]
        return APIClient(profile: ServiceProfile(kind: id, baseURL: "https://" + host + prefix, username: host),
                         credentials: Credential(username: host, password: "fixture-password-" + host, apiKey: apiKey),
                         session: URLSession(configuration: configuration))
    }
    private func bodyData(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
    private func body(_ request: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: bodyData(request))) as? [String: Any] ?? [:]
    }
    private func trReply(_ arguments: [String: Any]) -> Data { json(["result": "success", "arguments": arguments]) }
    private func trRow() -> [String: Any] {
        ["hashString": fixtureHash, "name": "Shared fixture", "status": 6, "error": 0,
         "percentDone": 1.0, "leftUntilDone": 0, "totalSize": 1024]
    }
    private func qbPayload() -> [String: Any] {
        ["full_update": true,
         "torrents": [fixtureHash: ["name": "Shared fixture", "state": "stalledUP", "progress": 1.0,
                              "has_tracker_error": false, "has_other_announce_error": false]],
         "server_state": ["dl_info_speed": 0, "up_info_speed": 7, "free_space_on_disk": 8192]]
    }

    func testTwoDynamicQBInstancesKeepSameHashIdentityAndBearerSeparate() async throws {
        let leftID = ServiceID.make(.qbittorrent), rightID = ServiceID.make(.qbittorrent)
        let left = client(leftID, host: "left.example", prefix: "/a", apiKey: "fixture-left-key")
        let right = client(rightID, host: "right.example", prefix: "/b", apiKey: "fixture-right-key")
        var seen = [String]()
        MultiServerHTTP.handler = { request in
            let host = request.url!.host!, isLeft = host == "left.example"
            let prefix = isLeft ? "/a" : "/b"
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), isLeft ? "Bearer fixture-left-key" : "Bearer fixture-right-key")
            XCTAssertEqual(request.httpMethod, "GET")
            seen.append(host + request.url!.path)
            if request.url!.path == prefix + "/api/v2/app/version" { return (200, [:], Data("v5.2.4".utf8)) }
            XCTAssertEqual(request.url!.path, prefix + "/api/v2/sync/maindata")
            return (200, [:], self.json(self.qbPayload()))
        }
        let leftRows = try await left.tasks(), rightRows = try await right.tasks()
        let leftTask = try XCTUnwrap(leftRows.first), rightTask = try XCTUnwrap(rightRows.first)
        XCTAssertEqual(leftTask.id, rightTask.id)
        XCTAssertEqual(leftTask.kind, leftID); XCTAssertEqual(rightTask.kind, rightID)
        XCTAssertNotEqual(leftTask.qualifiedID, rightTask.qualifiedID)
        let leftDashboard = try await left.dashboard(), rightDashboard = try await right.dashboard()
        XCTAssertEqual(leftDashboard.kind, leftID); XCTAssertEqual(rightDashboard.kind, rightID)
        XCTAssertEqual(leftDashboard.counts?.seeding, 1); XCTAssertEqual(rightDashboard.counts?.seeding, 1)
        XCTAssertEqual(seen.count, 6)
        XCTAssertFalse(seen.contains { $0.contains("auth/login") })
    }

    func testTwoDynamicTRInstancesKeepRPCSessionAuthAndSameHashIdentitySeparate() async throws {
        let leftID = ServiceID.make(.transmission), rightID = ServiceID.make(.transmission)
        let left = client(leftID, host: "left.example", prefix: "/north/transmission/web")
        let right = client(rightID, host: "right.example", prefix: "/south/transmission/web")
        var challenged = Set<String>()
        MultiServerHTTP.handler = { request in
            let host = request.url!.host!, isLeft = host == "left.example"
            XCTAssertEqual(request.url!.path, (isLeft ? "/north" : "/south") + "/transmission/rpc")
            XCTAssertEqual(request.httpMethod, "POST")
            let expectedBasic = Data((host + ":fixture-password-" + host).utf8).base64EncodedString()
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic " + expectedBasic)
            if challenged.insert(host).inserted {
                XCTAssertNil(request.value(forHTTPHeaderField: "X-Transmission-Session-Id"))
                return (409, ["X-Transmission-Session-Id": "session-" + host], Data())
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Transmission-Session-Id"), "session-" + host)
            switch self.body(request)["method"] as? String {
            case "torrent-get": return (200, [:], self.trReply(["torrents": [self.trRow()]]))
            case "session-stats": return (200, [:], self.trReply(["torrentCount": 1, "activeTorrentCount": 0, "downloadSpeed": 0, "uploadSpeed": isLeft ? 10 : 20]))
            case "session-get": return (200, [:], self.trReply(["download-dir": "/seed"]))
            case "free-space": return (200, [:], self.trReply(["path": "/seed", "size-bytes": 4096]))
            default: XCTFail("Unexpected RPC"); throw URLError(.badServerResponse)
            }
        }
        let leftRows = try await left.tasks(), rightRows = try await right.tasks()
        let leftTask = try XCTUnwrap(leftRows.first), rightTask = try XCTUnwrap(rightRows.first)
        XCTAssertEqual(leftTask.id, rightTask.id)
        XCTAssertEqual(leftTask.kind, leftID); XCTAssertEqual(rightTask.kind, rightID)
        XCTAssertNotEqual(leftTask.qualifiedID, rightTask.qualifiedID)
        let leftSnapshot = try await left.snapshot(), rightSnapshot = try await right.snapshot()
        XCTAssertEqual(leftSnapshot.kind, leftID); XCTAssertEqual(rightSnapshot.kind, rightID)
        XCTAssertEqual(leftSnapshot.uploadRate, 10); XCTAssertEqual(rightSnapshot.uploadRate, 20)
        let leftDashboard = try await left.dashboard(), rightDashboard = try await right.dashboard()
        XCTAssertEqual(leftDashboard.kind, leftID); XCTAssertEqual(rightDashboard.kind, rightID)
        XCTAssertEqual(leftDashboard.disk?.freeBytes, 4096); XCTAssertEqual(rightDashboard.disk?.freeBytes, 4096)
        XCTAssertEqual(challenged.count, 2)
    }

    func testDynamicQBActionAndLimitRouteToSelectedInstanceAndVersion() async throws {
        let left = client(.make(.qbittorrent), host: "left.example", prefix: "/a", apiKey: "fixture-left-key")
        let right = client(.make(.qbittorrent), host: "right.example", prefix: "/b", apiKey: "fixture-right-key")
        var actions = [String](), limits = [String: Int]()
        MultiServerHTTP.handler = { request in
            let host = request.url!.host!, isLeft = host == "left.example"
            let prefix = isLeft ? "/a" : "/b", path = request.url!.path
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), isLeft ? "Bearer fixture-left-key" : "Bearer fixture-right-key")
            if path == prefix + "/api/v2/app/version" { return (200, [:], Data((isLeft ? "v4.6.7" : "v5.2.4").utf8)) }
            if request.httpMethod == "POST" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://" + host)
                let wire = String(data: self.bodyData(request), encoding: .utf8) ?? ""
                if path.hasSuffix("/setUploadLimit") {
                    XCTAssertEqual(wire, isLeft ? "limit=5000000" : "limit=7500000")
                    limits[host] = isLeft ? 5_000_000 : 7_500_000
                } else {
                    XCTAssertEqual(wire, "hashes=" + self.fixtureHash)
                    actions.append(host + path)
                }
                return (200, [:], Data())
            }
            XCTAssertEqual(path, prefix + "/api/v2/transfer/info")
            return (200, [:], self.json(["up_rate_limit": limits[host] ?? -1]))
        }
        try await left.taskAction(id: fixtureHash, start: true)
        try await right.taskAction(id: fixtureHash, start: false)
        try await left.uploadLimit(mbps: 40)
        try await right.uploadLimit(mbps: 60)
        XCTAssertEqual(actions, ["left.example/a/api/v2/torrents/resume", "right.example/b/api/v2/torrents/stop"])
        XCTAssertEqual(limits.count, 2)
    }

    func testDynamicTRActionAndLimitUseOnlySelectedRPCAndCorrectUnits() async throws {
        let left = client(.make(.transmission), host: "left.example")
        let right = client(.make(.transmission), host: "right.example")
        var actions = [String](), limits = [String: Int]()
        MultiServerHTTP.handler = { request in
            let host = request.url!.host!
            XCTAssertEqual(request.url!.path, "/transmission/rpc")
            let expectedBasic = Data((host + ":fixture-password-" + host).utf8).base64EncodedString()
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic " + expectedBasic)
            let payload = self.body(request), arguments = payload["arguments"] as? [String: Any] ?? [:]
            switch payload["method"] as? String {
            case "torrent-start", "torrent-stop":
                XCTAssertEqual(arguments["ids"] as? [String], [self.fixtureHash])
                actions.append(host + ":" + (payload["method"] as! String))
                return (200, [:], self.trReply([:]))
            case "session-set":
                XCTAssertEqual(arguments["speed-limit-up-enabled"] as? Bool, true)
                let expected = host == "left.example" ? 5000 : 10000
                XCTAssertEqual(arguments["speed-limit-up"] as? Int, expected)
                limits[host] = expected
                return (200, [:], self.trReply([:]))
            case "session-get": return (200, [:], self.trReply(["speed-limit-up-enabled": true, "speed-limit-up": limits[host] ?? -1]))
            default: XCTFail("Unexpected RPC"); throw URLError(.badServerResponse)
            }
        }
        try await left.taskAction(id: fixtureHash, start: true)
        try await right.taskAction(id: fixtureHash, start: false)
        try await left.uploadLimit(mbps: 40)
        try await right.uploadLimit(mbps: 80)
        XCTAssertEqual(actions, ["left.example:torrent-start", "right.example:torrent-stop"])
        XCTAssertEqual(limits, ["left.example": 5000, "right.example": 10000])
    }

    func testDynamicTRDeniedActionsMakeNoRPCRequest() async {
        var requests = 0
        MultiServerHTTP.handler = { _ in requests += 1; throw URLError(.badURL) }
        let api = client(.make(.transmission), host: "left.example")
        do { try await api.taskAction(id: fixtureHash, start: true, authorize: { false }); XCTFail("must reject") } catch {}
        do { try await api.uploadLimit(mbps: 40, authorize: { false }); XCTFail("must reject") } catch {}
        XCTAssertEqual(requests, 0)
    }

    func testNonDownloaderCannotFallThroughToQBOrTransmissionRoutes() async {
        var requests = 0
        MultiServerHTTP.handler = { _ in requests += 1; throw URLError(.badURL) }
        let emby = client(.emby, host: "emby.example")
        do { _ = try await emby.tasks(); XCTFail("must reject") } catch {}
        do { try await emby.taskAction(id: fixtureHash, start: true); XCTFail("must reject") } catch {}
        do { try await emby.uploadLimit(mbps: 40); XCTFail("must reject") } catch {}
        do { _ = try await client(.make(.qbittorrent), host: "qb.example").rpc("torrent-stop"); XCTFail("must reject") } catch {}
        XCTAssertEqual(requests, 0)
    }

    func testDashboardParsersPreserveDynamicIDsAndRejectWrongProtocol() throws {
        let qb = ServiceID.make(.qbittorrent), tr = ServiceID.make(.transmission)
        let stats: [String: Any] = ["downloadSpeed": 0, "uploadSpeed": 0, "torrentCount": 1]
        XCTAssertEqual(try DashboardParser.qb(qbPayload(), kind: qb).kind, qb)
        XCTAssertEqual(try DashboardParser.tr(stats: stats, rows: [trRow()], kind: tr).kind, tr)
        XCTAssertEqual(try DashboardParser.tr(stats: stats, rows: [trRow()]).kind, .tr)
        XCTAssertThrowsError(try DashboardParser.qb(qbPayload(), kind: tr))
        XCTAssertThrowsError(try DashboardParser.tr(stats: stats, rows: [trRow()], kind: qb))
    }

    func testDynamicTRReverseProxyPrefixContainingTransmissionIsPreserved() async throws {
        // A prefix containing this word is not the actual terminal TR route.
        // No network request is performed by endpoint construction.
        let examples = [
            ("/transmission-proxy/north/transmission/web", "/transmission-proxy/north/transmission/rpc"),
            ("/seedboxes/transmission-archive", "/seedboxes/transmission-archive/transmission/rpc")
        ]
        for (prefix, expected) in examples {
            let api = client(.make(.transmission), host: "proxy.example", prefix: prefix)
            let endpoint = try await api.endpoint("/transmission/rpc")
            XCTAssertEqual(endpoint.path, expected)
        }
    }

    func testSameOriginRedirectAllowsDefaultPortNormalizationAndCaseDifferences() {
        let pairs = [
            ("https://BOX.example:443/api", "https://box.example/login"),
            ("https://box.example/api", "https://BOX.example:443/login"),
            ("http://HOME.local:80/api", "http://home.local/login"),
            ("HTTPS://box.example/api", "https://box.example/login")
        ]
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for (source, destination) in pairs {
            let task = session.dataTask(with: URL(string: source)!)
            let response = HTTPURLResponse(url: task.originalRequest!.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
            var decision: URLRequest?
            SameOriginDelegate().urlSession(session, task: task, willPerformHTTPRedirection: response,
                                           newRequest: URLRequest(url: URL(string: destination)!)) { decision = $0 }
            XCTAssertNotNil(decision, source + " -> " + destination)
            task.cancel()
        }
    }

    func testSameOriginRedirectRejectsDifferentHostSchemeOrNonDefaultPort() {
        let pairs = [
            ("https://box.example/api", "https://other.example/login"),
            ("https://box.example/api", "http://box.example/login"),
            ("http://box.example/api", "https://box.example/login"),
            ("https://box.example/api", "https://box.example:8443/login"),
            ("https://box.example:8443/api", "https://box.example/login"),
            ("https://box.example/api", "https://user:password@box.example/login")
        ]
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for (source, destination) in pairs {
            let task = session.dataTask(with: URL(string: source)!)
            let response = HTTPURLResponse(url: task.originalRequest!.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
            var decision: URLRequest?
            SameOriginDelegate().urlSession(session, task: task, willPerformHTTPRedirection: response,
                                           newRequest: URLRequest(url: URL(string: destination)!)) { decision = $0 }
            XCTAssertNil(decision, source + " -> " + destination)
            task.cancel()
        }
    }
}
