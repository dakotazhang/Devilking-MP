import XCTest
@testable import DevilkingMP

final class MultiServerConfigurationTests: XCTestCase {
    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "PocketRem-MultiServerTests-" + UUID().uuidString)!
    }
    private func profile(_ id: ServiceID, name: String? = nil, enabled: Bool = true) -> ServiceProfile {
        ServiceProfile(kind: id, baseURL: "https://server.example/" + id.protocolKind.rawValue,
                       username: "fixture-user", name: name, enabled: enabled)
    }
    private func legacyData() -> Data {
        Data("""
        [{"kind":"qb1","baseURL":"https://qb.example","username":"fixture-user","allowActions":true},
         {"kind":"tr","baseURL":"https://tr.example","username":"fixture-user","allowActions":false}]
        """.utf8)
    }

    func testLegacyStaticValuesRemainSourceAndStringCompatible() throws {
        let values: [ServiceKind] = [.qb1, .qb2, .tr, .moviepilot, .emby]
        XCTAssertEqual(values.map(\.rawValue), ["qb1", "qb2", "tr", "moviepilot", "emby"])
        XCTAssertEqual(ServiceID.allCases, values)
        let inferred: ServiceID = .qb1
        switch inferred { case .qb1: break; default: XCTFail("Legacy expression patterns must still work") }
        XCTAssertEqual(String(data: try JSONEncoder().encode(inferred), encoding: .utf8), "\"qb1\"")
        XCTAssertEqual(try JSONDecoder().decode(ServiceKind.self, from: Data("\"tr\"".utf8)), .tr)
    }

    func testManyDownloadersHaveIndependentStableIdentitiesAndProtocolCapabilities() {
        let qb = (0..<80).map { _ in ServiceID.make(.qbittorrent) }
        let tr = (0..<80).map { _ in ServiceID.make(.transmission) }
        XCTAssertEqual(Set(qb + tr).count, 160)
        XCTAssertTrue(qb.allSatisfy { $0.protocolKind == .qbittorrent && $0.isQB && $0.isDownloader })
        XCTAssertTrue(tr.allSatisfy { $0.protocolKind == .transmission && $0.isTR && $0.isDownloader })
        XCTAssertTrue((qb + tr).allSatisfy { ServiceID(rawValue: $0.rawValue) == $0 && !$0.isLegacy })
        XCTAssertEqual(ServiceID.make(.moviepilot), .moviepilot)
        XCTAssertEqual(ServiceID.make(.emby), .emby)
    }

    func testUnknownOrAmbiguousServerIdentityIsRejected() throws {
        for value in ["", "qb3", "qb", "tr:", "qb:random-name", "moviepilot:" + UUID().uuidString,
                      "QB:" + UUID().uuidString, "qb:" + UUID().uuidString + ":extra"] {
            XCTAssertNil(ServiceID(rawValue: value), value)
            XCTAssertThrowsError(try JSONDecoder().decode(ServiceID.self, from: JSONEncoder().encode(value)))
        }
    }

    func testUUIDCaseCanonicalizationCannotCreateASecondInstance() {
        let uuid = UUID().uuidString
        XCTAssertEqual(ServiceID(rawValue: "qb:" + uuid), ServiceID(rawValue: "qb:" + uuid.lowercased()))
        XCTAssertNotEqual(ServiceID(rawValue: "qb:" + uuid), ServiceID(rawValue: "tr:" + uuid))
    }

    func testLegacyProfileDecodingRetainsPermissionsAndAddsConservativeProtection() throws {
        let profiles = try JSONDecoder().decode([ServiceProfile].self, from: legacyData())
        XCTAssertEqual(profiles.map(\.id), [.qb1, .tr])
        XCTAssertTrue(profiles[0].allowActions)
        XCTAssertFalse(profiles[1].allowActions)
        XCTAssertTrue(profiles.allSatisfy(\.enabled))
        XCTAssertTrue(profiles.allSatisfy(\.migrationProtected))
        XCTAssertEqual(profiles[0].displayName, "家庭 qB1")
        let oldQB2 = Data(#"{"kind":"qb2","baseURL":"https://qb2.example","username":"fixture"}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(ServiceProfile.self, from: oldQB2).migrationProtected)
    }

    func testDynamicProfileRoundTripRetainsNameDisabledStateAndExactID() throws {
        let id = ServiceID.make(.transmission)
        let original = ServiceProfile(kind: id, baseURL: "https://tr.example", username: "fixture",
                                      allowActions: false, name: "Archive TR", enabled: false, migrationProtected: true)
        let decoded = try JSONDecoder().decode(ServiceProfile.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.protocolKind, .transmission)
        XCTAssertEqual(decoded.displayName, "Archive TR")
        XCTAssertFalse(decoded.enabled)
        XCTAssertFalse(decoded.allowActions)
        XCTAssertTrue(decoded.migrationProtected)
    }

    func testFreshInstallationHasNoPhantomServersOrWrittenStore() {
        let defaults = isolatedDefaults()
        let result = ConnectionProfileStore.load(defaults: defaults, legacyCredentialExists: { _ in false })
        XCTAssertTrue(result.profiles.isEmpty)
        XCTAssertNil(result.error)
        XCTAssertFalse(result.migrated)
        XCTAssertNil(defaults.object(forKey: ConnectionProfileStore.storageKey))
    }

    func testLegacyMigrationPreservesOriginalBytesAndStableKeychainAccountNames() throws {
        let defaults = isolatedDefaults(), raw = legacyData()
        defaults.set(raw, forKey: ConnectionProfileStore.legacyStorageKey)
        let result = ConnectionProfileStore.load(defaults: defaults, legacyCredentialExists: { _ in false })
        XCTAssertNil(result.error)
        XCTAssertTrue(result.migrated)
        XCTAssertEqual(result.profiles.map { $0.id.rawValue }, ["qb1", "tr"])
        XCTAssertEqual(defaults.data(forKey: ConnectionProfileStore.legacyStorageKey), raw)
        XCTAssertNotNil(defaults.data(forKey: ConnectionProfileStore.storageKey))
        let second = ConnectionProfileStore.load(defaults: defaults, legacyCredentialExists: { _ in false })
        XCTAssertFalse(second.migrated)
        XCTAssertEqual(second.profiles.map(\.id), [.qb1, .tr])
        XCTAssertEqual(KeychainStore.service, "top.devilkkkkk1.DevilkingMP.credentials")
    }

    func testCredentialOnlyRecoveryRestoresOnlyRealLegacyEntriesWithoutGrantingActions() {
        let defaults = isolatedDefaults()
        let result = ConnectionProfileStore.load(defaults: defaults, legacyCredentialExists: { $0 == .qb2 })
        XCTAssertNil(result.error)
        XCTAssertTrue(result.migrated)
        XCTAssertEqual(result.profiles.map(\.id), [.qb2])
        XCTAssertFalse(result.profiles[0].allowActions)
        XCTAssertFalse(result.profiles[0].enabled)
        XCTAssertFalse(result.profiles[0].migrationProtected)
        XCTAssertEqual(result.profiles[0].baseURL, ServiceID.qb2.defaultURL)
    }

    func testMalformedLegacyBytesArePreservedAndDoNotCreateV2Store() {
        let defaults = isolatedDefaults(), raw = Data("not-json".utf8)
        defaults.set(raw, forKey: ConnectionProfileStore.legacyStorageKey)
        let result = ConnectionProfileStore.load(defaults: defaults, legacyCredentialExists: { _ in true })
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.profiles.isEmpty)
        XCTAssertFalse(result.migrated)
        XCTAssertEqual(defaults.data(forKey: ConnectionProfileStore.legacyStorageKey), raw)
        XCTAssertNil(defaults.object(forKey: ConnectionProfileStore.storageKey))
    }

    func testMalformedV2DoesNotFallBackToOlderConfigurationOrOverwriteBytes() {
        let defaults = isolatedDefaults(), raw = Data("{broken".utf8)
        defaults.set(legacyData(), forKey: ConnectionProfileStore.legacyStorageKey)
        defaults.set(raw, forKey: ConnectionProfileStore.storageKey)
        let result = ConnectionProfileStore.load(defaults: defaults, legacyCredentialExists: { _ in true })
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.profiles.isEmpty)
        XCTAssertEqual(defaults.data(forKey: ConnectionProfileStore.storageKey), raw)
    }

    func testDuplicateIDsAreRejectedWithoutReplacingExistingStore() throws {
        let defaults = isolatedDefaults(), first = profile(.qb1)
        try ConnectionProfileStore.save([first], defaults: defaults)
        let original = defaults.data(forKey: ConnectionProfileStore.storageKey)
        XCTAssertThrowsError(try ConnectionProfileStore.save([first, first], defaults: defaults))
        XCTAssertEqual(defaults.data(forKey: ConnectionProfileStore.storageKey), original)
        let duplicate = try JSONEncoder().encode([first, first])
        defaults.set(duplicate, forKey: ConnectionProfileStore.storageKey)
        let loaded = ConnectionProfileStore.load(defaults: defaults, legacyCredentialExists: { _ in false })
        XCTAssertNotNil(loaded.error)
        XCTAssertEqual(defaults.data(forKey: ConnectionProfileStore.storageKey), duplicate)
    }

    func testUnknownIDInV2RejectsWholeStoreWithoutSilentlyDroppingEntry() {
        let defaults = isolatedDefaults()
        let raw = Data(#"[{"kind":"unknown","baseURL":"https://server.example","username":"fixture"}]"#.utf8)
        defaults.set(raw, forKey: ConnectionProfileStore.storageKey)
        let result = ConnectionProfileStore.load(defaults: defaults, legacyCredentialExists: { _ in false })
        XCTAssertTrue(result.profiles.isEmpty)
        XCTAssertNotNil(result.error)
        XCTAssertEqual(defaults.data(forKey: ConnectionProfileStore.storageKey), raw)
    }

    func testMetadataSaveKeepsIdentityPermissionsAndGlobalSafetySettings() throws {
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: "readOnlyMode"); defaults.set(true, forKey: "migrationProtection")
        let id = ServiceID.make(.qbittorrent)
        var value = profile(id, name: "Home")
        value.allowActions = false
        try ConnectionProfileStore.save([value], defaults: defaults)
        value.name = "Renamed home"; value.enabled = false
        try ConnectionProfileStore.save([value], defaults: defaults)
        let result = ConnectionProfileStore.load(defaults: defaults, legacyCredentialExists: { _ in false })
        XCTAssertEqual(result.profiles.first?.id, id)
        XCTAssertEqual(result.profiles.first?.displayName, "Renamed home")
        XCTAssertEqual(result.profiles.first?.allowActions, false)
        XCTAssertEqual(result.profiles.first?.enabled, false)
        XCTAssertTrue(defaults.bool(forKey: "readOnlyMode")); XCTAssertTrue(defaults.bool(forKey: "migrationProtection"))
    }

    func testTwoTransmissionInstancesKeepTheSameHashAsTwoQualifiedTasks() {
        let first = ServiceID.make(.transmission), second = ServiceID.make(.transmission)
        let hash = String(repeating: "a", count: 40)
        let row: [String: Any] = ["hashString": hash, "name": "Synthetic archive", "status": 6,
                                  "percentDone": 1, "leftUntilDone": 0, "error": 0]
        let a = TaskParser.tr(row, kind: first), b = TaskParser.tr(row, kind: second)
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(a.kind, first); XCTAssertEqual(b.kind, second)
        XCTAssertNotEqual(a.qualifiedID, b.qualifiedID)
        XCTAssertEqual(TaskParser.tr(row).kind, .tr)
    }

    func testDynamicProtocolTaskValidationAndMPCompatibilityDoNotUseLegacySlotEquality() {
        let qb = ServiceID.make(.qbittorrent), tr = ServiceID.make(.transmission)
        XCTAssertTrue(EndpointPolicy.validTaskID(String(repeating: "a", count: 64), kind: qb))
        XCTAssertFalse(EndpointPolicy.validTaskID(String(repeating: "a", count: 64), kind: tr))
        XCTAssertTrue(EndpointPolicy.validTaskID(String(repeating: "a", count: 40), kind: tr))
        let remote = MPResourceDownloader(id: "qB", name: "qB", type: "qbittorrent", targetBaseURL: "https://qb.example")
        XCTAssertTrue(remote.accepts(qb)); XCTAssertTrue(remote.accepts(.qb1))
        XCTAssertFalse(remote.accepts(tr)); XCTAssertFalse(remote.accepts(.moviepilot))
    }

    @MainActor func testDynamicBindingsPersistAndStayInsideTheirMPConnection() {
        let defaults = isolatedDefaults(), id = ServiceID.make(.transmission)
        let preferences = AppPreferences(defaults: defaults)
        preferences.setBoundDownloaderKind(id, for: "remote-id", baseURL: "https://mp-one.example")
        let restored = AppPreferences(defaults: defaults)
        XCTAssertEqual(restored.boundDownloaderKind(for: "remote-id", baseURL: "https://mp-one.example/"), id)
        XCTAssertNil(restored.boundDownloaderKind(for: "remote-id", baseURL: "https://mp-two.example"))
        restored.setBoundDownloaderKind(.moviepilot, for: "other", baseURL: "https://mp-one.example")
        XCTAssertNil(restored.boundDownloaderKind(for: "other", baseURL: "https://mp-one.example"))
    }

    @MainActor func testRemovingBindingsTargetsOnlyExactInstanceAndPreservesDirectoriesAcrossScopes() throws {
        let defaults = isolatedDefaults(), preferences = AppPreferences(defaults: defaults)
        let removed = ServiceID.make(.qbittorrent), kept = ServiceID.make(.qbittorrent)
        for base in ["https://mp-one.example", "https://mp-two.example"] {
            preferences.setBoundDownloaderKind(removed, for: "removed", baseURL: base)
            preferences.setBoundDownloaderKind(kept, for: "kept", baseURL: base)
            preferences.setPreferredDownloadDirectoryID("preset", for: base)
        }
        try preferences.removeBindings(to: removed)
        let restored = AppPreferences(defaults: defaults)
        for base in ["https://mp-one.example", "https://mp-two.example"] {
            XCTAssertNil(restored.boundDownloaderKind(for: "removed", baseURL: base))
            XCTAssertEqual(restored.boundDownloaderKind(for: "kept", baseURL: base), kept)
            XCTAssertEqual(restored.preferredDownloadDirectoryID(for: base), "preset")
        }
    }

    @MainActor func testGroupMembersAreDeduplicatedAndSelectionSurvivesRelaunch() throws {
        let defaults = isolatedDefaults(), preferences = AppPreferences(defaults: defaults)
        let a = ServiceID.make(.qbittorrent), b = ServiceID.make(.transmission)
        let group = try preferences.saveGroup(name: "Home", memberIDs: [a, a, b])
        try preferences.setSelectedGroupID(group)
        let restored = AppPreferences(defaults: defaults)
        XCTAssertEqual(restored.selectedGroupID, group)
        XCTAssertEqual(restored.selectedGroup?.memberIDs, [a, b])
        XCTAssertEqual(restored.scopedDownloaderIDs([a, b, a]), [a, b])
    }

    @MainActor func testOverlappingGroupsDoNotDuplicateGlobalStatisticsMembership() throws {
        let preferences = AppPreferences(defaults: isolatedDefaults())
        let a = ServiceID.make(.qbittorrent), b = ServiceID.make(.transmission), c = ServiceID.make(.qbittorrent)
        let home = try preferences.saveGroup(name: "Home", memberIDs: [a, b])
        let seedboxes = try preferences.saveGroup(name: "Seedboxes", memberIDs: [a, c])
        try preferences.setSelectedGroupID(home)
        XCTAssertEqual(preferences.scopedDownloaderIDs([a, b, c]), [a, b])
        try preferences.setSelectedGroupID(seedboxes)
        XCTAssertEqual(preferences.scopedDownloaderIDs([a, b, c]), [a, c])
        try preferences.setSelectedGroupID(nil)
        XCTAssertEqual(preferences.scopedDownloaderIDs([a, b, c, a]), [a, b, c])
    }

    @MainActor func testDeletingSelectedGroupReturnsToAllAndDoesNotTouchProfilesOrSafety() throws {
        let defaults = isolatedDefaults(), preferences = AppPreferences(defaults: defaults), id = ServiceID.make(.qbittorrent)
        try ConnectionProfileStore.save([profile(id)], defaults: defaults)
        defaults.set(true, forKey: "readOnlyMode"); defaults.set(true, forKey: "migrationProtection")
        let raw = defaults.data(forKey: ConnectionProfileStore.storageKey)
        let group = try preferences.saveGroup(name: "Home", memberIDs: [id])
        try preferences.setSelectedGroupID(group)
        try preferences.deleteGroup(group)
        XCTAssertNil(preferences.selectedGroupID)
        XCTAssertTrue(preferences.serverGroups.isEmpty)
        XCTAssertEqual(defaults.data(forKey: ConnectionProfileStore.storageKey), raw)
        XCTAssertTrue(defaults.bool(forKey: "readOnlyMode")); XCTAssertTrue(defaults.bool(forKey: "migrationProtection"))
    }

    @MainActor func testGroupRenameKeepsGroupAndMemberIdentity() throws {
        let preferences = AppPreferences(defaults: isolatedDefaults()), id = ServiceID.make(.qbittorrent)
        let group = try preferences.saveGroup(name: "Old name", memberIDs: [id])
        try preferences.setSelectedGroupID(group)
        let saved = try preferences.saveGroup(id: group, name: "New name", memberIDs: [id])
        XCTAssertEqual(saved, group)
        XCTAssertEqual(preferences.selectedGroup?.name, "New name")
        XCTAssertEqual(preferences.selectedGroup?.memberIDs, [id])
    }

    @MainActor func testInvalidNamesUnknownGroupsAndNonDownloaderMembersCannotChangeGroups() throws {
        let preferences = AppPreferences(defaults: isolatedDefaults()), id = ServiceID.make(.qbittorrent)
        _ = try preferences.saveGroup(name: "Home", memberIDs: [id])
        let before = preferences.serverGroups
        for name in ["", "   ", "Bad\nName", String(repeating: "x", count: 81)] {
            XCTAssertThrowsError(try preferences.saveGroup(name: name, memberIDs: [id]))
        }
        XCTAssertThrowsError(try preferences.saveGroup(name: "HOME", memberIDs: [id]))
        XCTAssertThrowsError(try preferences.saveGroup(name: "MP", memberIDs: [.moviepilot]))
        XCTAssertThrowsError(try preferences.saveGroup(id: UUID().uuidString, name: "Missing", memberIDs: []))
        XCTAssertThrowsError(try preferences.setSelectedGroupID(UUID().uuidString))
        XCTAssertEqual(preferences.serverGroups, before)
        XCTAssertNil(preferences.selectedGroupID)
    }

    @MainActor func testEmptyGroupsStayEmptyAndStaleMembersAreNeverInvented() throws {
        let preferences = AppPreferences(defaults: isolatedDefaults())
        let current = ServiceID.make(.qbittorrent), missing = ServiceID.make(.transmission)
        let group = try preferences.saveGroup(name: "Empty", memberIDs: [])
        try preferences.setSelectedGroupID(group)
        XCTAssertTrue(preferences.scopedDownloaderIDs([current]).isEmpty)
        _ = try preferences.saveGroup(id: group, name: "Archive", memberIDs: [current, missing])
        XCTAssertEqual(preferences.scopedDownloaderIDs([current, .moviepilot]), [current])
        try preferences.removeServerFromGroups(current)
        XCTAssertEqual(preferences.selectedGroup?.memberIDs, [missing])
        XCTAssertTrue(preferences.scopedDownloaderIDs([current]).isEmpty)
    }

    @MainActor func testCorruptGroupBytesArePreservedUntilExplicitLocalReset() throws {
        let defaults = isolatedDefaults(), raw = Data("corrupt-groups".utf8)
        defaults.set(raw, forKey: "ui.serverGroups.v1")
        defaults.set(true, forKey: "readOnlyMode")
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertNotNil(preferences.groupConfigurationError)
        XCTAssertTrue(preferences.serverGroups.isEmpty)
        XCTAssertEqual(defaults.data(forKey: "ui.serverGroups.v1"), raw)
        XCTAssertThrowsError(try preferences.saveGroup(name: "Home", memberIDs: []))
        try preferences.resetServerGroups()
        XCTAssertNil(preferences.groupConfigurationError)
        XCTAssertNil(AppPreferences(defaults: defaults).groupConfigurationError)
        XCTAssertTrue(defaults.bool(forKey: "readOnlyMode"))
    }
}
