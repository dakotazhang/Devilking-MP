import XCTest
import Foundation
@testable import DevilkingMP

final class SubscriptionLedgerTests: XCTestCase {
    private func fixture() -> (String, UserDefaults) {
        let name = "DevilkingMP.LedgerTest." + UUID().uuidString
        return (name, UserDefaults(suiteName: name)!)
    }
    private func profile(url: String = "http://192.168.1.100:3000", username: String = "fixture-account") -> ServiceProfile {
        ServiceProfile(kind: .moviepilot, baseURL: url, username: username)
    }
    private func request(tv: Bool = false, season: Int? = nil, source: String = "themoviedb") -> MPSubscriptionRequest {
        MPSubscriptionRequest(item: MPDiscoveryItem(mediaSource: source, mediaID: "12345", title: "测试作品", year: "2025",
                                                   mediaType: tv ? "电视剧" : "电影", poster: nil, backdrop: nil,
                                                   overview: "", rating: nil, genres: [], isAnime: false), season: season)
    }

    func testPreparedIntentSurvivesLedgerAndDefaultsRecreation() throws {
        let (name, defaults) = fixture(); defer { defaults.removePersistentDomain(forName: name) }
        let first = SubscriptionWriteLedger(defaults: defaults)
        let key = first.key(profile: profile(), request: request())
        XCTAssertNil(try first.record(key))
        try first.prepare(key)
        XCTAssertNil(try first.record(key)?.confirmedID)
        let anotherDefaults = UserDefaults(suiteName: name)!
        let reopened = SubscriptionWriteLedger(defaults: anotherDefaults)
        XCTAssertNotNil(try reopened.record(key))
        XCTAssertThrowsError(try reopened.prepare(key), "An uncertain intent must still block after reopening")
    }

    func testDuplicatePreparationDoesNotResetOriginalTimestamp() throws {
        let (name, defaults) = fixture(); defer { defaults.removePersistentDomain(forName: name) }
        let ledger = SubscriptionWriteLedger(defaults: defaults), key = ledger.key(profile: profile(), request: request())
        try ledger.prepare(key)
        let original = try XCTUnwrap(ledger.record(key))
        XCTAssertThrowsError(try ledger.prepare(key))
        XCTAssertEqual(try ledger.record(key), original)
    }

    func testDifferentServiceAccountAndSeasonIdentitiesAreIsolated() throws {
        let (name, defaults) = fixture(); defer { defaults.removePersistentDomain(forName: name) }
        let ledger = SubscriptionWriteLedger(defaults: defaults)
        let keys = [ledger.key(profile: profile(), request: request()),
                    ledger.key(profile: profile(url: "http://192.168.1.101:3000"), request: request()),
                    ledger.key(profile: profile(username: "another-account"), request: request()),
                    ledger.key(profile: profile(), request: request(tv: true, season: 0)),
                    ledger.key(profile: profile(), request: request(tv: true, season: 1)),
                    ledger.key(profile: profile(), request: request(tv: true, season: nil))]
        XCTAssertEqual(Set(keys).count, keys.count)
        for key in keys { try ledger.prepare(key) }
        for key in keys { XCTAssertNotNil(try ledger.record(key)) }
    }

    func testTMDBAliasUsesSameWriteIdentity() {
        let (name, defaults) = fixture(); defer { defaults.removePersistentDomain(forName: name) }
        let ledger = SubscriptionWriteLedger(defaults: defaults)
        XCTAssertEqual(ledger.key(profile: profile(), request: request(source: "tmdb")),
                       ledger.key(profile: profile(), request: request(source: "themoviedb")),
                       "Canonical aliases must not bypass an unknown write intent")
    }

    func testMalformedJSONBlocksReadsAndNewWritesWithoutReplacingEvidence() {
        let (name, defaults) = fixture(); defer { defaults.removePersistentDomain(forName: name) }
        let original = Data("{not-json".utf8)
        defaults.set(original, forKey: "subscriptionWriteIntents.v1")
        let ledger = SubscriptionWriteLedger(defaults: defaults)
        XCTAssertThrowsError(try ledger.record("fixture-key"))
        XCTAssertThrowsError(try ledger.prepare("fixture-key"))
        XCTAssertThrowsError(try ledger.confirm("fixture-key", id: "77"))
        XCTAssertEqual(defaults.data(forKey: "subscriptionWriteIntents.v1"), original)
    }

    func testWrongStorageTypeIsCorruptionRatherThanAnEmptyLedger() {
        let (name, defaults) = fixture(); defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("corrupt-record", forKey: "subscriptionWriteIntents.v1")
        let ledger = SubscriptionWriteLedger(defaults: defaults)
        XCTAssertThrowsError(try ledger.record("fixture-key"))
        XCTAssertThrowsError(try ledger.prepare("fixture-key"))
        XCTAssertThrowsError(try ledger.confirm("fixture-key", id: "77"))
        XCTAssertEqual(defaults.string(forKey: "subscriptionWriteIntents.v1"), "corrupt-record")
    }

    func testConfirmRetainsIntentAndCreationTimeAfterReopening() throws {
        let (name, defaults) = fixture(); defer { defaults.removePersistentDomain(forName: name) }
        let ledger = SubscriptionWriteLedger(defaults: defaults), key = ledger.key(profile: profile(), request: request())
        try ledger.prepare(key)
        let start = try XCTUnwrap(ledger.record(key)).createdAt
        try ledger.confirm(key, id: "77")
        let reopened = SubscriptionWriteLedger(defaults: UserDefaults(suiteName: name)!)
        let confirmed = try XCTUnwrap(reopened.record(key))
        XCTAssertEqual(confirmed.createdAt, start); XCTAssertEqual(confirmed.confirmedID, "77")
        XCTAssertThrowsError(try reopened.prepare(key), "Confirmed history must not silently become retryable")
    }

    func testFreshReadOfExistingSubscriptionCanCreateConfirmedRecord() throws {
        let (name, defaults) = fixture(); defer { defaults.removePersistentDomain(forName: name) }
        let ledger = SubscriptionWriteLedger(defaults: defaults), key = ledger.key(profile: profile(), request: request())
        try ledger.confirm(key, id: "78")
        XCTAssertEqual(try ledger.record(key)?.confirmedID, "78")
        XCTAssertThrowsError(try ledger.prepare(key))
    }

    func testPersistedLedgerContainsHashedIdentityRatherThanConnectionOrTitle() throws {
        let (name, defaults) = fixture(); defer { defaults.removePersistentDomain(forName: name) }
        let ledger = SubscriptionWriteLedger(defaults: defaults), key = ledger.key(profile: profile(), request: request())
        XCTAssertEqual(key.count, 64)
        XCTAssertTrue(key.allSatisfy { $0.isHexDigit })
        try ledger.prepare(key)
        let text = String(data: try XCTUnwrap(defaults.data(forKey: "subscriptionWriteIntents.v1")), encoding: .utf8)!
        for privateValue in ["192.168.1.100", "fixture-account", "测试作品", "themoviedb:12345"] {
            XCTAssertFalse(text.contains(privateValue))
        }
    }
}
