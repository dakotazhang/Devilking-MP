import XCTest
import Foundation
@testable import DevilkingMP

private final class ResourceFixtureLog: @unchecked Sendable {
    private let lock=NSLock()
    private var events=[String]()
    func append(_ value:String) { lock.lock();defer { lock.unlock() };events.append(value) }
    var values:[String] { lock.lock();defer { lock.unlock() };return events }
}

final class ResourceSearchTests: XCTestCase {
    private let base="http://192.168.1.100:3000"
    private func client() -> APIClient {
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[MockHTTP.self]
        return APIClient(profile:ServiceProfile(kind:.moviepilot,baseURL:base,username:"fixture"),credentials:Credential(username:"fixture",apiKey:"fixture-key"),session:URLSession(configuration:config))
    }
    /// Foundation URL.path may remove a terminal slash on Apple platforms.
    /// Route mocks compare a canonical path; raw wire-path assertions use URLComponents.
    private func path(_ request:URLRequest)->String {
        var path=URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.percentEncodedPath
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
    private func json(_ value:Any)->Data { try! JSONSerialization.data(withJSONObject:value) }
    private func envelope(_ value:Any)->Data { json(["success":true,"message":"","data":value]) }
    private func row(id:String="345",page:String?=nil,enclosure:String?=nil,site:Int=1)->[String:Any] {
        ["media_info":["media_source":"themoviedb","media_id":"12345","title":"合成测试影片","type":"电影","year":"2025"],
         "torrent_info":["site":site,"site_name":"测试站点","title":"Synthetic.2025.1080p.WEB-DL","description":"测试简介","page_url":page ?? "https://tracker.example/details.php?id=\(id)&passkey=fixture-secret", "enclosure":enclosure ?? "https://tracker.example/download.php?id=\(id)&passkey=fixture-secret","site_cookie":"fixture-only-cookie","site_ua":"fixture-agent","size":2_000_000_000,"seeders":7,"peers":2,"downloadvolumefactor":0,"uploadvolumefactor":2,"freedate":"2026-11-16 20:00:00","hit_and_run":false]]
    }
    private var downloader:MPResourceDownloader { MPResourceDownloader(id:"Fixture qB",name:"Fixture qB",type:"qbittorrent",targetBaseURL:"http://fixture-qb:8085",isDefault:true) }
    private var directory:MPResourceDirectory { MPResourceParser.directory(["name":"测试目录","storage":"local","save_path":"/downloads/fixture"])! }
    private func request(directory:MPResourceDirectory?=nil)->MPResourceDownloadRequest { MPResourceDownloadRequest(item:MPResourceParser.item(row())!,downloader:downloader,directory:directory) }
    private func body(_ request:URLRequest)->[String:Any] {
        if let data=request.httpBody { return (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:] }
        guard let stream=request.httpBodyStream else { return [:] };stream.open();defer { stream.close() }
        var data=Data(),buffer=[UInt8](repeating:0,count:1024)
        while stream.hasBytesAvailable { let count=stream.read(&buffer,maxLength:buffer.count);if count <= 0 { break };data.append(contentsOf:buffer.prefix(count)) }
        return (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:]
    }
    private func configResponse(_ r:URLRequest)->Data? {
        switch self.path(r) {
        case "/api/v1/site":return envelope([["id":1,"name":"测试站点","is_active":true]])
        case "/api/v1/download/clients":return envelope([["name":"Fixture qB","type":"qbittorrent"]])
        case "/api/v1/system/settings/describe/Downloaders":return envelope(["value":[["name":"Fixture qB","type":"qbittorrent","enabled":true,"default":true,"config":["host":"http://fixture-qb","port":8085,"password":"fixture-masked"]]]])
        case "/api/v1/download/paths":return envelope([["name":"测试目录","storage":"local","save_path":"/downloads/fixture"]])
        default:return nil
        }
    }
    override func tearDown() { MockHTTP.handler=nil;super.tearDown() }

    func testStableResourceIDIgnoresExpiringSecretsAndPayloadIsRedacted() throws {
        let a=try XCTUnwrap(MPResourceParser.item(row()))
        let b=try XCTUnwrap(MPResourceParser.item(row(page:"https://tracker.example/details.php?id=345&passkey=changed",enclosure:"https://tracker.example/download.php?id=345&token=changed")))
        XCTAssertEqual(a.id,b.id);XCTAssertTrue(a.canDownload)
        XCTAssertFalse(String(reflecting:a).contains("fixture-secret"));XCTAssertFalse(String(reflecting:a.payload!).contains("fixture-only-cookie"))
        XCTAssertNotEqual(a.id,MPResourceParser.item(row(site:2))?.id)
    }
    func testUnknownStableIdentityRemainsViewOnlyRatherThanUsingSignedURL() throws {
        let item=try XCTUnwrap(MPResourceParser.item(row(page:"https://tracker.example/item?token=rotating",enclosure:"https://tracker.example/download?token=rotating")))
        XCTAssertFalse(item.canDownload);XCTAssertNil(item.payload)
    }
    func testMissingSiteAndUnrecognizedMediaCannotBeDownloaded() {
        var value=row();value["media_info"]=[:]
        XCTAssertFalse(MPResourceParser.item(value)!.canDownload)
        var torrent=value["torrent_info"] as! [String:Any];torrent["site"]=true;value["torrent_info"]=torrent
        XCTAssertNil(MPResourceParser.item(value))
    }
    func testDisplayNeverEchoesURLCookieOrPasskey() {
        for raw in ["https://tracker.example/a?passkey=secret","magnet:?xt=secret","Cookie: session=secret","passkey=secret","token=secret"] {
            XCTAssertEqual(MPResourceParser.display(raw,fallback:"已隐藏"),"已隐藏")
        }
    }
    func testUnknownStatsAreNotRenderedAsZeroAndFreeRequiresKnownFactor() {
        var value=row();var torrent=value["torrent_info"] as! [String:Any]
        torrent["seeders"]="unknown";torrent["size"]=true;torrent.removeValue(forKey:"downloadvolumefactor");torrent.removeValue(forKey:"hit_and_run");value["torrent_info"]=torrent
        let parsed=MPResourceParser.item(value)!
        XCTAssertNil(parsed.seeders);XCTAssertNil(parsed.size);XCTAssertNil(parsed.downloadFactor);XCTAssertNil(parsed.hasHR)
    }
    func testDirectoryIdentityUsesPresetURIAndRejectsEmbeddedCredentials() {
        let a=MPResourceParser.directory(["name":"相同名","storage":"local","save_path":"/downloads/a"])!
        let b=MPResourceParser.directory(["name":"相同名","storage":"local","save_path":"/downloads/b"])!
        XCTAssertNotEqual(a.id,b.id)
        XCTAssertNil(MPResourceParser.directory(["save_path":"https://user:secret@storage.example/path"]))
        XCTAssertNil(MPResourceParser.directory(["save_path":"/downloads/a?token=secret"]))
    }
    func testDownloaderNeverRetainsCredentialFieldsOrGuessesRole() throws {
        let parsed=try XCTUnwrap(MPResourceParser.downloader(["name":"任意名称","type":"transmission","config":["host":"http://user:secret@fixture-tr/path?token=secret#x","port":9091,"password":"secret"]]))
        XCTAssertEqual(parsed.targetBaseURL,"http://fixture-tr:9091/path")
        XCTAssertEqual(parsed.compatibleKinds,[.tr])
        XCTAssertNil(MPResourceParser.downloader(["name":"unsupported","type":"deluge"]))
    }
    func testDownloaderBindingIsInvalidatedByTargetEndpointChange() {
        let original=downloader
        var changed=original;changed.targetBaseURL="http://different-qb:8085"
        XCTAssertNotEqual(original.bindingID,changed.bindingID)
        changed=original;changed.type="transmission"
        XCTAssertNotEqual(original.bindingID,changed.bindingID)
        changed=original;changed.targetBaseURL=nil
        XCTAssertFalse(changed.canBind)
        XCTAssertFalse(MPResourceDownloadRequest(item:MPResourceParser.item(row())!,downloader:changed).isValid)
    }
    func testSearchRequiresExplicitSitesAndNeverFetchesSharedLastCache() async throws {
        let log=ResourceFixtureLog()
        MockHTTP.handler={ request in
            log.append(self.path(request))
            if self.path(request) == "/api/v1/site" { return (200,[:],self.envelope([["id":1,"name":"测试站点","is_active":true]])) }
            XCTAssertEqual(request.httpMethod,"GET");XCTAssertEqual(self.path(request),"/api/v1/search/title")
            let q=URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems!
            XCTAssertEqual(q.first(where:{$0.name == "sites"})?.value,"1");XCTAssertEqual(q.first(where:{$0.name == "keyword"})?.value,"合成作品")
            XCTAssertEqual(request.timeoutInterval,125)
            return (200,[:],self.envelope([self.row()]))
        }
        let result=try await client().searchResources(query:"合成作品",sites:["1"])
        XCTAssertEqual(result.count,1);XCTAssertEqual(log.values,["/api/v1/site","/api/v1/search/title"])
    }
    func testEmptySitesBlockedBeforeNetworkAndForeignResultFailsClosed() async {
        let log=ResourceFixtureLog();MockHTTP.handler={r in log.append(self.path(r));return (200,[:],self.envelope([]))}
        do { _=try await client().searchResources(query:"合成作品",sites:[]);XCTFail() } catch {}
        XCTAssertTrue(log.values.isEmpty)
        MockHTTP.handler={r in if self.path(r) == "/api/v1/site" { return (200,[:],self.envelope([["id":1,"name":"测试站点","is_active":true]])) };return (200,[:],self.envelope([self.row(site:2)])) }
        do { _=try await client().searchResources(query:"合成作品",sites:["1"]);XCTFail() } catch {}
    }
    func testExactSearchKeepsSourceAndSpecialsSeasonZero() async throws {
        MockHTTP.handler={r in
            if self.path(r) == "/api/v1/site" { return (200,[:],self.envelope([["id":1,"name":"测试站点","is_active":true]])) }
            XCTAssertEqual(self.path(r),"/api/v1/search/media/777")
            let q=URLComponents(url:r.url!,resolvingAgainstBaseURL:false)!.queryItems!
            XCTAssertEqual(q.first(where:{$0.name == "season"})?.value,"0");XCTAssertEqual(q.first(where:{$0.name == "media_source"})?.value,"douban")
            return (200,[:],self.envelope([]))
        }
        let media=MPDiscoveryItem(mediaSource:"douban",mediaID:"777",title:"测试剧集",year:"2025",mediaType:"电视剧",poster:nil,backdrop:nil,overview:"",rating:nil,genres:[],isAnime:false)
        _=try await client().searchResources(query:media.title,sites:["1"],media:media,season:0)
    }
    func testOnlyExplicitNoResultsIsEmptyWhileBusinessFalseAndMalformedRemainErrors() async throws {
        for response in [["success":false,"message":"未搜索到任何资源"], ["success":false,"message":"failure https://tracker.example?passkey=secret"], ["data":[]]] as [[String:Any]] {
            MockHTTP.handler={r in if self.path(r) == "/api/v1/site" { return (200,[:],self.envelope([["id":1,"name":"测试站点","is_active":true]])) };return (200,[:],self.json(response)) }
            do { let result=try await client().searchResources(query:"作品",sites:["1"]);XCTAssertEqual(response["message"] as? String,"未搜索到任何资源");XCTAssertTrue(result.isEmpty) }
            catch { XCTAssertNotEqual(response["message"] as? String,"未搜索到任何资源");XCTAssertFalse(error.localizedDescription.contains("secret")) }
        }
    }
    func testReadOnlyDeniesDownloadBeforeAuthenticationOrConfigurationReads() async {
        let log=ResourceFixtureLog();MockHTTP.handler={r in log.append(self.path(r));return (200,[:],self.envelope([]))}
        do { _=try await client().downloadResource(request(),authorize:{false},beforeSend:{log.append("intent")});XCTFail() } catch {}
        XCTAssertTrue(log.values.isEmpty)
    }
    func testChangedInMemoryPayloadCannotDownloadDifferentResourceUnderOldIdentity() async {
        let log=ResourceFixtureLog();MockHTTP.handler={r in log.append(self.path(r));return (200,[:],self.envelope([]))}
        var changed=request();changed.item.payload=MPResourceParser.item(row(id:"999"))!.payload
        do { _=try await client().downloadResource(changed,authorize:{true},beforeSend:{log.append("intent")});XCTFail() } catch {}
        XCTAssertTrue(log.values.isEmpty)
    }
    func testDefaultDirectoryIsOmittedAndDurableIntentPrecedesSinglePost() async throws {
        let log=ResourceFixtureLog()
        MockHTTP.handler={r in
            log.append(self.path(r))
            if let data=self.configResponse(r) { return (200,[:],data) }
            XCTAssertEqual(self.path(r),"/api/v1/download");XCTAssertEqual(r.httpMethod,"POST")
            XCTAssertEqual(URLComponents(url:r.url!,resolvingAgainstBaseURL:false)?.percentEncodedPath,"/api/v1/download/")
            let payload=self.body(r);XCTAssertNil(payload["save_path"]);XCTAssertEqual(payload["downloader"] as? String,"Fixture qB")
            XCTAssertNotNil(payload["media_in"]);XCTAssertNotNil(payload["torrent_in"]);XCTAssertNil(payload["context"])
            XCTAssertTrue(log.values.contains("intent"));return (200,[:],self.envelope(["download_id":"fixturehash"]))
        }
        let id=try await client().downloadResource(request(),authorize:{true},beforeSend:{log.append("intent")})
        XCTAssertEqual(id,"fixturehash");XCTAssertEqual(log.values.filter{$0 == "/api/v1/download"}.count,1)
        XCTAssertFalse(log.values.contains("/api/v1/download/paths"))
    }
    func testChangedPresetBlocksBeforeIntentOrPost() async {
        let log=ResourceFixtureLog();MockHTTP.handler={r in
            log.append(self.path(r))
            if self.path(r) == "/api/v1/download/paths" { return (200,[:],self.envelope([])) }
            return (200,[:],self.configResponse(r) ?? self.envelope(["download_id":"unexpected"]))
        }
        do { _=try await client().downloadResource(request(directory:directory),authorize:{true},beforeSend:{log.append("intent")});XCTFail() } catch {}
        XCTAssertFalse(log.values.contains("intent"));XCTAssertFalse(log.values.contains("/api/v1/download"))
    }
    func testDisabledSiteBlocksBeforeIntentOrPost() async {
        let log=ResourceFixtureLog();MockHTTP.handler={r in
            log.append(self.path(r))
            if self.path(r) == "/api/v1/site" { return (200,[:],self.envelope([["id":1,"name":"测试站点","is_active":false]])) }
            return (200,[:],self.configResponse(r) ?? self.envelope(["download_id":"unexpected"]))
        }
        do { _=try await client().downloadResource(request(),authorize:{true},beforeSend:{log.append("intent")});XCTFail() } catch {}
        XCTAssertEqual(log.values,["/api/v1/site"])
    }
    func testAuthorizationRevokedAfterIntentPreventsPostButPreservesUnknownIntent() async {
        let log=ResourceFixtureLog();MockHTTP.handler={r in log.append(self.path(r));return (200,[:],self.configResponse(r) ?? self.envelope(["download_id":"unexpected"]))}
        do { _=try await client().downloadResource(request(),authorize:{!log.values.contains("intent")},beforeSend:{log.append("intent")});XCTFail() } catch {}
        XCTAssertTrue(log.values.contains("intent"));XCTAssertFalse(log.values.contains("/api/v1/download"))
    }
    func testUnknownDownloadResultIsNeverRetried() async {
        let log=ResourceFixtureLog();MockHTTP.handler={r in
            if let data=self.configResponse(r) { return (200,[:],data) }
            log.append("post");throw URLError(.networkConnectionLost)
        }
        do { _=try await client().downloadResource(request(),authorize:{true},beforeSend:{log.append("intent")});XCTFail() } catch {}
        XCTAssertEqual(log.values,["intent","post"])
    }
    func testHTTPSuccessWithoutBusinessDownloadIDIsNotSuccess() async {
        MockHTTP.handler={r in if let data=self.configResponse(r) { return (200,[:],data) };return (200,[:],self.envelope([:])) }
        do { _=try await client().downloadResource(request(),authorize:{true},beforeSend:{});XCTFail() } catch {}
    }
    func testLedgerSurvivesRelaunchAndContainsNoRestrictedResourceURL() throws {
        let name="ResourceLedger."+UUID().uuidString,defaults=UserDefaults(suiteName:name)!;defer { defaults.removePersistentDomain(forName:name) }
        let ledger=ResourceDownloadLedger(defaults:defaults),profile=ServiceProfile(kind:.moviepilot,baseURL:base,username:"fixture"),target=ServiceProfile(kind:.qb1,baseURL:"http://192.168.1.100:8085",username:"fixture")
        let key=ledger.key(profile:profile,request:request(),target:target);try ledger.prepare(key)
        let reopened=ResourceDownloadLedger(defaults:UserDefaults(suiteName:name)!)
        XCTAssertNotNil(try reopened.record(key));XCTAssertThrowsError(try reopened.prepare(key))
        let raw=String(data:defaults.data(forKey:"resourceDownloadIntents.v1")!,encoding:.utf8)!
        XCTAssertFalse(raw.contains("fixture-secret"));XCTAssertFalse(raw.contains("tracker.example"));XCTAssertFalse(raw.contains("fixture-only-cookie"))
        try reopened.confirm(key,id:"fixturehash");XCTAssertEqual(try reopened.record(key)?.confirmedDownloadID,"fixturehash")
    }
    func testLedgerDifferentDestinationAndAccountStayDistinctButSignedURLDoesNot() {
        let name="ResourceLedger."+UUID().uuidString,defaults=UserDefaults(suiteName:name)!;defer { defaults.removePersistentDomain(forName:name) }
        let ledger=ResourceDownloadLedger(defaults:defaults),profile=ServiceProfile(kind:.moviepilot,baseURL:base,username:"fixture"),target=ServiceProfile(kind:.qb1,baseURL:"http://192.168.1.100:8085",username:"fixture")
        let original=ledger.key(profile:profile,request:request(),target:target)
        var changed=request();changed.item=MPResourceParser.item(row(enclosure:"https://tracker.example/download.php?id=345&token=new"))!
        XCTAssertEqual(original,ledger.key(profile:profile,request:changed,target:target))
        XCTAssertNotEqual(original,ledger.key(profile:profile,request:request(directory:directory),target:target))
        var other=target;other.kind = .qb2
        XCTAssertNotEqual(original,ledger.key(profile:profile,request:request(),target:other))
        var otherMP=profile;otherMP.username="another"
        XCTAssertNotEqual(original,ledger.key(profile:otherMP,request:request(),target:target))
    }
    func testPendingAndConfirmedResourceCannotBypassIntentByChangingDestination() throws {
        let name="ResourceLedger."+UUID().uuidString,defaults=UserDefaults(suiteName:name)!;defer { defaults.removePersistentDomain(forName:name) }
        let ledger=ResourceDownloadLedger(defaults:defaults),profile=ServiceProfile(kind:.moviepilot,baseURL:base,username:"fixture"),target=ServiceProfile(kind:.qb1,baseURL:"http://192.168.1.100:8085",username:"fixture")
        let original=ledger.key(profile:profile,request:request(),target:target)
        let differentDirectory=ledger.key(profile:profile,request:request(directory:directory),target:target)
        var other=target;other.kind = .qb2;other.baseURL="http://192.168.1.100:8086"
        let differentTarget=ledger.key(profile:profile,request:request(),target:other)
        try ledger.prepare(original)
        for key in [differentDirectory,differentTarget] {
            XCTAssertNotNil(try ledger.record(key));XCTAssertThrowsError(try ledger.prepare(key))
        }
        try ledger.confirm(original,id:"fixturehash")
        XCTAssertEqual(try ledger.record(differentTarget)?.confirmedDownloadID,"fixturehash")
        XCTAssertThrowsError(try ledger.prepare(differentDirectory))
    }
    func testCorruptLedgerFailsClosedWithoutReplacingEvidence() {
        let name="ResourceLedger."+UUID().uuidString,defaults=UserDefaults(suiteName:name)!;defer { defaults.removePersistentDomain(forName:name) }
        defaults.set("corrupted",forKey:"resourceDownloadIntents.v1")
        let ledger=ResourceDownloadLedger(defaults:defaults)
        XCTAssertThrowsError(try ledger.record("key"));XCTAssertThrowsError(try ledger.prepare("key"));XCTAssertThrowsError(try ledger.confirm("key",id:"hash"))
        XCTAssertEqual(defaults.string(forKey:"resourceDownloadIntents.v1"),"corrupted")
    }
}
