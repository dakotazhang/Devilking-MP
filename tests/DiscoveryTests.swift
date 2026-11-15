import XCTest
@testable import DevilkingMP

final class DiscoveryTests: XCTestCase {
    private func row(_ overrides: [String: Any] = [:]) -> [String: Any] {
        var value: [String: Any] = ["media_source": "themoviedb", "media_id": "12345", "title": "合成作品", "year": "2025", "type": "电影", "vote_average": 7.8, "poster_path": "/synthetic.jpg", "overview": "测试简介"]
        overrides.forEach { value[$0.key] = $0.value }
        return value
    }
    private func item(_ overrides: [String: Any] = [:]) -> MPDiscoveryItem { MPDiscoveryParser.item(row(overrides))! }

    func testIdentityPreservesNativeSourcePair() {
        let value = item(["media_source": "douban", "media_id": "8888", "tmdb_id": 4444])
        XCTAssertEqual(value.mediaSource, "douban")
        XCTAssertEqual(value.mediaID, "8888")
        XCTAssertTrue(value.hasSubscribableIdentity)
    }
    func testTMDBAliasIsCanonicalWithoutTitleFallback() {
        let value = item(["media_source": "tmdb"])
        XCTAssertEqual(value.mediaSource, "themoviedb")
        var missing = row(); missing.removeValue(forKey: "media_id")
        XCTAssertNil(MPDiscoveryParser.item(missing))
    }
    func testExplicitSourceIsRequiredForBareProviderIdentity() {
        let value = MPDiscoveryParser.item(["id": 12345, "title": "仅有编号", "media_type": "movie"])!
        XCTAssertFalse(value.hasSubscribableIdentity)
        let known = MPDiscoveryParser.item(["id": 12345, "title": "来源已核对", "media_type": "movie"], defaultSource: "tmdb")!
        XCTAssertTrue(known.hasSubscribableIdentity)
    }
    func testNumericAndHostileIdentitiesCannotSelectBroadScope() {
        for id in ["", "all", "1|2", "../123", "0", "0000", "１２３", String(repeating: "1", count: 21)] {
            XCTAssertFalse(item(["media_id": id.isEmpty ? "0" : id]).hasSubscribableIdentity, id)
        }
        XCTAssertFalse(item(["media_source": "unknown"]).hasSubscribableIdentity)
    }
    func testMovieAndSeriesWithSameProviderIDStayDistinct() {
        XCTAssertNotEqual(item(["type": "movie"]).id, item(["type": "tv"]).id)
        XCTAssertEqual(item(["type": "movie"]).canonicalType, "电影")
        XCTAssertEqual(item(["type": "tv"]).canonicalType, "电视剧")
    }
    func testUnknownTypeCannotCreateSubscription() {
        XCTAssertFalse(item(["type": "unknown"]).hasSubscribableIdentity)
    }
    func testAnimationCategoryIsBasedOnMetadataNotTitle() {
        let animated = item(["genre_ids": [16, 35], "type": "tv"])
        XCTAssertTrue(MPBrowseCategory.anime.includes(animated))
        XCTAssertFalse(MPBrowseCategory.tv.includes(animated))
        XCTAssertFalse(MPBrowseCategory.movie.includes(animated))
        XCTAssertTrue(MPBrowseCategory.all.includes(animated))
        XCTAssertFalse(item(["title": "动画制作人的真实人生"]).isAnime)
    }
    func testNamedAnimationGenresAreRecognized() {
        XCTAssertTrue(item(["genres": [["id": 16, "name": "Animation"]]]).isAnime)
        XCTAssertTrue(item(["genres": ["动画"]]).isAnime)
    }
    func testMissingRatingIsUnknownInsteadOfZeroScore() {
        let ratings: [Any] = [0, -1, 11, "n/a", "Infinity"]
        for rating in ratings { XCTAssertNil(item(["vote_average": rating]).rating) }
        XCTAssertEqual(item(["vote_average": "8.2"]).rating, 8.2)
    }
    func testPublicArtworkUsesHTTPSWithoutCredentialsOrQuery() {
        XCTAssertEqual(MPDiscoveryParser.artwork("/synthetic.jpg"), "https://image.tmdb.org/t/p/w500/synthetic.jpg")
        for invalid in ["//external.test/poster.jpg", "http://external.test/a.jpg", "https://user:secret@external.test/a.jpg", "https://external.test/a.jpg?api_key=secret", "file:///tmp/a", "dkemby:123"] {
            XCTAssertNil(MPDiscoveryParser.artwork(invalid), invalid)
        }
        XCTAssertEqual(MPDiscoveryParser.artwork("https://images.example.org/poster.jpg"), "https://images.example.org/poster.jpg")
    }
    func testYearFallsBackOnlyToReturnedDate() {
        var value = row(); value.removeValue(forKey: "year"); value["release_date"] = "2024-02-01"
        XCTAssertEqual(MPDiscoveryParser.item(value)?.year, "2024")
    }
    func testDetailNeverChangesSelectedProviderIdentityOrType() {
        let original = item(["type": "电视剧"])
        let detail = MPDiscoveryParser.detail(row(["media_source": "douban", "media_id": "9999", "type": "电影"]), fallback: original)
        XCTAssertEqual(detail.item.mediaSource, original.mediaSource)
        XCTAssertEqual(detail.item.mediaID, original.mediaID)
        XCTAssertEqual(detail.item.canonicalType, original.canonicalType)
    }
    func testDetailKeepsPosterAndOverviewWhenAbsent() {
        let original = item()
        let detail = MPDiscoveryParser.detail([:], fallback: original)
        XCTAssertEqual(detail.item.poster, original.poster)
        XCTAssertEqual(detail.item.overview, original.overview)
    }
    func testSeasonsKeepSpecialsDistinctAndRejectMalformedNumbers() {
        let value = MPDiscoveryParser.detail(["seasons": [
            ["season_number": 2, "name": "第二季", "episode_count": 12],
            ["season_number": 0], ["season_number": 1], ["season_number": 2],
            ["season_number": -1], ["season_number": "broken"], ["season_number": 1.5], ["season_number": 1e100]
        ]], fallback: item(["type": "tv"]))
        XCTAssertEqual(value.seasons.map(\.number), [0, 1, 2])
        XCTAssertEqual(value.seasons.first?.title, "特别篇")
        XCTAssertEqual(value.seasons.last?.episodeCount, 12)
    }
    func testSeriesRequiresExplicitSeasonIncludingSpecialsZero() {
        let series = item(["type": "tv"])
        XCTAssertFalse(MPSubscriptionRequest(item: series, season: nil).isValid)
        XCTAssertTrue(MPSubscriptionRequest(item: series, season: 0).isValid)
        XCTAssertTrue(MPSubscriptionRequest(item: series, season: 1).isValid)
        XCTAssertFalse(MPSubscriptionRequest(item: series, season: -1).isValid)
        XCTAssertFalse(MPSubscriptionRequest(item: series, season: 10001).isValid)
        XCTAssertNotEqual(MPSubscriptionRequest(item: series, season: nil).identityKey, MPSubscriptionRequest(item: series, season: 0).identityKey)
    }
    func testMovieRequestCannotCarrySeriesSeason() {
        XCTAssertTrue(MPSubscriptionRequest(item: item(), season: nil).isValid)
        XCTAssertFalse(MPSubscriptionRequest(item: item(), season: 1).isValid)
    }
    func testSubscriptionFilterAcceptsRawAndExistingTranslatedStates() {
        for state in ["R", "N", "P", "Q", "订阅中", "等待", "待定", "排队中"] { XCTAssertTrue(MPSubscriptionFilter.active.includes(state), state) }
        for state in ["S", "已暂停"] { XCTAssertTrue(MPSubscriptionFilter.paused.includes(state), state); XCTAssertFalse(MPSubscriptionFilter.active.includes(state)) }
        XCTAssertFalse(MPSubscriptionFilter.active.includes("unknown"))
        XCTAssertEqual(MPSubscriptionFilter.title(for: "unknown"), "状态未知")
    }
}
