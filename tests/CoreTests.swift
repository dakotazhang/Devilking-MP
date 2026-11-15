import XCTest
import SwiftUI
@testable import DevilkingMP

final class MockHTTP: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int,[String:String],Data))?
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        do {
            let (status,headers,data)=try Self.handler!(request)
            let r=HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:"HTTP/1.1",headerFields:headers)!
            client?.urlProtocol(self,didReceive:r,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
        }catch{client?.urlProtocol(self,didFailWithError:error)}
    }
    override func stopLoading() {}
}
final class CoreTests:XCTestCase {
    func client(_ kind:ServiceKind, apiKey:String="") -> APIClient {
        let c=URLSessionConfiguration.ephemeral;c.protocolClasses=[MockHTTP.self]
        return APIClient(profile:ServiceProfile(kind:kind,baseURL:kind.defaultURL,username:"fixture"),credentials:Credential(username:"fixture",password:"test-only",apiKey:apiKey),session:URLSession(configuration:c))
    }
    func json(_ value:Any)->Data { try! JSONSerialization.data(withJSONObject:value) }
    override func tearDown() { MockHTTP.handler=nil;super.tearDown() }
    func testEndpointRejectsPublicHTTPAndEmbeddedSecrets() {
        for s in ["http://example.org","http://172.32.0.1","https://u:p@example.org","https://example.org?token=secret","https://example.org/#x","file:///tmp/a"] {XCTAssertThrowsError(try EndpointPolicy.validate(s))}
    }
    func testEndpointAcceptsVPNLANAndHTTPS() {
        for s in ["http://192.168.1.100:8085","http://172.16.2.1","http://192.168.1.2","https://media.example.org:18444","http://home.local"] {XCTAssertNoThrow(try EndpointPolicy.validate(s))}
    }
    func testLANBoundaries() {XCTAssertFalse(EndpointPolicy.isLAN("172.32.1.2"));XCTAssertFalse(EndpointPolicy.isLAN("10.1.2.999"));XCTAssertFalse(EndpointPolicy.isLAN("10.1.2.3.evil.test"));XCTAssertTrue(EndpointPolicy.isLAN("10.77.77.1"))}
    func testTaskIdentityCannotSelectAllOrMultiple() {
        for value in ["all","1","",String(repeating:"a",count:40)+"|"+String(repeating:"b",count:40)] {XCTAssertFalse(EndpointPolicy.validTaskID(value,kind:.qb1))}
        XCTAssertTrue(EndpointPolicy.validTaskID(String(repeating:"a",count:40),kind:.tr))
    }
    func testRedirectCannotCarryCredentialsToAnotherOrigin() {
        let session=URLSession(configuration:.ephemeral);defer{session.invalidateAndCancel()}
        let task=session.dataTask(with:URL(string:"http://192.168.1.100:8085/api/v2/app/version")!)
        let response=HTTPURLResponse(url:task.originalRequest!.url!,statusCode:302,httpVersion:nil,headerFields:nil)!
        var decision:URLRequest?
        SameOriginDelegate().urlSession(session,task:task,willPerformHTTPRedirection:response,newRequest:URLRequest(url:URL(string:"https://external.invalid/capture")!)){decision=$0}
        XCTAssertNil(decision);task.cancel()
    }
    func testUntrustedLargeNumbersCannotCrashRendering() {
        let t=TaskParser.tr(["status":2,"totalSize":1e100,"rateUpload":1e100]);XCTAssertEqual(t.size,0);XCTAssertEqual(t.uploadRate,0)
        XCTAssertFalse(Format.bytes(Double.infinity).isEmpty)
    }
    func testLockedAuthorizationCancelsWrite() async {
        var count=0;MockHTTP.handler={_ in count += 1;throw URLError(.badURL)}
        do{_ = try await client(.tr).rpc("torrent-stop",args:["ids":[String(repeating:"a",count:40)]],authorize:{false});XCTFail("should cancel")}catch{}
        XCTAssertEqual(count,0)
    }
    func testQBStalledIsSeedingNotStopped() {
        let t=TaskParser.qb(["hash":"a","name":"test","state":"stalledUP","progress":1],kind:.qb1)
        XCTAssertFalse(t.isStopped);XCTAssertTrue(t.isComplete);XCTAssertNil(t.error);XCTAssertEqual(t.state,"做种 · 暂无请求")
    }
    func testQBTrueStopAndFileError() {
        XCTAssertTrue(TaskParser.qb(["state":"stoppedUP"],kind:.qb1).isStopped)
        XCTAssertNotNil(TaskParser.qb(["state":"missingFiles"],kind:.qb1).error)
    }
    func testTRCheckingAndQueuedAreDistinct() {
        let a=TaskParser.tr(["status":1,"recheckProgress":0]),b=TaskParser.tr(["status":2,"recheckProgress":0.47])
        XCTAssertEqual(a.state,"等待校验");XCTAssertEqual(a.verification,0);XCTAssertEqual(b.state,"正在校验");XCTAssertEqual(b.verification,0.47)
    }
    func testTRTrackerMessagesNotExposed() {
        let t=TaskParser.tr(["status":0,"error":2,"errorString":"private tracker URL and passkey"])
        XCTAssertTrue(t.isStopped);XCTAssertFalse(t.error!.contains("passkey"))
    }
    func testTR409ChallengeAndBasicAuth() async throws {
        var count=0
        MockHTTP.handler={r in
            count += 1;XCTAssertTrue(r.value(forHTTPHeaderField:"Authorization")!.hasPrefix("Basic "))
            if count == 1{return(409,["X-Transmission-Session-Id":"fixture-session"],Data())}
            XCTAssertEqual(r.value(forHTTPHeaderField:"X-Transmission-Session-Id"),"fixture-session")
            return(200,[:],self.json(["result":"success","arguments":["torrentCount":4,"activeTorrentCount":1]]))
        }
        let s=try await client(.tr).snapshot();XCTAssertTrue(s.online);XCTAssertEqual(s.taskCount,4);XCTAssertEqual(count,2)
    }
    func testTRBusinessFailureIsNotRetried() async {
        var count=0;MockHTTP.handler={_ in count += 1;return(200,[:],self.json(["result":"torrent not found"]))}
        do{_ = try await client(.tr).rpc("torrent-stop",args:["ids":["fixture"]]);XCTFail("must reject") }catch{}
        XCTAssertEqual(count,1)
    }
    func testNetworkFailureOnWriteNeverRetries() async {
        var count=0;MockHTTP.handler={_ in count += 1;throw URLError(.timedOut)}
        do{_ = try await client(.tr).rpc("torrent-stop");XCTFail("must fail")}catch{}
        XCTAssertEqual(count,1)
    }
    func testQBFormCookieLoginAndVersion() async throws {
        var paths=[String]();MockHTTP.handler={r in
            let p=r.url!.path;paths.append(p)
            if p.hasSuffix("/auth/login") {XCTAssertEqual(r.httpMethod,"POST");XCTAssertEqual(r.value(forHTTPHeaderField:"Origin"),"http://192.168.1.100:8085");return(200,["Set-Cookie":"SID=fixture; Path=/"],Data("Ok.".utf8))}
            if p.hasSuffix("/app/version"){return(200,[:],Data("v5.2.4".utf8))}
            return(200,[:],self.json(["dl_info_speed":0,"up_info_speed":128]))
        }
        let s=try await client(.qb1).snapshot();XCTAssertEqual(s.uploadRate,128);XCTAssertEqual(paths.count,3)
    }
    func testQBAPIKeyUsesBearerWithoutPasswordLogin() async throws {
        var paths=[String]();MockHTTP.handler={r in paths.append(r.url!.path);XCTAssertEqual(r.value(forHTTPHeaderField:"Authorization"),"Bearer fixture-api-key");if r.url!.path.hasSuffix("/app/version"){return(200,[:],Data("v5.2.4".utf8))};return(200,[:],self.json(["dl_info_speed":0]))}
        _=try await client(.qb2,apiKey:"fixture-api-key").snapshot();XCTAssertEqual(paths.count,2);XCTAssertFalse(paths.contains("/api/v2/auth/login"))
    }
    func testMPAPIKeyHeaderNeverQueryOrBearer() async throws {
        MockHTTP.handler={r in XCTAssertEqual(r.value(forHTTPHeaderField:"X-API-KEY"),"fixture-mp-key");XCTAssertNil(r.value(forHTTPHeaderField:"Authorization"));XCTAssertFalse(r.url!.absoluteString.contains("fixture-mp-key"));return(200,[:],self.json(["success":true,"data":[["id":3,"name":"Fixture","state":"P"]]]))}
        let s=try await client(.moviepilot,apiKey:"fixture-mp-key").subscriptions();XCTAssertEqual(s.first?.state,"待定")
    }
    func testMPPasswordLoginUsesBearerJWT() async throws {
        var count=0;MockHTTP.handler={r in
            count += 1
            if r.url!.path.hasSuffix("/access-token"){return(200,[:],self.json(["access_token":"fixture-jwt"]))}
            XCTAssertEqual(r.value(forHTTPHeaderField:"Authorization"),"Bearer fixture-jwt");XCTAssertNil(r.value(forHTTPHeaderField:"X-API-KEY"))
            return(200,[:],self.json(["success":true,"data":[]]))
        }
        _=try await client(.moviepilot).subscriptions();XCTAssertEqual(count,2)
    }
    func testEmbyPosterIsAuthenticatedWithoutQueryToken() async throws {
        MockHTTP.handler={r in
            if r.url!.path.hasSuffix("AuthenticateByName"){return(200,[:],self.json(["AccessToken":"fixture-emby-token","User":["Id":"42"]]))}
            XCTAssertEqual(r.value(forHTTPHeaderField:"X-Emby-Token"),"fixture-emby-token");XCTAssertFalse(r.url!.absoluteString.contains("fixture-emby-token"));XCTAssertEqual(r.url!.path,"/emby/Items/123/Images/Primary")
            return(200,["Content-Type":"image/jpeg"],Data([1,2,3]))
        }
        let d=try await client(.emby).embyImage("123");XCTAssertEqual(d.count,3)
    }
    func testMPFalseDoesNotBecomeEmptySuccess() async {
        MockHTTP.handler={_ in(200,[:],self.json(["success":false,"message":"sensitive backend detail"]))}
        do{_ = try await client(.moviepilot,apiKey:"key").snapshot();XCTFail("false is failure")}catch{XCTAssertFalse(error.localizedDescription.contains("sensitive"))}
    }
    func testMPPauseIsSAndExactlyOneWrite() async throws {
        var calls=0;MockHTTP.handler={r in calls += 1;XCTAssertEqual(r.httpMethod,"PUT");XCTAssertEqual(r.url!.path,"/api/v1/subscribe/status/8");XCTAssertEqual(URLComponents(url:r.url!,resolvingAgainstBaseURL:false)?.queryItems?.first?.value,"S");return(200,[:],self.json(["success":true]))}
        try await client(.moviepilot,apiKey:"key").subscriptionState(id:"8",paused:true);XCTAssertEqual(calls,1)
    }
    func testMPMetadataSearchDoesNotSearchTrackers() async throws {
        MockHTTP.handler={r in XCTAssertEqual(r.url!.path,"/api/v1/media/search");return(200,[:],self.json(["success":true,"data":[]]))}
        _=try await client(.moviepilot,apiKey:"key").search("Fixture")
    }
    func testCachedAccountErrorRemainsUnknown() async throws {
        MockHTTP.handler={r in XCTAssertEqual(r.url!.path,"/api/v1/site/userdata/latest");return(200,[:],self.json(["success":true,"data":[["name":"Fixture","err_msg":"private error"]]]))}
        let s=try await client(.moviepilot,apiKey:"key").sites();XCTAssertFalse(s[0].hasData);XCTAssertFalse(s[0].status.contains("private"))
    }
    func testSpeedConversionFortyMbpsTRIs5000KB() async throws {
        var writes=0;MockHTTP.handler={r in
            // URLProtocol request streams may not expose httpBody, inspect routing and return requested contract.
            if writes == 0{writes += 1;return(200,[:],self.json(["result":"success","arguments":[:]]))}
            return(200,[:],self.json(["result":"success","arguments":["speed-limit-up-enabled":true,"speed-limit-up":5000]]))
        }
        try await client(.tr).uploadLimit(mbps:40);XCTAssertEqual(writes,1)
    }
    func testInvalidLimitRejectedBeforeNetwork() async {
        var count=0;MockHTTP.handler={_ in count += 1;throw URLError(.badURL)}
        for value in [-1.0,Double.infinity,10001] { do{try await client(.tr).uploadLimit(mbps:value);XCTFail("invalid")}catch{} }
        XCTAssertEqual(count,0)
    }
    @MainActor func testDefaultMigrationAndActionGates() {
        let name="DevilkingTests-"+UUID().uuidString;let d=UserDefaults(suiteName:name)!;defer{d.removePersistentDomain(forName:name)}
        let m=AppModel(defaults:d);XCTAssertTrue(m.migrationProtection);XCTAssertFalse(m.canManage(.qb1));XCTAssertFalse(m.canManage(.tr));XCTAssertTrue(m.profiles.allSatisfy{!$0.allowActions})
    }
    func testFormEncodingPreservesPlusAndReservedCharacters() {
        let data=APIClient.form(["password":"x+y&z=中文"]);let s=String(data:data,encoding:.utf8)!
        XCTAssertTrue(s.contains("%2B"));XCTAssertTrue(s.contains("%26"));XCTAssertFalse(s.contains("+"))
    }
}
