import XCTest
import Foundation
@testable import DevilkingMP

private actor ReadProbe {
    var active=0
    var peak=0
    var executed=0
    func begin(){active += 1;executed += 1;peak=max(active,peak)}
    func end(){active -= 1}
}

final class MultiServerRefreshTests:XCTestCase {
    func testManyDownloaderReadsStayWithinConcurrencyBudget() async throws {
        let gate=DownloaderReadGate(limit:4),probe=ReadProbe()
        try await withThrowingTaskGroup(of:Int.self){group in
            for index in 0..<32 {group.addTask{
                try await gate.read{
                    await probe.begin()
                    do {try await Task.sleep(nanoseconds:10_000_000)}catch{await probe.end();throw error}
                    await probe.end();return index
                }
            }}
            var results=Set<Int>()
            for try await value in group{results.insert(value)}
            XCTAssertEqual(results.count,32)
        }
        let peak=await probe.peak,executed=await probe.executed
        XCTAssertEqual(peak,4);XCTAssertEqual(executed,32)
    }

    func testCancelledWaitingDownloaderNeverRunsAndSlotRemainsUsable() async throws {
        let gate=DownloaderReadGate(limit:1)
        let first=Task{try await gate.read{try await Task.sleep(nanoseconds:80_000_000);return 1}}
        try await Task.sleep(nanoseconds:10_000_000)
        let cancelled=Task{try await gate.read{XCTFail("Cancelled queued read must not reach an endpoint");return 2}}
        try await Task.sleep(nanoseconds:10_000_000);cancelled.cancel()
        do{_=try await cancelled.value;XCTFail("Must cancel")}catch{XCTAssertTrue(error is CancellationError)}
        _=try await first.value
        let next=try await ReadBudget.run(seconds:1){try await gate.read{return 3}}
        XCTAssertEqual(next,3)
    }

    func testAggregateCountsEachInstanceOnceAcrossOverlappingGroups() {
        let a=ServiceID.make(.qbittorrent),b=ServiceID.make(.transmission),now=Date()
        let samples=[a:DashboardSnapshot(kind:a,downloadRate:10,uploadRate:20,counts:DashboardTaskCounts(total:3,seeding:3),updatedAt:now),b:DashboardSnapshot(kind:b,downloadRate:30,uploadRate:40,counts:DashboardTaskCounts(total:5,seeding:5),updatedAt:now)]
        let all=DashboardAggregate(configured:[a,b,a,b],snapshots:samples,now:now)
        XCTAssertEqual(all.configuredCount,2);XCTAssertEqual(all.currentCount,2)
        XCTAssertEqual(all.counts?.total,8);XCTAssertEqual(all.uploadRate,60)
    }

    func testFailedGroupMemberKeepsPartialCoverageInsteadOfClaimingZero() {
        let a=ServiceID.make(.qbittorrent),b=ServiceID.make(.transmission),now=Date()
        let samples=[a:DashboardSnapshot(kind:a,downloadRate:10,uploadRate:20,counts:DashboardTaskCounts(total:3),updatedAt:now),b:DashboardSnapshot.failure(kind:b,previous:nil,error:"Synthetic offline",now:now)]
        let group=DashboardAggregate(configured:[a,b],snapshots:samples,now:now)
        XCTAssertTrue(group.hasPartialCoverage);XCTAssertEqual(group.currentCount,1)
        XCTAssertEqual(group.counts?.total,3);XCTAssertEqual(group.uploadRate,20)
        let offline=DashboardAggregate(configured:[b],snapshots:samples,now:now)
        XCTAssertNil(offline.counts);XCTAssertNil(offline.downloadRate)
    }

    func testEndpointComparisonPreservesProxyPrefixesAndNormalizesDefaultPorts() {
        let tr=ServiceID.make(.transmission),qb=ServiceID.make(.qbittorrent)
        XCTAssertEqual(ConnectionEndpointIdentity.key("https://BOX.example:443/transmission/rpc/",kind:tr),"https://box.example")
        XCTAssertEqual(ConnectionEndpointIdentity.key("https://box.example/tr-north/transmission/web",kind:tr),"https://box.example/tr-north")
        XCTAssertEqual(ConnectionEndpointIdentity.key("https://box.example/transmission-proxy/north/transmission/web",kind:tr),"https://box.example/transmission-proxy/north")
        XCTAssertEqual(ConnectionEndpointIdentity.key("https://BOX.example:443/qb/",kind:qb),"https://box.example/qb")
    }
}
