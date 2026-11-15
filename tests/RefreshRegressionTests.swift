import XCTest
import Foundation
@testable import DevilkingMP

private final class RefreshHTTPState: @unchecked Sendable {
    private let lock=NSLock()
    private var healthy=false
    private var count=0
    func reset(healthy:Bool=false) { lock.lock();defer{lock.unlock()};self.healthy=healthy;count=0 }
    func read()->(Bool,Int) { lock.lock();defer{lock.unlock()};return (healthy,count) }
    func begin()->Bool { lock.lock();defer{lock.unlock()};count+=1;return healthy }
}
private final class RefreshHTTP:URLProtocol {
    static let state=RefreshHTTPState()
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        guard Self.state.begin() else{return} // Deliberately unresponsive until cancelled.
        let data:Data
        if request.url!.path.hasSuffix("app/version") { data=Data("v5.2.4".utf8) }
        else if request.url!.path.contains("recommend") {
            data=try! JSONSerialization.data(withJSONObject:["success":true,"data":[]])
        } else {
            data=try! JSONSerialization.data(withJSONObject:["full_update":true,"torrents":[:],"server_state":["dl_info_speed":0,"up_info_speed":0,"free_space_on_disk":1000]])
        }
        let response=HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:"HTTP/1.1",headerFields:[:])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class RefreshRegressionTests:XCTestCase {
    override func setUp() { super.setUp();RefreshHTTP.state.reset() }
    private func session()->URLSession {
        let config=URLSessionConfiguration.ephemeral
        config.protocolClasses=[RefreshHTTP.self]
        return URLSession(configuration:config)
    }
    @MainActor private func model(_ defaults:UserDefaults,kind:ServiceKind,budget:TimeInterval=0.12)->AppModel {
        let session=session()
        return AppModel(defaults:defaults,credentialReader: { k in
            k == kind ? Credential(username:"fixture",password:"",apiKey:"fixture-only") : Credential()
        },clientFactory:{ APIClient(profile:$0,credentials:$1,session:session) },readBudgetSeconds:budget)
    }
    func testWholeReadBudgetTerminatesCancellableSlowWork() async {
        let start=Date()
        do {
            let _:Int=try await ReadBudget.run(seconds:0.03) { try await Task.sleep(nanoseconds:3_000_000_000);return 1 }
            XCTFail("Must time out")
        } catch { XCTAssertEqual((error as? URLError)?.code,.timedOut) }
        XCTAssertLessThan(Date().timeIntervalSince(start),1)
    }
    func testReadBudgetPropagatesParentCancellation() async {
        let operation=Task { try await ReadBudget.run(seconds:5) { try await Task.sleep(nanoseconds:5_000_000_000);return 1 } }
        try? await Task.sleep(nanoseconds:20_000_000)
        operation.cancel()
        do { _=try await operation.value;XCTFail("Must cancel") } catch { XCTAssertTrue(error is CancellationError) }
    }
    @MainActor func testOfflineDashboardClearsSpinnerAndManualRefreshCanRecover() async {
        let name="RefreshTest."+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        let model=model(defaults,kind:.qb1)
        await model.refreshDashboard()
        XCTAssertFalse(model.dashboardRefreshing);XCTAssertFalse(model.dashboardManualRefreshing)
        XCTAssertNotNil(model.dashboardSnapshots[.qb1]?.error)
        RefreshHTTP.state.reset(healthy:true)
        await model.refreshDashboard()
        XCTAssertFalse(model.dashboardRefreshing);XCTAssertFalse(model.dashboardManualRefreshing)
        XCTAssertNil(model.dashboardSnapshots[.qb1]?.error)
        XCTAssertEqual(model.dashboardSnapshots[.qb1]?.counts?.total,0)
    }
    @MainActor func testConcurrentRefreshesJoinOneReadRatherThanStartingDuplicates() async {
        let name="RefreshTest."+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        let model=model(defaults,kind:.qb1)
        let first=Task{await model.refreshDashboard(manual:false)}
        try? await Task.sleep(nanoseconds:20_000_000)
        XCTAssertTrue(model.dashboardRefreshing);XCTAssertFalse(model.dashboardManualRefreshing)
        let second=Task{await model.refreshDashboard()}
        await first.value;await second.value
        XCTAssertEqual(RefreshHTTP.state.read().1,1)
        XCTAssertFalse(model.dashboardRefreshing);XCTAssertFalse(model.dashboardManualRefreshing)
    }
    @MainActor func testCancelledDiscoveryCanBeRefreshedAgainWithoutStickyLoading() async {
        let name="RefreshTest."+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        let model=model(defaults,kind:.moviepilot,budget:2)
        let first=Task{await model.loadDiscovery()}
        try? await Task.sleep(nanoseconds:25_000_000)
        model.cancelDiscoveryRefresh()
        await first.value
        XCTAssertFalse(model.discoveryLoading)
        RefreshHTTP.state.reset(healthy:true)
        await model.loadDiscovery()
        XCTAssertFalse(model.discoveryLoading);XCTAssertNil(model.discoveryError)
        XCTAssertEqual(model.discoverySections.count,4);XCTAssertNotNil(model.discoveryUpdatedAt)
    }
    @MainActor func testDiscoveryTimeoutClearsSpinnerAndPreservesPriorContent() async {
        let name="RefreshTest."+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        let model=model(defaults,kind:.moviepilot)
        model.discoverySections=[MPDiscoverySection(id:"cached",title:"上次推荐",subtitle:"",category:.movie,items:[])]
        await model.loadDiscovery()
        XCTAssertFalse(model.discoveryLoading);XCTAssertNotNil(model.discoveryError)
        XCTAssertEqual(model.discoverySections.first?.id,"cached")
    }
    @MainActor func testBindingCannotOverrideReadOnlyOrTargetMigrationProtection() {
        let name="RefreshTest."+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        let model=AppModel(defaults:defaults,credentialReader:{_ in Credential(username:"fixture",password:"test-only",apiKey:"")})
        model.profiles=ServiceKind.allCases.map{ServiceProfile(kind:$0,baseURL:$0.defaultURL,username:"fixture",allowActions:true)}
        let downloader=MPResourceDownloader(id:"Fixture qB",name:"Fixture qB",type:"qbittorrent",targetBaseURL:"http://downloader:8080")
        model.preferences.setBoundDownloaderKind(.qb1,for:downloader.bindingID,baseURL:model.profile(.moviepilot).baseURL)
        XCTAssertFalse(model.canDownloadResource(downloader))
        model.readOnlyMode=false
        XCTAssertFalse(model.canDownloadResource(downloader))
        model.migrationProtection=false
        XCTAssertTrue(model.canDownloadResource(downloader))
        model.preferences.setBoundDownloaderKind(.tr,for:downloader.bindingID,baseURL:model.profile(.moviepilot).baseURL)
        XCTAssertFalse(model.canDownloadResource(downloader))
    }
    @MainActor func testResourceResultFromAnotherConnectionCannotSendAnyRequest() async throws {
        let name="RefreshTest."+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        let session=session()
        let model=AppModel(defaults:defaults,credentialReader:{_ in Credential(username:"fixture",password:"test-only",apiKey:"")},clientFactory:{APIClient(profile:$0,credentials:$1,session:session)})
        model.profiles=ServiceKind.allCases.map{ServiceProfile(kind:$0,baseURL:$0.defaultURL,username:"fixture",allowActions:true)}
        model.readOnlyMode=false;model.migrationProtection=false
        let downloader=try XCTUnwrap(UITestFixtures.resourceDownloaders().first)
        model.preferences.setBoundDownloaderKind(.qb1,for:downloader.bindingID,baseURL:model.profile(.moviepilot).baseURL)
        var item=try XCTUnwrap(UITestFixtures.resourceSearch("星海远航",sites:["1"]).first)
        item.connectionToken=UUID() // A different MP account / connection epoch.
        XCTAssertFalse(model.isCurrentResource(item))
        let sent=await model.downloadResource(MPResourceDownloadRequest(item:item,downloader:downloader))
        XCTAssertFalse(sent)
        XCTAssertEqual(RefreshHTTP.state.read().1,0)
    }
    @MainActor func testBackgroundAndPermissionChangesInvalidateOpenConfirmations() {
        let name="RefreshTest."+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        let model=model(defaults,kind:.moviepilot)
        let first=model.interactionEpoch
        model.readOnlyMode=false
        XCTAssertNotEqual(first,model.interactionEpoch)
        let second=model.interactionEpoch
        model.protectOnBackground()
        XCTAssertNotEqual(second,model.interactionEpoch)
    }
}
