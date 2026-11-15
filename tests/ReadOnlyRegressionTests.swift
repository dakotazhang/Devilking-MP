import XCTest
import Foundation
@testable import DevilkingMP

private final class DiscoveryFixtureLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values = [String]()
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    var events: [String] { lock.lock(); defer { lock.unlock() }; return values }
}

final class ReadOnlyRegressionTests: XCTestCase {
    private func client() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHTTP.self]
        return APIClient(profile: ServiceProfile(kind: .moviepilot, baseURL: "http://192.168.1.100:3000", username: "fixture"),
                         credentials: Credential(username: "fixture", password: "", apiKey: "fixture-metadata-key"),
                         session: URLSession(configuration: config))
    }
    private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }
    private func envelope(_ value: Any) -> Data { json(["success": true, "message": "", "data": value]) }
    private func item(tv: Bool = false, source: String = "themoviedb", id: String = "12345") -> MPDiscoveryItem {
        MPDiscoveryItem(mediaSource: source, mediaID: id, title: "测试作品", year: "2025", mediaType: tv ? "电视剧" : "电影",
                        poster: nil, backdrop: nil, overview: "测试简介", rating: 8, genres: [], isAnime: false)
    }
    private func body(_ request: URLRequest) -> [String: Any] {
        if let data = request.httpBody { return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }
        guard let stream = request.httpBodyStream else { return [:] }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
    override func tearDown() { MockHTTP.handler = nil; super.tearDown() }

    @MainActor func testFreshInstallIsReadOnlyWithoutChangingServicePermissions() {
        let suite = "DevilkingMP.ReadOnlyTest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        XCTAssertTrue(model.readOnlyMode)
        XCTAssertTrue(model.migrationProtection)
        for kind in ServiceKind.allCases { XCTAssertFalse(model.canManage(kind)); XCTAssertFalse(model.profile(kind).allowActions) }
    }

    @MainActor func testGlobalReadOnlyAndMigrationProtectionAreIndependentGates() {
        let suite = "DevilkingMP.ReadOnlyTest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let kinds: [ServiceKind] = [.qb1, .qb2, .tr, .moviepilot]
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults, credentialReader: { _ in
            Credential(username: "fixture", password: "test-only", apiKey: "")
        })
        model.profiles = ServiceKind.allCases.map { ServiceProfile(kind: $0, baseURL: $0.defaultURL, username: "fixture", allowActions: true) }
        model.locked = false
        XCTAssertTrue(model.isConfigured(.qb2))
        for kind in kinds { XCTAssertFalse(model.canManage(kind), "Global read-only must override per-service permission") }
        model.readOnlyMode = false
        XCTAssertTrue(model.canManage(.qb2)); XCTAssertTrue(model.canManage(.moviepilot))
        XCTAssertFalse(model.canManage(.qb1)); XCTAssertFalse(model.canManage(.tr))
        model.migrationProtection = false
        XCTAssertTrue(model.canManage(.qb1)); XCTAssertTrue(model.canManage(.tr))
        model.locked = true
        for kind in kinds { XCTAssertFalse(model.canManage(kind)) }
    }

    func testReadOnlyCreationIsDeniedBeforeAnyNetworkRequestOrIntent() async {
        let log = DiscoveryFixtureLog()
        MockHTTP.handler = { _ in log.append("network"); throw URLError(.badURL) }
        do {
            _ = try await client().createSubscription(MPSubscriptionRequest(item: item(), season: nil), authorize: { false }, beforeSend: { log.append("intent") })
            XCTFail("Read-only must reject creation")
        } catch {}
        XCTAssertEqual(log.events, [])
    }

    func testSearchOnlyUsesMetadataGETAndKeepsSourceIdentity() async throws {
        let log = DiscoveryFixtureLog()
        MockHTTP.handler = { request in
            log.append(request.httpMethod ?? "")
            XCTAssertEqual(request.url?.path, "/api/v1/media/search")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "type" }?.value, "media")
            XCTAssertEqual(query.first { $0.name == "title" }?.value, "南京 + 电影")
            XCTAssertFalse(request.url!.absoluteString.contains("fixture-metadata-key"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-KEY"), "fixture-metadata-key")
            return (200, [:], self.envelope([["title": "测试作品", "media_source": "douban", "media_id": "54321", "type": "电影", "year": "2025"]]))
        }
        let results = try await client().searchDiscovery("南京 + 电影")
        XCTAssertEqual(results.first?.mediaSource, "douban"); XCTAssertEqual(results.first?.mediaID, "54321")
        XCTAssertEqual(log.events, ["GET"])
    }

    func testDetailCannotRelabelAResponseForAnotherWork() async {
        MockHTTP.handler = { _ in (200, [:], self.envelope(["title": "别的作品", "media_source": "themoviedb", "media_id": "99999", "type": "电影"])) }
        do { _ = try await client().mediaDetail(item()); XCTFail("Wrong identity must fail closed") } catch {}
    }

    func testTVDetailsReadRealSeasonsAndPreserveSpecialSeasonZero() async throws {
        let log = DiscoveryFixtureLog()
        MockHTTP.handler = { request in
            log.append(request.url!.path)
            XCTAssertEqual(request.httpMethod, "GET")
            if request.url!.path.hasSuffix("/seasons") {
                return (200, [:], self.envelope([["season_number": 0, "name": "特别篇", "episode_count": 2], ["season_number": 1, "name": "第一季", "episode_count": 12]]))
            }
            return (200, [:], self.envelope(["title": "测试作品", "media_source": "themoviedb", "media_id": "12345", "type": "电视剧"]))
        }
        let result = try await client().mediaDetail(item(tv: true))
        XCTAssertEqual(result.seasons.map(\.number), [0, 1]); XCTAssertEqual(result.seasons.first?.episodeCount, 2)
        XCTAssertEqual(log.events, ["/api/v1/media/12345", "/api/v1/media/seasons"])
    }

    func testEmptySubscriptionObjectIsNotAnExistingSubscription() async throws {
        MockHTTP.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, [:], self.envelope(["id": NSNull(), "name": NSNull(), "type": NSNull()]))
        }
        let existing = try await client().existingSubscription(MPSubscriptionRequest(item: item(), season: nil))
        XCTAssertNil(existing)
    }

    func testMissingSubscriptionIDIsUnknownRatherThanSafeToCreate() async {
        MockHTTP.handler = { _ in (200, [:], self.envelope(["name": "测试作品"])) }
        do { _ = try await client().existingSubscription(MPSubscriptionRequest(item: item(), season: nil)); XCTFail("Missing id is an unknown response") } catch {}
    }

    func testExistingSubscriptionDoesNotPostOrCreateIntent() async throws {
        let log = DiscoveryFixtureLog()
        MockHTTP.handler = { request in
            log.append(request.httpMethod ?? "")
            return (200, [:], self.envelope(["id": 77, "name": "测试作品", "type": "电影", "media_source": "themoviedb", "media_id": "12345", "state": "R"]))
        }
        let id = try await client().createSubscription(MPSubscriptionRequest(item: item(), season: nil), authorize: { true }, beforeSend: { log.append("intent") })
        XCTAssertEqual(id, "77"); XCTAssertEqual(log.events, ["GET"])
    }

    func testCreationPersistsIntentBeforeUniquePostAndOmitsDefaultRuleOverrides() async throws {
        let log = DiscoveryFixtureLog()
        MockHTTP.handler = { request in
            if request.httpMethod == "GET" { log.append("duplicate-get"); return (200, [:], self.envelope(["id": NSNull()])) }
            log.append("POST")
            XCTAssertEqual(request.url?.absoluteString, "http://192.168.1.100:3000/api/v1/subscribe/")
            let payload = self.body(request)
            XCTAssertEqual(payload["media_source"] as? String, "themoviedb")
            XCTAssertEqual(payload["media_id"] as? String, "12345")
            XCTAssertEqual(payload["type"] as? String, "电视剧")
            XCTAssertEqual(payload["season"] as? Int, 0)
            XCTAssertEqual(Set(payload.keys), Set(["name", "year", "type", "media_source", "media_id", "season"]))
            return (200, [:], self.envelope(["id": 78]))
        }
        let id = try await client().createSubscription(MPSubscriptionRequest(item: item(tv: true, source: "tmdb"), season: 0), authorize: { true }, beforeSend: { log.append("intent") })
        XCTAssertEqual(id, "78"); XCTAssertEqual(log.events, ["duplicate-get", "intent", "POST"])
    }

    func testIntentPersistenceFailurePreventsPost() async {
        let log = DiscoveryFixtureLog()
        MockHTTP.handler = { request in log.append(request.httpMethod ?? ""); return (200, [:], self.envelope(["id": NSNull()])) }
        do {
            _ = try await client().createSubscription(MPSubscriptionRequest(item: item(), season: nil), authorize: { true }, beforeSend: { throw AppError.message("fixture intent write failed") })
            XCTFail("Intent failure must prevent POST")
        } catch {}
        XCTAssertEqual(log.events, ["GET"])
    }

    func testPermissionRevokedAfterDuplicateReadPreventsIntentAndPost() async {
        let log = DiscoveryFixtureLog()
        MockHTTP.handler = { request in log.append(request.httpMethod ?? ""); return (200, [:], self.envelope(["id": NSNull()])) }
        do {
            _ = try await client().createSubscription(MPSubscriptionRequest(item: item(), season: nil), authorize: { !log.events.contains("GET") }, beforeSend: { log.append("intent") })
            XCTFail("Permission changed during read")
        } catch {}
        XCTAssertEqual(log.events, ["GET"])
    }

    func testPermissionRevokedByIntentCheckpointPreventsPost() async {
        let log = DiscoveryFixtureLog()
        MockHTTP.handler = { request in log.append(request.httpMethod ?? ""); return (200, [:], self.envelope(["id": NSNull()])) }
        do {
            _ = try await client().createSubscription(MPSubscriptionRequest(item: item(), season: nil), authorize: { !log.events.contains("intent") }, beforeSend: { log.append("intent") })
            XCTFail("Permission must be rechecked at the final send boundary")
        } catch {}
        XCTAssertEqual(log.events, ["GET", "intent"])
    }

    func testCreationNetworkTimeoutNeverRetriesBusinessPost() async {
        let log = DiscoveryFixtureLog()
        MockHTTP.handler = { request in
            log.append(request.httpMethod ?? "")
            if request.httpMethod == "GET" { return (200, [:], self.envelope(["id": NSNull()])) }
            throw URLError(.timedOut)
        }
        do {
            _ = try await client().createSubscription(MPSubscriptionRequest(item: item(), season: nil), authorize: { true }, beforeSend: {})
            XCTFail("Unknown write must not be reported as success")
        } catch {}
        XCTAssertEqual(log.events, ["GET", "POST"])
    }

    func testBusinessFalseIsNotSuccessAndDoesNotRetry() async {
        let log = DiscoveryFixtureLog()
        MockHTTP.handler = { request in
            log.append(request.httpMethod ?? "")
            return request.httpMethod == "GET" ? (200, [:], self.envelope(["id": NSNull()])) : (200, [:], self.json(["success": false, "data": NSNull()]))
        }
        do { _ = try await client().createSubscription(MPSubscriptionRequest(item: item(), season: nil), authorize: { true }, beforeSend: {}); XCTFail("Business false is not success") } catch {}
        XCTAssertEqual(log.events, ["GET", "POST"])
    }

    func testBooleanIDIsNotAcceptedAsCreatedSubscription() async {
        let log = DiscoveryFixtureLog()
        MockHTTP.handler = { request in
            log.append(request.httpMethod ?? "")
            return request.httpMethod == "GET" ? (200, [:], self.envelope(["id": NSNull()])) : (200, [:], self.envelope(["id": true]))
        }
        do { _ = try await client().createSubscription(MPSubscriptionRequest(item: item(), season: nil), authorize: { true }, beforeSend: {}); XCTFail("Boolean is not an id") } catch {}
        XCTAssertEqual(log.events, ["GET", "POST"])
    }

    func testMoviePayloadCannotAccidentallyContainTVSeason() async {
        let log = DiscoveryFixtureLog()
        MockHTTP.handler = { _ in log.append("network"); throw URLError(.badURL) }
        do { _ = try await client().createSubscription(MPSubscriptionRequest(item: item(), season: 1), authorize: { true }, beforeSend: {}); XCTFail("Invalid movie season must be blocked") } catch {}
        XCTAssertEqual(log.events, [])
    }

    func testTVWithoutSelectedSeasonIsBlockedWithoutNetwork() async {
        let log = DiscoveryFixtureLog()
        MockHTTP.handler = { _ in log.append("network"); throw URLError(.badURL) }
        do { _ = try await client().createSubscription(MPSubscriptionRequest(item: item(tv: true), season: nil), authorize: { true }, beforeSend: {}); XCTFail("TV needs an explicit season") } catch {}
        XCTAssertEqual(log.events, [])
    }

    func testRecommendationFailuresRemainVisibleAndDoNotEraseOtherSources() async throws {
        MockHTTP.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            if request.url!.path.hasSuffix("/douban_tvs") { return (503, [:], Data()) }
            return (200, [:], self.envelope([["title": "测试作品", "media_source": "douban", "media_id": "54321", "type": "电视剧"]]))
        }
        let sections = try await client().discoverySections()
        XCTAssertEqual(sections.count, 4)
        XCTAssertNotNil(sections.first { $0.id == "douban_tvs" }?.error)
        XCTAssertEqual(sections.filter { $0.error == nil }.count, 3)
        XCTAssertTrue(sections.first { $0.id == "douban_tv_animation" }!.items.allSatisfy(\.isAnime))
    }
}
