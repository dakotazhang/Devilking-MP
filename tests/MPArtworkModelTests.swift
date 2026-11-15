import XCTest
import Foundation
@testable import DevilkingMP

private actor ArtworkConcurrencyProbe {
    var active=0
    var peak=0
    func begin() {active+=1;peak=max(peak,active)}
    func end() {active-=1}
}

private final class ModelArtworkState: @unchecked Sendable {
    private let lock=NSLock()
    private var count=0
    private var status=200
    private var hang=false
    func reset(status:Int=200,hang:Bool=false) {lock.lock();defer{lock.unlock()};count=0;self.status=status;self.hang=hang}
    func configure(status:Int=200,hang:Bool=false) {lock.lock();defer{lock.unlock()};self.status=status;self.hang=hang}
    func begin()->(Int,Bool) {lock.lock();defer{lock.unlock()};count+=1;return(status,hang)}
    func calls()->Int {lock.lock();defer{lock.unlock()};return count}
}
private final class ModelArtworkHTTP:URLProtocol {
    static let state=ModelArtworkState()
    static let png=Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        let (status,hang)=Self.state.begin()
        guard !hang else{return}
        XCTAssertEqual(request.httpMethod,"GET")
        XCTAssertEqual(request.url?.host,"192.168.40.20")
        XCTAssertTrue(request.url?.path.hasSuffix("system/cache/image") == true)
        let response=HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"image/png"])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Self.png)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class MPArtworkModelTests:XCTestCase {
    override func setUp() {super.setUp();ModelArtworkHTTP.state.reset()}

    @MainActor private func model(_ defaults:UserDefaults)->AppModel {
        let config=URLSessionConfiguration.ephemeral
        config.protocolClasses=[ModelArtworkHTTP.self]
        let session=URLSession(configuration:config)
        let model=AppModel(defaults:defaults,credentialReader:{$0 == .moviepilot ? Credential(username:"fixture",password:"",apiKey:"fixture-only") : Credential()},clientFactory:{APIClient(profile:$0,credentials:$1,session:session)},readBudgetSeconds:1)
        model.profiles=[ServiceProfile(kind:.moviepilot,baseURL:"http://192.168.40.20:3000",username:"fixture")]
        return model
    }
    private let poster="https://img1.doubanio.com/view/photo/s_ratio_poster/public/fixture.webp?width=300"

    func testImageReadConcurrencyIsBounded() async throws {
        let gate=MPArtworkReadGate(limit:2),probe=ArtworkConcurrencyProbe()
        try await withThrowingTaskGroup(of:Data.self) {group in
            for _ in 0..<7 {group.addTask {
                try await gate.read {
                    await probe.begin()
                    do {try await Task.sleep(nanoseconds:20_000_000)} catch {await probe.end();throw error}
                    await probe.end()
                    return Data([1])
                }
            }}
            for try await value in group {XCTAssertEqual(value,Data([1]))}
        }
        let peak=await probe.peak
        XCTAssertEqual(peak,2)
    }
    func testCancelledQueuedImageDoesNotLoseTheNextSlot() async throws {
        let gate=MPArtworkReadGate(limit:1)
        let first=Task {try await gate.read {try await Task.sleep(nanoseconds:80_000_000);return Data([1])}}
        try await Task.sleep(nanoseconds:10_000_000)
        let cancelled=Task {try await gate.read {XCTFail("Cancelled queued image must never execute");return Data([2])}}
        try await Task.sleep(nanoseconds:10_000_000)
        cancelled.cancel()
        do {_=try await cancelled.value;XCTFail("Must cancel")} catch {XCTAssertTrue(error is CancellationError)}
        _=try await first.value
        let result=try await ReadBudget.run(seconds:1) {try await gate.read {Data([3])}}
        XCTAssertEqual(result,Data([3]))
    }
    @MainActor func testIdenticalImagesCoalesceAndRefreshClearsPositiveCache() async {
        let suite="ArtworkModel."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        defer{defaults.removePersistentDomain(forName:suite)}
        let model=model(defaults)
        let first=Task{await model.loadMPArtwork(poster)}
        let second=Task{await model.loadMPArtwork(poster)}
        let a=await first.value,b=await second.value
        XCTAssertEqual(a,ModelArtworkHTTP.png);XCTAssertEqual(b,a)
        XCTAssertEqual(ModelArtworkHTTP.state.calls(),1)
        _=await model.loadMPArtwork(poster)
        XCTAssertEqual(ModelArtworkHTTP.state.calls(),1)
        let token=model.mpArtworkRefreshToken
        model.invalidateMPArtwork()
        XCTAssertNotEqual(token,model.mpArtworkRefreshToken)
        _=await model.loadMPArtwork(poster)
        XCTAssertEqual(ModelArtworkHTTP.state.calls(),2)
        XCTAssertTrue(model.readOnlyMode);XCTAssertTrue(model.migrationProtection)
    }
    @MainActor func testFailedImageCanBeRetriedWithoutAnEndlessNegativeCache() async {
        let suite="ArtworkModel."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        defer{defaults.removePersistentDomain(forName:suite)}
        let model=model(defaults)
        ModelArtworkHTTP.state.configure(status:503)
        let first=await model.loadMPArtwork(poster)
        XCTAssertNil(first)
        ModelArtworkHTTP.state.configure()
        let second=await model.loadMPArtwork(poster)
        XCTAssertEqual(second,ModelArtworkHTTP.png)
        XCTAssertEqual(ModelArtworkHTTP.state.calls(),2)
    }
    @MainActor func testExplicitPosterRetryRefetchesOnlyThatImageInsteadOfReusingBadBytes() async {
        let suite="ArtworkModel."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        defer{defaults.removePersistentDomain(forName:suite)}
        let model=model(defaults)
        let other="https://img1.doubanio.com/view/photo/s_ratio_poster/public/other.webp"
        _=await model.loadMPArtwork(poster)
        _=await model.loadMPArtwork(other)
        XCTAssertEqual(ModelArtworkHTTP.state.calls(),2)
        let retried=await model.loadMPArtwork(poster,forceReload:true)
        XCTAssertEqual(retried,ModelArtworkHTTP.png)
        XCTAssertEqual(ModelArtworkHTTP.state.calls(),3)
        _=await model.loadMPArtwork(other)
        XCTAssertEqual(ModelArtworkHTTP.state.calls(),3,"Other visible posters must retain their cache")
    }
    @MainActor func testChangingConnectionCannotReuseThePriorAccountsImageCache() async {
        let suite="ArtworkModel."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        defer{defaults.removePersistentDomain(forName:suite)}
        let model=model(defaults)
        _=await model.loadMPArtwork(poster)
        let epoch=model.resourceConnectionEpoch
        model.disconnect(.moviepilot)
        XCTAssertNotEqual(epoch,model.resourceConnectionEpoch)
        _=await model.loadMPArtwork(poster)
        XCTAssertEqual(ModelArtworkHTTP.state.calls(),2)
    }
    @MainActor func testBackgroundCancelsPendingImageWithoutKeepingStaleBytes() async {
        let suite="ArtworkModel."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        defer{defaults.removePersistentDomain(forName:suite)}
        let model=model(defaults)
        ModelArtworkHTTP.state.configure(hang:true)
        let pending=Task{await model.loadMPArtwork(poster)}
        try? await Task.sleep(nanoseconds:20_000_000)
        model.protectOnBackground()
        let cancelled=await pending.value
        XCTAssertNil(cancelled)
        ModelArtworkHTTP.state.configure()
        let recovered=await model.loadMPArtwork(poster)
        XCTAssertEqual(recovered,ModelArtworkHTTP.png)
    }
}
