import XCTest
import Foundation
import Combine
@testable import DevilkingMP

@MainActor private final class PerformanceVault {
    var values:[ServiceID:Credential]=[:]
    var reads=0
    var writes=0
    var failWrites=Set<Int>()
    var failDeletes=false
    var removeOnRead:Int?
    func read(_ id:ServiceID)->Credential {
        reads += 1
        if removeOnRead == reads {values[id]=nil}
        return values[id] ?? Credential()
    }
    func write(_ value:Credential,id:ServiceID)throws {
        writes += 1
        if failWrites.contains(writes) {throw AppError.message("Synthetic write failure")}
        values[id]=value
    }
    func delete(_ id:ServiceID)throws {
        if failDeletes {throw AppError.message("Synthetic delete failure")}
        values[id]=nil
    }
}

final class TabPerformanceCoreTests:XCTestCase {
    private func defaults()->UserDefaults {UserDefaults(suiteName:"PocketRem-Performance-"+UUID().uuidString)!}
    @MainActor private func make(_ defaults:UserDefaults,vault:PerformanceVault,
                                kinds:[ServiceID]=[.qb1,.qb2,.tr],
                                factory:((ServiceProfile,Credential)->APIClient)?=nil)throws->AppModel {
        let profiles=kinds.map{ServiceProfile(kind:$0,baseURL:"https://"+$0.rawValue.replacingOccurrences(of:":",with:"-")+".example",username:"fixture",allowActions:true,migrationProtected:false)}
        for id in kinds {vault.values[id]=Credential(username:"fixture",password:"synthetic-only")}
        try ConnectionProfileStore.save(profiles,defaults:defaults)
        return AppModel(defaults:defaults,credentialReader:{vault.read($0)},
            credentialWriter:{try vault.write($0,id:$1)},credentialDeleter:{try vault.delete($0)},
            clientFactory:factory ?? {APIClient(profile:$0,credentials:$1)})
    }

    @MainActor func testTenThousandRenderPredicatesDoNotReadKeychainAgain() throws {
        let d=defaults(),vault=PerformanceVault(),model=try make(d,vault:vault)
        model.readOnlyMode=false;model.migrationProtection=false
        let initial=vault.reads
        XCTAssertEqual(initial,3)
        for _ in 0..<10_000 {
            XCTAssertTrue(model.isConfigured(.tr))
            XCTAssertTrue(model.hasSavedCredentials(.qb1))
            XCTAssertTrue(model.canManage(.qb2))
        }
        XCTAssertEqual(vault.reads,initial,"Rendering must not synchronously query Security.framework per predicate")
    }

    @MainActor func testFiveThousandTaskScopeQueriesDoNotScaleVaultReadsWithRows() throws {
        let d=defaults(),vault=PerformanceVault(),model=try make(d,vault:vault)
        let rows=UITestFixtures.largeTasks(.qb1)+UITestFixtures.largeTasks(.qb2)+UITestFixtures.largeTasks(.tr)
        XCTAssertEqual(rows.count,5000)
        model.tasks=rows
        let initial=vault.reads
        var matched=0
        for task in model.tasks {
            let configured=model.visibleDownloaderProfiles.filter{model.isConfigured($0.kind)}.map(\.kind)
            if configured.contains(task.kind) {matched += 1}
        }
        XCTAssertEqual(matched,5000)
        XCTAssertEqual(vault.reads,initial,"Even a repeated row scope query cannot reach the Keychain")
    }

    @MainActor func testLargeFixtureIdentityIsStableAndContainsMixedReadOnlyStates() {
        for (kind,count) in [(ServiceID.qb1,1200),(.qb2,300),(.tr,3500)] {
            let first=UITestFixtures.largeTasks(kind),second=UITestFixtures.largeTasks(kind)
            XCTAssertEqual(first.count,count)
            XCTAssertEqual(first.map(\.qualifiedID),second.map(\.qualifiedID))
            XCTAssertEqual(Set(first.map(\.qualifiedID)).count,count)
            XCTAssertEqual(first.first?.id,"large-"+kind.rawValue+"-00000")
            XCTAssertTrue(first.allSatisfy{$0.name.hasPrefix("批量合成") && $0.path == "/synthetic/media"})
            XCTAssertEqual(first.first?.rawState,kind.isTR ? "6":"stalledUP")
            XCTAssertGreaterThan(Set(first.map(\.rawState)).count,3)
        }
    }

    @MainActor func testDisplayRenameAndGroupChangesDoNotReadVault() throws {
        let d=defaults(),vault=PerformanceVault(),model=try make(d,vault:vault)
        let before=vault.reads
        try model.renameConnection(.tr,name:"Archive")
        _=try model.preferences.saveGroup(name:"Household",memberIDs:[.qb1,.tr])
        for _ in 0..<100 { _=model.visibleDownloaderProfiles;_=model.isConfigured(.tr) }
        XCTAssertEqual(vault.reads,before)
        XCTAssertTrue(model.isConfigured(.tr))
    }

    @MainActor func testCredentialClearUpdatesPresenceWithoutReadsFromSubsequentPaint() throws {
        let d=defaults(),vault=PerformanceVault(),model=try make(d,vault:vault)
        try model.clearCredentials(.tr)
        let afterClear=vault.reads
        for _ in 0..<100 {XCTAssertFalse(model.hasSavedCredentials(.tr));XCTAssertFalse(model.isConfigured(.tr))}
        XCTAssertEqual(vault.reads,afterClear)
        XCTAssertTrue(vault.values[.tr]?.isEmpty ?? true)
        XCTAssertFalse(model.profile(.tr).allowActions)
    }

    @MainActor func testFailedDeleteRetainsPresenceAndOriginalPermission() throws {
        let d=defaults(),vault=PerformanceVault(),model=try make(d,vault:vault)
        vault.failDeletes=true
        XCTAssertThrowsError(try model.clearCredentials(.tr))
        let after=vault.reads
        XCTAssertTrue(model.hasSavedCredentials(.tr));XCTAssertTrue(model.isConfigured(.tr))
        XCTAssertTrue(model.profile(.tr).allowActions)
        XCTAssertEqual(vault.reads,after)
    }

    @MainActor func testFailedWriteDoesNotCreateCachedCredentialPresence() throws {
        let d=defaults(),vault=PerformanceVault(),model=try make(d,vault:vault)
        let id=ServiceID.make(.transmission)
        vault.failWrites=[vault.writes+1]
        XCTAssertThrowsError(try model.saveConnection(id,baseURL:"https://new.example",username:"fixture",password:"synthetic-new",apiKey:"",allowActions:false))
        let after=vault.reads
        XCTAssertFalse(model.hasSavedCredentials(id));XCTAssertFalse(model.isConfigured(id))
        XCTAssertFalse(model.profiles.contains{$0.kind == id})
        XCTAssertEqual(vault.reads,after)
    }

    @MainActor func testExternalCredentialRemovalIsRecheckedBeforeAnyActionOrAPIClient() async throws {
        let d=defaults(),vault=PerformanceVault()
        var factories=0
        let model=try make(d,vault:vault,kinds:[.tr],factory:{profile,credential in
            factories += 1;return APIClient(profile:profile,credentials:credential)
        })
        model.readOnlyMode=false;model.migrationProtection=false
        XCTAssertTrue(model.canManage(.tr))
        vault.values[.tr]=nil
        let before=vault.reads
        await model.setUploadLimit(.tr,mbps:40)
        XCTAssertEqual(vault.reads,before+1)
        XCTAssertEqual(factories,0,"Cached rendering presence must never authorize a network operation")
        XCTAssertFalse(model.hasSavedCredentials(.tr))
        XCTAssertFalse(model.canManage(.tr))
    }

    @MainActor func testExplicitLifecyclePresenceRefreshFindsExternalRemovalWithoutNetwork() throws {
        let d=defaults(),vault=PerformanceVault(),model=try make(d,vault:vault)
        vault.values[.tr]=nil
        let before=vault.reads
        model.refreshCredentialAvailability()
        XCTAssertEqual(vault.reads,before+3)
        XCTAssertFalse(model.isConfigured(.tr));XCTAssertTrue(model.isConfigured(.qb1))
        let after=vault.reads
        for _ in 0..<1000 {_=model.isConfigured(.tr)}
        XCTAssertEqual(vault.reads,after)
    }

    @MainActor func testImportRollbackRestoresCachedPresenceAndOriginalConfiguration() throws {
        let d=defaults(),vault=PerformanceVault(),model=try make(d,vault:vault,kinds:[.tr])
        let newID=ServiceID.make(.qbittorrent)
        let oldBytes=d.data(forKey:ConnectionProfileStore.storageKey),oldPassword=vault.values[.tr]?.password
        vault.failWrites=[vault.writes+2]
        let input:[String:Any]=["version":2,"services":[
            ["kind":"tr","type":"transmission","name":"Replacement","baseURL":"https://tr.example","username":"fixture","password":"replacement-only"],
            ["kind":newID.rawValue,"type":"qbittorrent","name":"New","baseURL":"https://new.example","username":"fixture","password":"synthetic-only"]
        ]]
        let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".dkmp")
        try JSONSerialization.data(withJSONObject:input).write(to:file)
        defer {try? FileManager.default.removeItem(at:file)}
        XCTAssertThrowsError(try model.importProfile(file))
        XCTAssertEqual(vault.values[.tr]?.password,oldPassword)
        XCTAssertEqual(d.data(forKey:ConnectionProfileStore.storageKey),oldBytes)
        XCTAssertEqual(model.profiles.map(\.kind),[.tr])
        let after=vault.reads
        for _ in 0..<100 {
            XCTAssertTrue(model.hasSavedCredentials(.tr));XCTAssertTrue(model.isConfigured(.tr))
            XCTAssertFalse(model.hasSavedCredentials(newID));XCTAssertFalse(model.isConfigured(newID))
        }
        XCTAssertEqual(vault.reads,after)
    }

    @MainActor func testCredentialRevokedAfterSessionChallengeCannotAuthorizeSecondSend() async throws {
        let d=defaults(),vault=PerformanceVault()
        let configuration=URLSessionConfiguration.ephemeral;configuration.protocolClasses=[MockHTTP.self]
        let session=URLSession(configuration:configuration)
        defer {MockHTTP.handler=nil;session.invalidateAndCancel()}
        let model=try make(d,vault:vault,kinds:[.tr],factory:{APIClient(profile:$0,credentials:$1,session:session)})
        model.readOnlyMode=false;model.migrationProtection=false
        // guardAction, client and the first send each read the real vault. The
        // fourth read occurs after TR's 409 challenge, immediately before send.
        let before=vault.reads;vault.removeOnRead=before+4
        var requests=0
        MockHTTP.handler={request in
            requests += 1
            return (409,["X-Transmission-Session-Id":"synthetic-session"],Data())
        }
        await model.setUploadLimit(.tr,mbps:40)
        XCTAssertEqual(requests,1,"A successful session-set must not follow the unauthenticated challenge after revocation")
        XCTAssertEqual(vault.reads,before+4)
        XCTAssertFalse(model.hasSavedCredentials(.tr));XCTAssertFalse(model.canManage(.tr))
        XCTAssertFalse(model.readOnlyMode);XCTAssertTrue(model.profile(.tr).allowActions)
    }

    @MainActor func testOneTaskReadPublishesOneReplacementAndKeepsOtherInstanceRows() async throws {
        let d=defaults(),vault=PerformanceVault()
        let configuration=URLSessionConfiguration.ephemeral;configuration.protocolClasses=[MockHTTP.self]
        let session=URLSession(configuration:configuration)
        defer {MockHTTP.handler=nil;session.invalidateAndCancel()}
        let model=try make(d,vault:vault,factory:{APIClient(profile:$0,credentials:$1,session:session)})
        let other=TaskParser.qb(["hash":String(repeating:"b",count:40),"name":"Other instance","state":"stalledUP","progress":1],kind:.qb1)
        model.tasks=[other]
        let rows=(0..<3500).map {index -> [String:Any] in
            ["hashString":String(format:"%040x",index+1),"name":"Synthetic TR \(index)","status":6,"percentDone":1.0,
             "error":0,"totalSize":32_000_000_000,"leftUntilDone":0,"rateDownload":0,"rateUpload":0,"uploadRatio":1.0,
             "downloadDir":"/synthetic/media","labels":["keep"],"recheckProgress":0]
        }
        let reply=try JSONSerialization.data(withJSONObject:["result":"success","arguments":["torrents":rows]])
        var requests=0
        MockHTTP.handler={request in
            requests += 1;XCTAssertEqual(request.url?.path,"/transmission/rpc")
            return (200,[:],reply)
        }
        var publications=0
        let token=model.$tasks.dropFirst().sink{_ in publications += 1}
        let loaded=await model.loadTasks(.tr)
        withExtendedLifetime(token) {}
        XCTAssertTrue(loaded);XCTAssertEqual(requests,1)
        XCTAssertEqual(publications,1,"removeAll + append previously published two large arrays")
        XCTAssertEqual(model.tasks.count,3501)
        XCTAssertEqual(model.tasks.first?.qualifiedID,other.qualifiedID)
        XCTAssertEqual(model.tasks.filter{$0.kind == .tr}.count,3500)
    }
}
