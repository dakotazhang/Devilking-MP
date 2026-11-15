import XCTest
import Foundation
@testable import DevilkingMP

private final class LifecycleHTTPState: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func reset() { lock.lock(); defer { lock.unlock() }; count = 0 }
    func record() { lock.lock(); defer { lock.unlock() }; count += 1 }
    var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
}
private final class LifecycleHTTP: URLProtocol {
    static let state = LifecycleHTTPState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.state.record()
        let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("synthetic-offline".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@MainActor private final class LifecycleVault {
    var values: [ServiceID: Credential] = [:]
    var writeCount = 0
    var deleteCount = 0
    var failingWrites = Set<Int>()
    var failDeletes = false
    func read(_ id: ServiceID) -> Credential { values[id] ?? Credential() }
    func write(_ credential: Credential, id: ServiceID) throws {
        writeCount += 1
        guard !failingWrites.contains(writeCount) else { throw AppError.message("Synthetic credential write failed") }
        values[id] = credential
    }
    func delete(_ id: ServiceID) throws {
        deleteCount += 1
        guard !failDeletes else { throw AppError.message("Synthetic credential delete failed") }
        values.removeValue(forKey: id)
    }
}

final class MultiServerLifecycleTests: XCTestCase {
    override func setUp() { super.setUp(); LifecycleHTTP.state.reset() }
    private func makeDefaults() -> UserDefaults { UserDefaults(suiteName: "PocketRem-Lifecycle-" + UUID().uuidString)! }
    @MainActor private func makeModel(_ defaults: UserDefaults, vault: LifecycleVault) -> AppModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LifecycleHTTP.self]
        let session = URLSession(configuration: configuration)
        return AppModel(defaults: defaults, credentialReader: { vault.read($0) },
                        credentialWriter: { try vault.write($0, id: $1) },
                        credentialDeleter: { try vault.delete($0) },
                        clientFactory: { APIClient(profile: $0, credentials: $1, session: session) }, readBudgetSeconds: 0.2)
    }
    @MainActor @discardableResult private func add(_ model: AppModel, type: ServiceProtocol = .qbittorrent,
                                                  name: String = "Home", host: String = "https://home.example",
                                                  allowActions: Bool = true, protected: Bool = false) throws -> ServiceID {
        try model.createConnection(protocolKind: type, name: name, baseURL: host, username: "fixture",
                                   password: "fixture-only-password", apiKey: "", allowActions: allowActions,
                                   migrationProtected: protected)
    }
    private func task(_ id: ServiceID) -> TorrentTask {
        TaskParser.qb(["hash": String(repeating: "a", count: 40), "name": "Synthetic task", "state": "stalledUP", "progress": 1], kind: id)
    }
    private func writeImport(_ object: [String: Any]) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("PocketRem-Lifecycle-" + UUID().uuidString + ".json")
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        return file
    }
    private func same(_ first: Credential, _ second: Credential, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(first.username, second.username, file: file, line: line)
        XCTAssertEqual(first.password, second.password, file: file, line: line)
        XCTAssertEqual(first.apiKey, second.apiKey, file: file, line: line)
    }

    @MainActor func testSuspendRetainsCredentialsPermissionsGroupAndMPBinding() throws {
        let defaults = makeDefaults(), vault = LifecycleVault(), model = makeModel(defaults, vault: vault)
        let id = try add(model)
        let group = try model.preferences.saveGroup(name: "Home", memberIDs: [id])
        model.preferences.setBoundDownloaderKind(id, for: "remote-main", baseURL: "https://mp.example")
        let before = vault.read(id)
        model.disconnect(id)
        XCTAssertFalse(model.profile(id).enabled)
        XCTAssertTrue(model.profile(id).allowActions)
        XCTAssertTrue(model.hasSavedCredentials(id))
        XCTAssertFalse(model.isConfigured(id)); XCTAssertFalse(model.canManage(id))
        same(vault.read(id), before)
        XCTAssertEqual(model.preferences.serverGroups.first { $0.id == group }?.memberIDs, [id])
        XCTAssertEqual(model.preferences.boundDownloaderKind(for: "remote-main", baseURL: "https://mp.example"), id)
        XCTAssertEqual(vault.deleteCount, 0); XCTAssertEqual(LifecycleHTTP.state.requests, 0)
    }

    @MainActor func testReconnectIsLocalAndDoesNotBypassReadOnlyOrContactServer() async throws {
        let defaults = makeDefaults(), vault = LifecycleVault(), model = makeModel(defaults, vault: vault)
        let id = try add(model)
        model.disconnect(id)
        try model.setConnectionEnabled(id, enabled: true)
        XCTAssertTrue(model.isConfigured(id)); XCTAssertTrue(model.readOnlyMode)
        XCTAssertFalse(model.canManage(id))
        await model.performTask(task(id), start: false)
        await model.setUploadLimit(id, mbps: 40)
        XCTAssertEqual(LifecycleHTTP.state.requests, 0)
        XCTAssertEqual(vault.writeCount, 1)
    }

    @MainActor func testClearingCredentialsKeepsConnectionAndClassificationButRemovesPermission() throws {
        let defaults = makeDefaults(), vault = LifecycleVault(), model = makeModel(defaults, vault: vault)
        let id = try add(model)
        let group = try model.preferences.saveGroup(name: "Home", memberIDs: [id])
        model.preferences.setBoundDownloaderKind(id, for: "main", baseURL: "https://mp.example")
        try model.clearCredentials(id)
        XCTAssertEqual(model.profiles.map(\.id), [id])
        XCTAssertFalse(model.profile(id).enabled); XCTAssertFalse(model.profile(id).allowActions)
        XCTAssertFalse(model.hasSavedCredentials(id)); XCTAssertEqual(vault.deleteCount, 1)
        XCTAssertEqual(model.preferences.serverGroups.first { $0.id == group }?.memberIDs, [id])
        XCTAssertEqual(model.preferences.boundDownloaderKind(for: "main", baseURL: "https://mp.example"), id)
        XCTAssertThrowsError(try model.setConnectionEnabled(id, enabled: true))
        XCTAssertEqual(LifecycleHTTP.state.requests, 0)
    }

    @MainActor func testRemovingOneInstanceKeepsOthersAndDurableIntentLedgers() throws {
        let defaults = makeDefaults(), vault = LifecycleVault(), model = makeModel(defaults, vault: vault)
        let removed = try add(model), kept = try add(model, type: .transmission, name: "Archive", host: "https://archive.example")
        let group = try model.preferences.saveGroup(name: "Home", memberIDs: [removed, kept])
        let intent = Data("synthetic-durable-intent".utf8)
        defaults.set(intent, forKey: "resourceDownloadIntents.v1")
        defaults.set(intent, forKey: "subscriptionWriteIntents.v1")
        try model.removeConnection(removed)
        XCTAssertEqual(model.profiles.map(\.id), [kept])
        XCTAssertTrue(vault.read(removed).isEmpty); XCTAssertFalse(vault.read(kept).isEmpty)
        XCTAssertEqual(model.preferences.serverGroups.first { $0.id == group }?.memberIDs, [kept])
        XCTAssertEqual(defaults.data(forKey: "resourceDownloadIntents.v1"), intent)
        XCTAssertEqual(defaults.data(forKey: "subscriptionWriteIntents.v1"), intent)
        XCTAssertEqual(LifecycleHTTP.state.requests, 0)
    }

    @MainActor func testCredentialDeleteFailureRestoresConnectionWithoutPretendingItWasCleared() throws {
        let defaults = makeDefaults(), vault = LifecycleVault(), model = makeModel(defaults, vault: vault)
        let id = try add(model), before = defaults.data(forKey: ConnectionProfileStore.storageKey)
        let credential = vault.read(id)
        vault.failDeletes = true
        XCTAssertThrowsError(try model.clearCredentials(id))
        XCTAssertTrue(model.profile(id).enabled); XCTAssertTrue(model.profile(id).allowActions)
        same(vault.read(id), credential)
        XCTAssertEqual(defaults.data(forKey: ConnectionProfileStore.storageKey), before)
        XCTAssertThrowsError(try model.removeConnection(id))
        XCTAssertEqual(model.profiles.map(\.id), [id])
        same(vault.read(id), credential)
        XCTAssertEqual(LifecycleHTTP.state.requests, 0)
    }

    @MainActor func testBadConfigurationRejectsNewConnectionsButExplicitBackupImportCanRecover() throws {
        let defaults = makeDefaults(), vault = LifecycleVault(), raw = Data("broken-v2-configuration".utf8)
        defaults.set(raw, forKey: ConnectionProfileStore.storageKey)
        let model = makeModel(defaults, vault: vault)
        XCTAssertNotNil(model.configurationError); XCTAssertTrue(model.profiles.isEmpty)
        XCTAssertThrowsError(try add(model))
        let file = try writeImport(["version": 2, "services": [["type": "qbittorrent", "name": "Home", "baseURL": "https://home.example", "username": "fixture", "password": "fixture-only"]]])
        defer { try? FileManager.default.removeItem(at: file) }
        try model.importProfile(file)
        XCTAssertNil(model.configurationError)
        XCTAssertEqual(model.profiles.count, 1)
        XCTAssertTrue(model.readOnlyMode); XCTAssertTrue(model.migrationProtection)
        XCTAssertFalse(model.profiles[0].allowActions)
        let recoveries = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("profiles.recovery.") }
        XCTAssertEqual(recoveries.count, 1)
        // The deliberately corrupt original must remain available, not be decoded and discarded.
        XCTAssertTrue(recoveries.values.contains { value in
            if let data = value as? Data { return data == raw }
            if let dictionary = value as? [String: Any] { return dictionary.values.contains { ($0 as? Data) == raw } }
            return false
        })
        XCTAssertEqual(vault.writeCount, 1); XCTAssertEqual(LifecycleHTTP.state.requests, 0)
    }

    @MainActor func testRenameKeepsPermissionGlobalLocksDirectoryAndBindingWithoutCredentialWrite() throws {
        let defaults = makeDefaults(), vault = LifecycleVault(), model = makeModel(defaults, vault: vault)
        let id = try add(model)
        model.preferences.setPreferredDownloadDirectoryID("preset", for: "https://mp.example")
        model.preferences.setBoundDownloaderKind(id, for: "main", baseURL: "https://mp.example")
        let writes = vault.writeCount, credential = vault.read(id), protection = model.profile(id).migrationProtected
        let epoch = model.resourceConnectionEpoch
        try model.renameConnection(id, name: "Home renamed")
        XCTAssertEqual(model.profile(id).id, id); XCTAssertEqual(model.profile(id).displayName, "Home renamed")
        XCTAssertTrue(model.profile(id).allowActions)
        XCTAssertEqual(model.profile(id).migrationProtected, protection)
        XCTAssertTrue(model.readOnlyMode); XCTAssertTrue(model.migrationProtection)
        XCTAssertEqual(model.preferences.preferredDownloadDirectoryID(for: "https://mp.example"), "preset")
        XCTAssertEqual(model.preferences.boundDownloaderKind(for: "main", baseURL: "https://mp.example"), id)
        XCTAssertEqual(model.resourceConnectionEpoch, epoch)
        same(vault.read(id), credential); XCTAssertEqual(vault.writeCount, writes)
        XCTAssertEqual(LifecycleHTTP.state.requests, 0)
    }

    @MainActor func testMultipleQBsAndTRsSurviveRelaunchAsSeparateInstances() throws {
        let defaults = makeDefaults(), vault = LifecycleVault(), model = makeModel(defaults, vault: vault)
        let first = try add(model, host: "https://qb-one.example")
        let second = try add(model, name: "Seedbox", host: "https://qb-two.example")
        let third = try add(model, type: .transmission, name: "Archive one", host: "https://tr-one.example")
        let fourth = try add(model, type: .transmission, name: "Archive two", host: "https://tr-two.example")
        model.disconnect(second)
        let restored = makeModel(defaults, vault: vault)
        XCTAssertEqual(restored.profiles.map(\.id), [first, second, third, fourth])
        XCTAssertEqual(restored.downloaderProfiles.count, 4)
        XCTAssertFalse(restored.isConfigured(second)); XCTAssertTrue(restored.hasSavedCredentials(second))
        XCTAssertTrue(restored.isConfigured(first)); XCTAssertTrue(restored.isConfigured(third)); XCTAssertTrue(restored.isConfigured(fourth))
        XCTAssertEqual(LifecycleHTTP.state.requests, 0)
    }

    @MainActor func testManualMPBindingAllowsInternalAddressAliasButNotChangedRemoteIdentity() throws {
        let defaults = makeDefaults(), vault = LifecycleVault(), model = makeModel(defaults, vault: vault)
        let id = try add(model)
        try model.saveConnection(.moviepilot, baseURL: "https://mp.example", username: "fixture", password: "fixture-only", apiKey: "", allowActions: true)
        model.readOnlyMode = false
        let remote = MPResourceDownloader(id: "MP main", name: "MP main", type: "qbittorrent", targetBaseURL: "http://qb-container:8080")
        model.preferences.setBoundDownloaderKind(id, for: remote.bindingID, baseURL: "https://mp.example")
        XCTAssertTrue(model.canDownloadResource(remote))
        var changed = remote; changed.targetBaseURL = "http://different-container:8080"
        XCTAssertFalse(model.canDownloadResource(changed))
        model.disconnect(id)
        XCTAssertFalse(model.canDownloadResource(remote))
        XCTAssertEqual(LifecycleHTTP.state.requests, 0)
    }

    @MainActor func testV2ImportAddsManyProtocolsWithoutApplyingManagementPermission() throws {
        let defaults = makeDefaults(), vault = LifecycleVault(), model = makeModel(defaults, vault: vault)
        let services: [[String: Any]] = (0..<12).map { index in
            ["type": index % 2 == 0 ? "qbittorrent" : "transmission", "name": "Server \(index)",
             "baseURL": "https://server-\(index).example", "username": "fixture", "password": "fixture-only"]
        }
        let file = try writeImport(["version": 2, "services": services])
        defer { try? FileManager.default.removeItem(at: file) }
        try model.importProfile(file)
        XCTAssertEqual(model.profiles.count, 12); XCTAssertEqual(Set(model.profiles.map(\.id)).count, 12)
        XCTAssertEqual(model.profiles.filter { $0.protocolKind == .qbittorrent }.count, 6)
        XCTAssertEqual(model.profiles.filter { $0.protocolKind == .transmission }.count, 6)
        XCTAssertTrue(model.profiles.allSatisfy { !$0.allowActions })
        XCTAssertTrue(model.readOnlyMode); XCTAssertTrue(model.migrationProtection)
        XCTAssertEqual(vault.values.count, 12); XCTAssertEqual(LifecycleHTTP.state.requests, 0)
    }

    @MainActor func testV2ImportCredentialFailureRollsBackWrittenValuesAndPreservesConfigBytes() throws {
        let defaults = makeDefaults(), vault = LifecycleVault(), model = makeModel(defaults, vault: vault)
        let oldID = try add(model), newID = ServiceID.make(.transmission)
        let oldCredential = vault.read(oldID), original = defaults.data(forKey: ConnectionProfileStore.storageKey)
        vault.failingWrites = [vault.writeCount + 2]
        let services: [[String: Any]] = [
            ["kind": oldID.rawValue, "type": "qbittorrent", "name": "Changed", "baseURL": "https://home.example", "username": "fixture", "password": "replacement-only"],
            ["kind": newID.rawValue, "type": "transmission", "name": "New", "baseURL": "https://new.example", "username": "fixture", "password": "fixture-only"]
        ]
        let file = try writeImport(["version": 2, "services": services])
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try model.importProfile(file))
        same(vault.read(oldID), oldCredential)
        XCTAssertTrue(vault.read(newID).isEmpty)
        XCTAssertEqual(defaults.data(forKey: ConnectionProfileStore.storageKey), original)
        XCTAssertEqual(model.profiles.map(\.id), [oldID]); XCTAssertEqual(model.profile(oldID).displayName, "Home")
        XCTAssertEqual(LifecycleHTTP.state.requests, 0)
    }

    @MainActor func testFailedCredentialRollbackClosesManagementInsteadOfClaimingRecovery() throws {
        let defaults = makeDefaults(), vault = LifecycleVault(), model = makeModel(defaults, vault: vault)
        let oldID = try add(model), newID = ServiceID.make(.transmission)
        let original = defaults.data(forKey: ConnectionProfileStore.storageKey)
        model.readOnlyMode = false
        XCTAssertTrue(model.canManage(oldID))
        vault.failingWrites = [vault.writeCount + 2, vault.writeCount + 3]
        let file = try writeImport(["version": 2, "services": [
            ["kind": oldID.rawValue, "type": "qbittorrent", "name": "Changed", "baseURL": "https://home.example", "username": "fixture", "password": "replacement-only"],
            ["kind": newID.rawValue, "type": "transmission", "name": "New", "baseURL": "https://new.example", "username": "fixture", "password": "fixture-only"]
        ]])
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try model.importProfile(file))
        XCTAssertNotNil(model.configurationError)
        XCTAssertTrue(model.readOnlyMode); XCTAssertFalse(model.canManage(oldID))
        XCTAssertTrue(defaults.bool(forKey: "readOnlyMode"))
        XCTAssertEqual(defaults.data(forKey: ConnectionProfileStore.storageKey), original)
        XCTAssertFalse(model.configurationError?.contains("replacement-only") ?? true)
        let restored = makeModel(defaults, vault: vault)
        XCTAssertNotNil(restored.configurationError)
        XCTAssertTrue(restored.readOnlyMode); XCTAssertFalse(restored.isConfigured(oldID)); XCTAssertFalse(restored.canManage(oldID))
        XCTAssertEqual(LifecycleHTTP.state.requests, 0)
    }

    @MainActor func testCredentialOnlyRecoveryStaysSuspendedBeforeAnyRead() async {
        let defaults = makeDefaults(), vault = LifecycleVault()
        vault.values[.qb1] = Credential(username: "fixture", password: "legacy-only")
        let model = makeModel(defaults, vault: vault)
        XCTAssertEqual(model.profiles.map(\.id), [.qb1])
        XCTAssertFalse(model.profile(.qb1).enabled)
        XCTAssertTrue(model.hasSavedCredentials(.qb1)); XCTAssertFalse(model.isConfigured(.qb1))
        await model.refreshDashboard()
        XCTAssertEqual(LifecycleHTTP.state.requests, 0)
        XCTAssertEqual(vault.writeCount, 0); XCTAssertEqual(vault.deleteCount, 0)
    }

    @MainActor func testInvalidImportIsRejectedBeforeAnyCredentialMutation() throws {
        let defaults = makeDefaults(), vault = LifecycleVault(), model = makeModel(defaults, vault: vault)
        let id = ServiceID.make(.qbittorrent)
        let file = try writeImport(["version": 2, "services": [
            ["kind": id.rawValue, "type": "qbittorrent", "name": "A", "baseURL": "https://a.example", "username": "fixture", "password": "fixture-only"],
            ["kind": id.rawValue, "type": "transmission", "name": "B", "baseURL": "https://b.example", "username": "fixture", "password": "fixture-only"]
        ]])
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try model.importProfile(file))
        XCTAssertEqual(vault.writeCount, 0); XCTAssertTrue(model.profiles.isEmpty)
        XCTAssertNil(defaults.object(forKey: ConnectionProfileStore.storageKey))
        XCTAssertEqual(LifecycleHTTP.state.requests, 0)
    }

    @MainActor func testLegacyMigrationUsesSameCredentialAccountsAndPreservesOriginalBytes() throws {
        let defaults = makeDefaults(), vault = LifecycleVault()
        vault.values[.qb1] = Credential(username: "fixture", password: "legacy-only")
        let raw = Data(#"[{"kind":"qb1","baseURL":"https://legacy.example","username":"fixture","allowActions":true}]"#.utf8)
        defaults.set(raw, forKey: ConnectionProfileStore.legacyStorageKey)
        let model = makeModel(defaults, vault: vault)
        XCTAssertNil(model.configurationError)
        XCTAssertEqual(model.profiles.map(\.id), [.qb1])
        XCTAssertEqual(model.credential(.qb1).password, "legacy-only")
        XCTAssertTrue(model.profile(.qb1).migrationProtected)
        XCTAssertTrue(model.readOnlyMode); XCTAssertFalse(model.canManage(.qb1))
        XCTAssertEqual(defaults.data(forKey: ConnectionProfileStore.legacyStorageKey), raw)
        XCTAssertEqual(vault.writeCount, 0); XCTAssertEqual(vault.deleteCount, 0)
        XCTAssertEqual(LifecycleHTTP.state.requests, 0)
    }
}
