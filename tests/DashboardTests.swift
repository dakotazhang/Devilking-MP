import XCTest
@testable import DevilkingMP

final class DashboardHTTP: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class DashboardTests: XCTestCase {
    private let moment = Date(timeIntervalSince1970: 1_800_000_000)
    private let testHash = String(repeating: "a", count: 40)
    override func tearDown() { DashboardHTTP.handler = nil; super.tearDown() }
    private func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
    private func client(_ kind: ServiceKind) -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DashboardHTTP.self]
        return APIClient(profile: ServiceProfile(kind: kind, baseURL: kind.defaultURL, username: "fixture"),
                         credentials: Credential(username: "fixture", password: "fixture-only", apiKey: kind == .tr ? "" : "fixture-key"),
                         session: URLSession(configuration: configuration))
    }
    private func qbPayload() -> [String: Any] {
        ["full_update": true, "torrents": [testHash: ["state": "stalledUP", "has_tracker_error": false, "has_other_announce_error": false]],
         "server_state": ["dl_info_speed": 0, "up_info_speed": 750_000, "alltime_dl": 1000, "alltime_ul": 2000,
                          "free_space_on_disk": 9_000_000_000, "connection_status": "connected"]]
    }
    func testKnownZeroIsDifferentFromMissingAndInvalidCounters() {
        XCTAssertEqual(DashboardParser.number(0), 0)
        let invalid: [Any] = [true, false, "100", -1, Double.nan, Double.infinity, 1e99, NSNull()]
        for value in invalid {
            XCTAssertNil(DashboardParser.number(value))
        }
        XCTAssertNil(DashboardParser.number(nil))
    }
    func testQBStalledSeedingAndStoppedAreSeparate() throws {
        let counts = try DashboardParser.qbCounts([["state": "stalledUP"], ["state": "uploading"], ["state": "stoppedUP"], ["state": "pausedDL"]])
        XCTAssertEqual(counts.total, 4); XCTAssertEqual(counts.seeding, 2); XCTAssertEqual(counts.stopped, 2)
        XCTAssertEqual(counts.downloading, 0)
    }
    func testQBCheckingQueueAndUnknownNeverBecomeSeeding() throws {
        let counts = try DashboardParser.qbCounts([["state": "checkingUP"], ["state": "queuedUP"], ["state": "moving"], ["state": "future-state"]])
        XCTAssertEqual(counts.verifying, 1); XCTAssertEqual(counts.queued, 1); XCTAssertEqual(counts.unknown, 2)
        XCTAssertEqual(counts.seeding, 0)
    }
    func testQBBothLocalAndTrackerErrorsCountWithoutPrivateMessages() throws {
        let counts = try DashboardParser.qbCounts([["state": "missingFiles"], ["state": "stalledUP", "has_tracker_error": true],
                                                  ["state": "downloading", "has_other_announce_error": true]])
        XCTAssertEqual(counts.errors, 3); XCTAssertEqual(counts.seeding, 1); XCTAssertEqual(counts.downloading, 1)
    }
    func testQBMissingStateRejectsWholeTaskCount() {
        XCTAssertThrowsError(try DashboardParser.qbCounts([[:]]))
    }
    func testQBFullSnapshotPreservesActualZeroAndDisk() throws {
        let result = try DashboardParser.qb(qbPayload(), kind: .qb1, now: moment)
        XCTAssertEqual(result.downloadRate, 0); XCTAssertEqual(result.uploadRate, 750_000)
        XCTAssertEqual(result.disk?.freeBytes, 9_000_000_000); XCTAssertEqual(result.counts?.seeding, 1)
        XCTAssertEqual(result.cumulativeDownloaded, 1000); XCTAssertTrue(result.warnings.isEmpty)
    }
    func testQBEmptyFullMapIsKnownEmpty() throws {
        var value = qbPayload(); value["torrents"] = [String: [String: Any]]()
        XCTAssertEqual(try DashboardParser.qb(value, kind: .qb2).counts?.total, 0)
    }
    func testQBDeltaCannotBeMisreadAsFullTaskSet() {
        var value = qbPayload(); value["full_update"] = false
        XCTAssertThrowsError(try DashboardParser.qb(value, kind: .qb1))
    }
    func testQBMissingMapCannotBecomeEmptyAndMissingRateCannotBecomeZero() {
        var value = qbPayload(); value["torrents"] = nil
        XCTAssertThrowsError(try DashboardParser.qb(value, kind: .qb1))
        value = qbPayload(); value["server_state"] = ["dl_info_speed": 0]
        XCTAssertThrowsError(try DashboardParser.qb(value, kind: .qb1))
    }
    func testQBUntrustedIdentityRejected() {
        var value = qbPayload(); value["torrents"] = ["all": ["state": "uploading"]]
        XCTAssertThrowsError(try DashboardParser.qb(value, kind: .qb1))
    }
    func testQBNegativeFreeSpaceStaysUnknown() throws {
        var value = qbPayload(); var state = value["server_state"] as! [String: Any]
        state["free_space_on_disk"] = -1; value["server_state"] = state
        let result = try DashboardParser.qb(value, kind: .qb1)
        XCTAssertNil(result.disk); XCTAssertFalse(result.warnings.isEmpty)
    }
    func testTRCategoriesDoNotTurnCheckingOrQueueIntoSeeding() throws {
        let counts = try DashboardParser.trCounts((0...6).map { ["status": $0, "error": 0] })
        XCTAssertEqual(counts.total, 7); XCTAssertEqual(counts.verifying, 2); XCTAssertEqual(counts.queued, 2)
        XCTAssertEqual(counts.stopped, 1); XCTAssertEqual(counts.downloading, 1); XCTAssertEqual(counts.seeding, 1)
    }
    func testTRUnknownStatusRemainsUnknownAndErrorOverlaps() throws {
        let result = try DashboardParser.trCounts([["status": 22, "error": 0], ["status": 6, "error": 2]])
        XCTAssertEqual(result.unknown, 1); XCTAssertEqual(result.seeding, 1); XCTAssertEqual(result.errors, 1)
    }
    func testTRMissingErrorOrFractionalStatusDoesNotBecomeHealthy() {
        XCTAssertThrowsError(try DashboardParser.trCounts([["status": 6]]))
        XCTAssertThrowsError(try DashboardParser.trCounts([["status": 1.5, "error": 0]]))
        XCTAssertThrowsError(try DashboardParser.trCounts([["status": true, "error": 0]]))
    }
    func testTRCountsFromLaterListAllowNaturalChangesBetweenReads() throws {
        let result = try DashboardParser.tr(stats: ["downloadSpeed": 0, "uploadSpeed": 10, "torrentCount": 2], rows: [["status": 6, "error": 0]])
        XCTAssertEqual(result.counts?.total, 1); XCTAssertFalse(result.warnings.isEmpty)
    }
    func testTRMissingTrafficAndTotalsAreUnknown() throws {
        XCTAssertThrowsError(try DashboardParser.tr(stats: ["torrentCount": 0], rows: []))
        let result = try DashboardParser.tr(stats: ["downloadSpeed": 0, "uploadSpeed": 0, "torrentCount": 0], rows: [])
        XCTAssertNil(result.cumulativeUploaded)
    }
    func testTRDiskRequiresMatchingDirectoryAndValidCapacity() {
        XCTAssertNotNil(DashboardParser.trDisk(["path": "/media", "size-bytes": 0, "total_size": 100], requestedPath: "/media"))
        XCTAssertNil(DashboardParser.trDisk(["path": "/different", "size-bytes": 5], requestedPath: "/media"))
        XCTAssertNil(DashboardParser.trDisk(["path": "/media", "size-bytes": 101, "total_size": 100], requestedPath: "/media"))
        XCTAssertNil(DashboardParser.trDisk(["path": "/media", "size-bytes": -1], requestedPath: "/media"))
    }
    func testFreshnessRejectsStaleFailedAndFutureData() {
        var value = DashboardSnapshot(kind: .qb1, downloadRate: 0, uploadRate: 0, updatedAt: moment)
        XCTAssertTrue(value.isFresh(now: moment)); XCTAssertFalse(value.isFresh(now: moment.addingTimeInterval(126)))
        XCTAssertFalse(value.isFresh(now: moment.addingTimeInterval(-6)))
        value.error = "failed"; XCTAssertFalse(value.isFresh(now: moment))
    }
    func testFailurePreservesPriorTimestampWithoutRebrandingCacheCurrent() {
        let prior = DashboardSnapshot(kind: .tr, downloadRate: 12, uploadRate: 34, updatedAt: moment)
        let failed = DashboardSnapshot.failure(kind: .tr, previous: prior, error: "连接超时", now: moment.addingTimeInterval(50))
        XCTAssertEqual(failed.updatedAt, moment); XCTAssertEqual(failed.downloadRate, 12)
        XCTAssertEqual(failed.attemptedAt, moment.addingTimeInterval(50)); XCTAssertFalse(failed.isFresh(now: moment.addingTimeInterval(50)))
    }
    func testNoFreshServicesShowsUnknownRatherThanZero() {
        let value = DashboardAggregate(configured: [.qb1, .tr], snapshots: [:], now: moment)
        XCTAssertEqual(value.currentCount, 0); XCTAssertTrue(value.hasPartialCoverage)
        XCTAssertNil(value.downloadRate); XCTAssertNil(value.uploadRate); XCTAssertNil(value.counts)
    }
    func testOnlyFreshConfiguredServicesContributeToPartialAggregate() {
        let good = DashboardSnapshot(kind: .qb1, downloadRate: 10, uploadRate: 20, counts: DashboardTaskCounts(total: 4, seeding: 3), updatedAt: moment)
        let stale = DashboardSnapshot(kind: .tr, downloadRate: 9000, uploadRate: 9000, updatedAt: moment.addingTimeInterval(-130))
        let unconfigured = DashboardSnapshot(kind: .qb2, downloadRate: 9000, uploadRate: 9000, updatedAt: moment)
        let value = DashboardAggregate(configured: [.qb1, .tr], snapshots: [.qb1: good, .tr: stale, .qb2: unconfigured], now: moment)
        XCTAssertEqual(value.downloadRate, 10); XCTAssertEqual(value.currentCount, 1); XCTAssertEqual(value.counts?.seeding, 3)
    }
    func testDuplicateConfiguredServiceNotCountedTwice() {
        let value = DashboardAggregate(configured: [.qb1, .qb1, .emby], snapshots: [.qb1: DashboardSnapshot(kind: .qb1, downloadRate: 10, updatedAt: moment)], now: moment)
        XCTAssertEqual(value.configuredCount, 1); XCTAssertEqual(value.downloadRate, 10)
    }
    func testQBRefreshUsesOneCompleteSyncGetWithoutTaskOrPeerCalls() async throws {
        var requests: [String] = []
        DashboardHTTP.handler = { request in
            requests.append(request.url!.path); XCTAssertEqual(request.httpMethod, "GET")
            if request.url!.path.hasSuffix("app/version") { return (200, [:], Data("v5.2.4".utf8)) }
            XCTAssertEqual(request.url!.path, "/api/v2/sync/maindata")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "0")
            return (200, [:], self.json(self.qbPayload()))
        }
        let result = try await client(.qb1).dashboard()
        XCTAssertEqual(result.counts?.total, 1); XCTAssertEqual(requests.count, 2)
    }
    func testNonDownloaderRejectedBeforeAnyNetwork() async {
        var calls = 0; DashboardHTTP.handler = { _ in calls += 1; throw URLError(.badURL) }
        do { _ = try await client(.emby).dashboard(); XCTFail("must reject") } catch {}
        XCTAssertEqual(calls, 0)
    }
    func testTRDiskFailurePreservesKnownCountersWithoutRetryOrWrite() async throws {
        var calls = 0
        DashboardHTTP.handler = { request in
            calls += 1; XCTAssertEqual(request.httpMethod, "POST")
            let args: [String: Any]
            switch calls {
            case 1: args = ["downloadSpeed": 0, "uploadSpeed": 5, "torrentCount": 1]
            case 2: args = ["torrents": [["hashString": self.testHash, "status": 6, "error": 0]]]
            default: return (500, [:], Data())
            }
            return (200, [:], self.json(["result": "success", "arguments": args]))
        }
        let result = try await client(.tr).dashboard()
        XCTAssertEqual(calls, 3); XCTAssertEqual(result.uploadRate, 5); XCTAssertNil(result.disk)
        XCTAssertFalse(result.warnings.isEmpty); XCTAssertNil(result.error)
    }

    func testQBTaskFiltersMatchDashboardCategoryCountsIncludingQueuesAndErrors() throws {
        let states = ["uploading", "stalledUP", "forcedUP", "downloading", "stalledDL", "forcedDL", "metaDL", "forcedMetaDL",
                      "checkingUP", "checkingDL", "checkingResumeData", "stoppedUP", "stoppedDL", "pausedUP", "pausedDL",
                      "queuedUP", "queuedDL", "error", "missingFiles", "moving", "future-state"]
        var rows: [[String: Any]] = states.map { ["state": $0, "progress": 1.0] }
        rows.append(["state": "stalledUP", "progress": 1.0, "has_tracker_error": true])
        rows.append(["state": "downloading", "progress": 0.2, "has_other_announce_error": true])
        let counts = try DashboardParser.qbCounts(rows)
        let tasks = rows.map { TaskParser.qb($0, kind: .qb1) }
        for filter in DashboardTaskFilter.allCases {
            XCTAssertEqual(tasks.filter { filter.includes($0) }.count, counts[filter], filter.rawValue)
        }
        XCTAssertEqual(counts.queued, 2); XCTAssertEqual(counts.unknown, 2)
        for task in tasks where ["queuedUP", "queuedDL"].contains(task.rawState) {
            XCTAssertFalse(DashboardTaskFilter.seeding.includes(task))
            XCTAssertFalse(DashboardTaskFilter.downloading.includes(task))
        }
    }

    func testTRTaskFiltersMatchDashboardCategoryCountsAndUnknownNeverBecomeSeeding() throws {
        let rows: [[String: Any]] = (0...7).map { ["status": $0, "error": $0 == 6 ? 2 : 0, "percentDone": 1.0, "leftUntilDone": 0] }
        let counts = try DashboardParser.trCounts(rows)
        let tasks = rows.map(TaskParser.tr)
        for filter in DashboardTaskFilter.allCases {
            XCTAssertEqual(tasks.filter { filter.includes($0) }.count, counts[filter], filter.rawValue)
        }
        XCTAssertEqual(counts.unknown, 1)
        XCTAssertFalse(DashboardTaskFilter.seeding.includes(tasks.last!))
    }

    func testSameHashAcrossDownloadersHasDistinctQualifiedIdentity() {
        let qb1 = TaskParser.qb(["hash": testHash, "state": "stalledUP", "progress": 1.0], kind: .qb1)
        let qb2 = TaskParser.qb(["hash": testHash, "state": "stalledUP", "progress": 1.0], kind: .qb2)
        let tr = TaskParser.tr(["hashString": testHash, "status": 6, "error": 0, "percentDone": 1.0, "leftUntilDone": 0])
        XCTAssertEqual(qb1.id, tr.id)
        XCTAssertEqual(Set([qb1.qualifiedID, qb2.qualifiedID, tr.qualifiedID]).count, 3)
    }

    func testMissingRawStateDoesNotBecomeSeedingMerelyBecauseFilesAreComplete() {
        let task = TaskParser.qb(["hash": testHash, "progress": 1.0], kind: .qb1)
        XCTAssertTrue(task.isComplete)
        XCTAssertFalse(DashboardTaskFilter.seeding.includes(task))
        XCTAssertFalse(DashboardTaskFilter.downloading.includes(task))
        XCTAssertTrue(DashboardTaskFilter.all.includes(task))
    }

    func testTasksAndDashboardShareFullSyncTrackerFlagsAndErrorFilter() async throws {
        var payload = qbPayload()
        payload["torrents"] = [
            testHash: ["state": "stalledUP", "progress": 1.0, "has_tracker_error": true, "has_other_announce_error": false],
            String(repeating: "b", count: 40): ["state": "queuedUP", "progress": 1.0, "has_tracker_error": false, "has_other_announce_error": false]
        ]
        var syncCalls = 0
        DashboardHTTP.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            if request.url!.path.hasSuffix("app/version") { return (200, [:], Data("v5.2.4".utf8)) }
            XCTAssertEqual(request.url!.path, "/api/v2/sync/maindata")
            syncCalls += 1
            return (200, [:], self.json(payload))
        }
        let api = client(.qb1)
        let dashboard = try await api.dashboard()
        let tasks = try await api.tasks()
        XCTAssertEqual(syncCalls, 2)
        XCTAssertEqual(tasks.count, dashboard.counts?.total)
        XCTAssertEqual(tasks.filter { DashboardTaskFilter.errors.includes($0) }.count, dashboard.counts?.errors)
        XCTAssertEqual(tasks.filter { DashboardTaskFilter.seeding.includes($0) }.count, dashboard.counts?.seeding)
        XCTAssertEqual(tasks.first(where: { $0.id == self.testHash })?.error, "Tracker 连接异常")
        XCTAssertEqual(tasks.filter { $0.rawState == "queuedUP" }.count, 1)
    }
}
