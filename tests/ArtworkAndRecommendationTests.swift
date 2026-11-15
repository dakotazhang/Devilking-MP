import XCTest
import Foundation
@testable import DevilkingMP

final class ArtworkAndRecommendationTests:XCTestCase {
    private let png=Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/a9sAAAAASUVORK5CYII=")!
    private let poster="https://img1.doubanio.com/view/photo/s_ratio_poster/public/fixture.webp?width=300"
    private let providers:[[String:Any]]=[["media_source":"themoviedb"],["media_source":"douban"],["media_source":"bangumi"],["media_source":"anilist"]]
    private func client(kind:ServiceKind = .moviepilot)->APIClient {
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[MockHTTP.self]
        return APIClient(profile:ServiceProfile(kind:kind,baseURL:"http://192.168.1.100:3000",username:"fixture",allowActions:false),credentials:Credential(username:"fixture",apiKey:"fixture-key"),session:URLSession(configuration:config))
    }
    private func json(_ value:Any)->Data { try! JSONSerialization.data(withJSONObject:value) }
    private func envelope(_ value:Any)->Data { json(["success":true,"data":value]) }
    private func flags(_ value:Bool)->[String:Bool] {
        Dictionary(uniqueKeysWithValues:MPRecommendationCatalog.builtins.map{($0.title,value)})
    }
    override func tearDown() { MockHTTP.handler=nil;super.tearDown() }

    func testPublicArtworkAllowsBoundedResizeParametersWithoutAllowingCredentials() {
        XCTAssertEqual(MPArtworkPolicy.reference(poster),poster)
        for bad in ["https://img.example/poster.jpg?passkey=secret","https://img.example/poster.jpg?token=secret","https://user:secret@img.example/poster.jpg","https://img.example/poster.jpg?width=https://private.example","https://img.example/api/restart","https://img.example/download.php?id=1","http://img.example/poster.jpg"] {
            XCTAssertNil(MPArtworkPolicy.reference(bad),bad)
        }
    }
    func testMPProxyReferenceUnwrapsNestedURLAndDropsOuterResourceToken() {
        var components=URLComponents();components.path="/api/v1/system/cache/image";components.queryItems=[URLQueryItem(name:"url",value:poster),URLQueryItem(name:"token",value:"old-resource-token")]
        XCTAssertEqual(MPArtworkPolicy.reference(components.string!),poster)
        components.path="/api/v1/system/img/0";components.queryItems=[URLQueryItem(name:"imgurl",value:poster),URLQueryItem(name:"use_cookies",value:"true")]
        XCTAssertEqual(MPArtworkPolicy.reference(components.string!),poster)
        XCTAssertNil(MPArtworkPolicy.reference("/api/v1/system/restart?url=https://img.example/poster.jpg"))
        XCTAssertNil(MPArtworkPolicy.reference("https://img.example/poster.jpg?auth=secret"))
    }
    func testMPProxyCannotTargetPrivateAddressOrProtocol() {
        for target in ["http://192.168.1.200/poster.jpg","https://127.0.0.1/poster.jpg","file:///private/poster.jpg","https://localhost/poster.jpg"] {
            var components=URLComponents();components.path="/api/v1/system/cache/image";components.queryItems=[URLQueryItem(name:"url",value:target)]
            XCTAssertNil(MPArtworkPolicy.reference(components.string!))
        }
    }
    func testImageUsesOnlyConfiguredMPOriginAndHeaderWithoutBusinessPermission() async throws {
        var count=0
        MockHTTP.handler={request in
            count+=1
            XCTAssertEqual(request.httpMethod,"GET");XCTAssertEqual(request.url!.host,"192.168.1.100")
            XCTAssertEqual(request.url!.path,"/api/v1/system/cache/image")
            XCTAssertEqual(request.value(forHTTPHeaderField:"X-API-KEY"),"fixture-key")
            let query=URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems!
            XCTAssertEqual(query.count,1);XCTAssertEqual(query.first?.name,"url");XCTAssertEqual(query.first?.value,self.poster)
            return (200,["Content-Type":"image/png"],self.png)
        }
        let result=try await client().moviePilotArtwork(poster)
        XCTAssertEqual(result,png);XCTAssertEqual(count,1)
    }
    func testInvalidImageReferenceAndWrongServiceMakeNoNetworkRequest() async {
        var count=0;MockHTTP.handler={_ in count+=1;return (200,["Content-Type":"image/png"],self.png)}
        do { _=try await client().moviePilotArtwork("/api/v1/system/restart");XCTFail() } catch {}
        do { _=try await client(kind:.qb1).moviePilotArtwork(poster);XCTFail() } catch {}
        XCTAssertEqual(count,0)
    }
    func testExpiredJWTIsClearedWithoutReplayAndNextExplicitImageRetryLogsInAgain() async throws {
        let configuration=URLSessionConfiguration.ephemeral;configuration.protocolClasses=[MockHTTP.self]
        let api=APIClient(profile:ServiceProfile(kind:.moviepilot,baseURL:"http://192.168.1.100:3000",username:"fixture"),credentials:Credential(username:"fixture",password:"fixture-only"),session:URLSession(configuration:configuration))
        var log=[String](),logins=0,images=0
        MockHTTP.handler={request in
            if request.url!.path.hasSuffix("/login/access-token") {
                logins+=1;log.append("login")
                return (200,[:],self.json(["access_token":logins == 1 ? "expired-fixture":"fresh-fixture"]))
            }
            XCTAssertEqual(request.httpMethod,"GET");XCTAssertEqual(request.url!.path,"/api/v1/system/cache/image")
            images+=1;log.append("image")
            XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),images == 1 ? "Bearer expired-fixture":"Bearer fresh-fixture")
            return images == 1 ? (401,["Content-Type":"application/json"],self.json(["detail":"expired"])) : (200,["Content-Type":"image/png"],self.png)
        }
        do { _=try await api.moviePilotArtwork(poster);XCTFail("First image must fail without replay") } catch {}
        XCTAssertEqual(log,["login","image"])
        let result=try await api.moviePilotArtwork(poster)
        XCTAssertEqual(result,png);XCTAssertEqual(log,["login","image","login","image"])
    }
    func testHTTP418AndFakeImagePayloadRemainFailuresWithoutAutomaticRetry() async {
        for status in [200,418] {
            var count=0;MockHTTP.handler={_ in count+=1;return (status,["Content-Type":"image/webp"],Data("not-an-image".utf8))}
            do { _=try await client().moviePilotArtwork(poster);XCTFail("False image MIME or HTTP failure must not be success") } catch {}
            XCTAssertEqual(count,1)
        }
    }
    func testHTMLMIMEAndOversizedContentLengthFailBeforeImageAcceptance() async {
        for headers in [["Content-Type":"text/html"],["Content-Type":"image/png","Content-Length":String(MPArtworkPolicy.maximumBytes+1)]] {
            MockHTTP.handler={_ in (200,headers,self.png)}
            do { _=try await client().moviePilotArtwork(poster);XCTFail() } catch {}
        }
    }
    func testStreamingSizeLimitAlsoRejectsMissingContentLength() async {
        var oversized=png;oversized.append(Data(repeating:0,count:MPArtworkPolicy.maximumBytes))
        MockHTTP.handler={_ in (200,["Content-Type":"image/png"],oversized)}
        do { _=try await client().moviePilotArtwork(poster);XCTFail() } catch {}
    }
    func testRealImageMagicIsRequiredForAllowedMIME() throws {
        XCTAssertEqual(try MPArtworkPolicy.validateImage(png,mime:"image/png; charset=binary"),png)
        XCTAssertThrowsError(try MPArtworkPolicy.validateImage(Data("<html>login</html>".utf8),mime:"image/png"))
    }
    func testNullRecommendationConfigurationUsesNativeFilmColumnOrder() throws {
        let rows=try MPRecommendationCatalog.configured(["value":NSNull()],extensions:[],providers:providers)
        XCTAssertEqual(rows.count,15)
        XCTAssertEqual(rows.prefix(3).map(\.id),["recommend/tmdb_trending","recommend/douban_showing","recommend/bangumi_calendar"])
        XCTAssertFalse(rows.contains{$0.path?.contains("music") == true})
    }
    func testExplicitAllDisabledIsEmptyInsteadOfFallingBackToHardcodedFour() throws {
        let rows=try MPRecommendationCatalog.configured(["value":flags(false)],extensions:[],providers:providers)
        XCTAssertTrue(rows.isEmpty)
    }
    func testSelectedColumnsAndMediaProviderAvailabilityAreBothRespected() throws {
        var selected=flags(false);selected["豆瓣最新电视剧"]=true;selected["TMDB热门电影"]=true
        let rows=try MPRecommendationCatalog.configured(["value":selected],extensions:[],providers:[["media_source":"douban"]])
        XCTAssertEqual(rows.map(\.id),["recommend/douban_tvs"])
    }
    func testEnglishAndTraditionalConfigurationKeysAreRecognized() throws {
        var selected=flags(false);selected.removeValue(forKey:"TMDB热门电影");selected["TMDB Hot Movies"]=true
        selected.removeValue(forKey:"豆瓣最新电视剧");selected["豆瓣最新電視劇"]=true
        let rows=try MPRecommendationCatalog.configured(["value":selected],extensions:[],providers:providers)
        XCTAssertEqual(rows.map(\.id),["recommend/tmdb_movies","recommend/douban_tvs"])
    }
    func testOlderSavedSelectionAutoEnablesOnlyNativeNewAniListDefaults() throws {
        let rows=try MPRecommendationCatalog.configured(["value":["正在热映":true]],extensions:[],providers:providers)
        XCTAssertEqual(rows.map(\.id),["recommend/douban_showing","anilist/trending","anilist/popular-this-season"])
    }
    func testUnknownPluginGETIsNotAutomaticallyExecuted() throws {
        var selected=flags(false);selected["扩展栏目"]=true
        let rows=try MPRecommendationCatalog.configured(["value":selected],extensions:[["name":"扩展栏目","api_path":"system/restart","type":"电影"]],providers:providers)
        XCTAssertEqual(rows.count,1);XCTAssertNil(rows.first?.path)
    }
    func testMalformedRecommendationSelectionIsUnknownInsteadOfDefaultEnabled() {
        for configuration in [["value":["正在热映":1]],["value":"broken"],[:]] as [[String:Any]] {
            XCTAssertThrowsError(try MPRecommendationCatalog.configured(configuration,extensions:[],providers:providers))
        }
    }
    func testDiscoveryReadsConfiguredCatalogAndKeepsSuccessfulColumnsOnOneFailure() async throws {
        var selected=flags(false);selected["正在热映"]=true;selected["豆瓣最新电视剧"]=true
        MockHTTP.handler={request in
            let path=request.url!.path
            if path.hasSuffix("/config/Recommend") { return (200,[:],self.envelope(["value":selected])) }
            if path.hasSuffix("/recommend/source") { return (200,[:],self.envelope([])) }
            if path.hasSuffix("/media/source") { return (200,[:],self.envelope(self.providers)) }
            if path.hasSuffix("/douban_tvs") { return (503,[:],Data()) }
            XCTAssertEqual(path,"/api/v1/recommend/douban_showing")
            return (200,[:],self.envelope([["title":"合成影片","media_source":"douban","media_id":"123","type":"电影","poster_path":self.poster]]))
        }
        let rows=try await client().discoverySections()
        XCTAssertEqual(rows.count,2);XCTAssertEqual(rows[0].items.count,1);XCTAssertNotNil(rows[1].error)
        XCTAssertEqual(rows[0].items[0].poster,poster)
    }
    func testBangumiAndAniListKeepNativeIdentityWithoutBecomingTMDB() throws {
        for source in ["bangumi","anilist"] {
            let item=try XCTUnwrap(MPDiscoveryParser.item(["title":"合成番剧","media_source":source,"media_id":"123","type":"电视剧"]))
            XCTAssertEqual(item.mediaSource,source);XCTAssertTrue(item.hasSubscribableIdentity)
        }
    }
}
