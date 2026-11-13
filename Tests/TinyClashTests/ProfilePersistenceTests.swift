import Foundation
import XCTest
@testable import TinyClash

/// All persistence and validation paths are injected under a new temporary directory.
/// These tests never initialize AppState, AppPaths, or a real mihomo process.
@MainActor
final class ProfilePersistenceTests: XCTestCase {
    private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var profile = Profile(name: "Test", kind: .local, fileName: "test.yaml",
                              updatedAt: Date(timeIntervalSince1970: 1_700_000_000), updateInterval: 0)
        var index: URL { directory.appendingPathComponent("profiles.json") }
        var file: URL { directory.appendingPathComponent(profile.fileName) }
        let original = "# untouched\nmixed-port: 7890\nrules:\n  - MATCH,DIRECT\n"

        init() throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(original.utf8).write(to: file)
        }

        func store(validate: @escaping (URL) async throws -> Void = { _ in }) -> ProfileStore {
            ProfileStore(profilesDirectory: directory, indexURL: index, validate: validate)
        }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    func testLegacyConversionIsIdempotentEvenIfOldMetadataSurvivesAnInterruptedCommit() async throws {
        let fixture = try Fixture()
        fixture.profile.customRules = ["DOMAIN,legacy.test,DIRECT"]
        fixture.profile.customGroups = [CustomGroup(name: "Legacy", proxies: ["DIRECT"])]
        let store = fixture.store()
        store.save([fixture.profile])
        let first = try await store.prepareEdit(.addRule("DOMAIN,first.test,DIRECT"), to: fixture.profile)
        _ = try store.commit(first, profiles: [fixture.profile])
        // Simulate a crash after the YAML rename but before the index rename.
        store.save([fixture.profile])
        let retry = try await store.prepareEdit(.addRule("DOMAIN,second.test,DIRECT"), to: fixture.profile)
        let profiles = try store.commit(retry, profiles: [fixture.profile])
        let yaml = try String(contentsOf: fixture.file, encoding: .utf8)
        XCTAssertEqual(yaml.components(separatedBy: "DOMAIN,legacy.test,DIRECT").count - 1, 1)
        XCTAssertEqual(yaml.components(separatedBy: "- name: Legacy").count - 1, 1)
        XCTAssertFalse(profiles[0].hasCustomization)
        XCTAssertFalse(store.load()[0].hasCustomization)
        XCTAssertEqual(try ConfigOverlay.apply(rules: [], groups: [], to: yaml), yaml)
    }

    func testAddedGroupWritesStandardMultilineBlockYAMLMatchingExistingIndentation() async throws {
        let fixture = try Fixture()
        let original = """
        mixed-port: 7890
        proxy-groups:
        - name: 新加坡
          type: url-test
          url: https://cp.cloudflare.com/generate_204
          interval: 300
          include-all: true
          filter: '新加坡'
        rules:
        - MATCH,新加坡
        """
        try Data(original.utf8).write(to: fixture.file)
        let store = fixture.store()
        store.save([fixture.profile])

        let group = CustomGroup(
            name: "aa",
            type: "url-test",
            proxies: [],
            includeAll: true,
            filter: "香|美",
            url: "https://www.gstatic.com/generate_204",
            interval: 300
        )
        let edit = try await store.prepareEdit(.addGroup(group), to: fixture.profile)
        _ = try store.commit(edit, profiles: [fixture.profile])
        let yaml = try String(contentsOf: fixture.file, encoding: .utf8)
        XCTAssertFalse(yaml.contains("{\""))
        XCTAssertTrue(yaml.contains("""
        - name: aa
          type: url-test
          url: https://www.gstatic.com/generate_204
          interval: 300
          include-all: true
          filter: '香|美'
        """), yaml)
    }

    func testEmptyFlowArraysExpandToStandardBlockYAMLWhenAdding() async throws {
        let fixture = try Fixture()
        let original = "mixed-port: 7890\nproxy-groups: [] # keep\nrules: []\n"
        try Data(original.utf8).write(to: fixture.file)
        let store = fixture.store()
        store.save([fixture.profile])
        var profiles = [fixture.profile]
        let g = CustomGroup(name: "Manual", proxies: ["DIRECT", "节点 #1"])
        let e1 = try await store.prepareEdit(.addGroup(g), to: profiles[0])
        profiles = try store.commit(e1, profiles: profiles)
        let e2 = try await store.prepareEdit(.addRule("DOMAIN,example.test,Manual"), to: profiles[0])
        _ = try store.commit(e2, profiles: profiles)
        let yaml = try String(contentsOf: fixture.file, encoding: .utf8)
        XCTAssertTrue(yaml.contains("proxy-groups: # keep\n  - name: Manual\n    type: select\n    proxies:\n      - DIRECT\n      - '节点 #1'\n"), yaml)
        XCTAssertTrue(yaml.contains("rules:\n  - DOMAIN,example.test,Manual\n"), yaml)
    }

    func testInlineArraysAndCommentsArePreservedWhenAdding() async throws {
        let fixture = try Fixture()
        let original = "mixed-port: 7890\r\nproxy-groups: [{name: Existing, type: select, proxies: [DIRECT]}] # keep groups\r\nrules: ['MATCH,DIRECT'] # keep rules\r\ndns: {enable: false} # untouched\r\n"
        try Data(original.utf8).write(to: fixture.file)
        let store = fixture.store()
        store.save([fixture.profile])
        var profiles = [fixture.profile]
        let rule = try await store.prepareEdit(.addRule("DOMAIN,example.test,DIRECT"), to: profiles[0])
        profiles = try store.commit(rule, profiles: profiles)
        let group = CustomGroup(name: "New", proxies: ["DIRECT"])
        let edit = try await store.prepareEdit(.addGroup(group), to: profiles[0])
        _ = try store.commit(edit, profiles: profiles)
        let yaml = try String(contentsOf: fixture.file, encoding: .utf8)
        XCTAssertTrue(yaml.contains("rules: [\"DOMAIN,example.test,DIRECT\", 'MATCH,DIRECT'] # keep rules\r\n"))
        XCTAssertTrue(yaml.contains("{name: Existing, type: select, proxies: [DIRECT]}, \(group.flowYAML)] # keep groups\r\n"))
        XCTAssertTrue(yaml.hasSuffix("dns: {enable: false} # untouched\r\n"))
    }

    func testFailedValidationLeavesYAMLAndLegacyMetadataByteForByteUnchanged() async throws {
        let fixture = try Fixture()
        fixture.profile.customRules = ["DOMAIN,legacy.test,DIRECT"]
        fixture.profile.customGroups = [CustomGroup(name: "Legacy", proxies: ["DIRECT"])]
        let store = fixture.store { _ in throw ProfileError.invalidConfig("invalid rule") }
        store.save([fixture.profile])
        let originalIndex = try Data(contentsOf: fixture.index)
        do {
            _ = try await store.prepareEdit(.addRule("NOT-A-RULE"), to: fixture.profile)
            XCTFail("Invalid configuration must not prepare a commit")
        } catch ProfileError.invalidConfig { }
        XCTAssertEqual(try Data(contentsOf: fixture.file), Data(fixture.original.utf8))
        XCTAssertEqual(try Data(contentsOf: fixture.index), originalIndex)
        XCTAssertTrue(store.load()[0].hasCustomization)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).contains { $0.hasPrefix(".validate-") })
    }

    func testSequentialRuleAndGroupAdditionsKeepAllPriorEntries() async throws {
        let fixture = try Fixture()
        fixture.profile.customRules = ["DOMAIN,legacy.test,DIRECT"]
        let store = fixture.store()
        store.save([fixture.profile])
        var profiles = [fixture.profile]
        for editKind in [ProfileStore.ProfileEdit.addRule("DOMAIN,first.test,DIRECT"),
                         .addGroup(CustomGroup(name: "Choice", proxies: ["DIRECT"])),
                         .addRule("DOMAIN,second.test,Choice")] {
            let edit = try await store.prepareEdit(editKind, to: profiles[0])
            profiles = try store.commit(edit, profiles: profiles)
            profiles = store.load() // Simulate restart between additions.
        }
        let yaml = try String(contentsOf: fixture.file, encoding: .utf8)
        XCTAssertTrue(yaml.contains("  - DOMAIN,second.test,Choice\n  - DOMAIN,first.test,DIRECT\n  - DOMAIN,legacy.test,DIRECT\n  - MATCH,DIRECT"), yaml)
        XCTAssertEqual(yaml.components(separatedBy: "DOMAIN,legacy.test,DIRECT").count - 1, 1)
        XCTAssertTrue(yaml.contains("  - name: Choice\n    type: select\n    proxies:\n      - DIRECT"), yaml)
        XCTAssertFalse(profiles[0].hasCustomization)
    }

    func testDeletingProxyGroupSupportsBlockLegacyFlowAndLastGroup() async throws {
        let fixture = try Fixture()
        let original = """
        mixed-port: 7890
        proxy-groups:
          - type: select
            name: 'First #1'
            proxies:
              - DIRECT

          # keep section comment
          - {"name":"LegacyJSON","type":"select","proxies":["DIRECT"]}
          - name: Last
            type: select
            proxies:
              - DIRECT
        rules:
          - MATCH,DIRECT
        """
        try Data(original.utf8).write(to: fixture.file)
        let store = fixture.store()
        store.save([fixture.profile])
        var profiles = [fixture.profile]

        let d1 = try await store.prepareEdit(.deleteGroup("LegacyJSON"), to: profiles[0])
        profiles = try store.commit(d1, profiles: profiles)
        var yaml = try String(contentsOf: fixture.file, encoding: .utf8)
        XCTAssertFalse(yaml.contains("LegacyJSON"))
        XCTAssertTrue(yaml.contains("# keep section comment"))
        XCTAssertTrue(yaml.contains("name: 'First #1'"))
        XCTAssertTrue(yaml.contains("- name: Last"))

        let d2 = try await store.prepareEdit(.deleteGroup("First #1"), to: profiles[0])
        profiles = try store.commit(d2, profiles: profiles)
        let d3 = try await store.prepareEdit(.deleteGroup("Last"), to: profiles[0])
        profiles = try store.commit(d3, profiles: profiles)
        yaml = try String(contentsOf: fixture.file, encoding: .utf8)
        XCTAssertTrue(yaml.contains("proxy-groups: []\n"), yaml)

        // Adding after deleting the last group writes clean block YAML again.
        let addBack = try await store.prepareEdit(.addGroup(CustomGroup(name: "Restored", proxies: ["DIRECT"])), to: profiles[0])
        _ = try store.commit(addBack, profiles: profiles)
        yaml = try String(contentsOf: fixture.file, encoding: .utf8)
        XCTAssertTrue(yaml.contains("proxy-groups:\n  - name: Restored\n"), yaml)
    }

    func testDeletingRulesHandlesCaseInsensitiveNoResolveCompoundAndLastRule() async throws {
        let fixture = try Fixture()
        let original = """
        mixed-port: 7890
        rules:
          - DOMAIN-SUFFIX,Google.COM,DIRECT # keep? no, line deleted
          - "IP-CIDR,192.168.1.5/24,DIRECT,no-resolve"
          - AND,((DOMAIN,a.com),(DST-PORT,443)),REJECT
          - MATCH,DIRECT
        """
        try Data(original.utf8).write(to: fixture.file)
        let store = fixture.store()
        store.save([fixture.profile])
        var profiles = [fixture.profile]

        let r1 = try await store.prepareEdit(.deleteRule(.init(index: 0, type: "DomainSuffix", payload: "google.com", proxy: "DIRECT")), to: profiles[0])
        profiles = try store.commit(r1, profiles: profiles)
        let r2 = try await store.prepareEdit(.deleteRule(.init(index: 0, type: "IPCIDR", payload: "192.168.1.5/24", proxy: "DIRECT")), to: profiles[0])
        profiles = try store.commit(r2, profiles: profiles)
        let r3 = try await store.prepareEdit(.deleteRule(.init(index: 0, type: "AND", payload: "((Domain,a.com) && (DstPort,443))", proxy: "REJECT")), to: profiles[0])
        profiles = try store.commit(r3, profiles: profiles)
        var yaml = try String(contentsOf: fixture.file, encoding: .utf8)
        XCTAssertEqual(yaml, "mixed-port: 7890\nrules:\n  - MATCH,DIRECT")

        let r4 = try await store.prepareEdit(.deleteRule(.init(index: 0, type: "Match", payload: "", proxy: "DIRECT")), to: profiles[0])
        _ = try store.commit(r4, profiles: profiles)
        yaml = try String(contentsOf: fixture.file, encoding: .utf8)
        XCTAssertEqual(yaml, "mixed-port: 7890\nrules: []")
    }

    func testDeletingReferencedGroupRejectedByValidationLeavesFilesUnchanged() async throws {
        let fixture = try Fixture()
        let original = "mixed-port: 7890\nproxy-groups:\n  - name: Proxy\n    type: select\n    proxies:\n      - DIRECT\nrules:\n  - MATCH,Proxy\n"
        try Data(original.utf8).write(to: fixture.file)
        let store = fixture.store { candidate in
            let yaml = try String(contentsOf: candidate, encoding: .utf8)
            if !yaml.contains("- name: Proxy") && yaml.contains("MATCH,Proxy") {
                throw ProfileError.invalidConfig("proxy [Proxy] not found")
            }
        }
        store.save([fixture.profile])
        let originalIndex = try Data(contentsOf: fixture.index)
        do {
            _ = try await store.prepareEdit(.deleteGroup("Proxy"), to: fixture.profile)
            XCTFail("Referenced group deletion must fail validation")
        } catch ProfileError.invalidConfig { }
        XCTAssertEqual(try Data(contentsOf: fixture.file), Data(original.utf8))
        XCTAssertEqual(try Data(contentsOf: fixture.index), originalIndex)
    }

    func testDeletingMissingRuleOrGroupThrowsWithoutModifyingFiles() async throws {
        let fixture = try Fixture()
        let store = fixture.store()
        store.save([fixture.profile])
        do {
            _ = try await store.prepareEdit(.deleteGroup("DoesNotExist"), to: fixture.profile)
            XCTFail("Expected groupNotFound")
        } catch ConfigOverlay.OverlayError.groupNotFound { }
        do {
            _ = try await store.prepareEdit(.deleteRule(.init(index: 99, type: "Domain", payload: "missing.test", proxy: "DIRECT")), to: fixture.profile)
            XCTFail("Expected ruleNotFound")
        } catch ConfigOverlay.OverlayError.ruleNotFound { }
        XCTAssertEqual(try Data(contentsOf: fixture.file), Data(fixture.original.utf8))
    }

    func testDeletingLegacyCustomItemRemovesItAndMigratesRemainingEntries() async throws {
        let fixture = try Fixture()
        fixture.profile.customRules = ["DOMAIN,legacy-keep.test,DIRECT", "DOMAIN,legacy-drop.test,DIRECT"]
        fixture.profile.customGroups = [CustomGroup(name: "KeepGroup", proxies: ["DIRECT"])]
        let store = fixture.store()
        store.save([fixture.profile])
        let edit = try await store.prepareEdit(.deleteRule(.init(index: 1, type: "Domain", payload: "legacy-drop.test", proxy: "DIRECT")), to: fixture.profile)
        let profiles = try store.commit(edit, profiles: [fixture.profile])
        let yaml = try String(contentsOf: fixture.file, encoding: .utf8)
        XCTAssertFalse(yaml.contains("legacy-drop.test"))
        XCTAssertTrue(yaml.contains("legacy-keep.test"))
        XCTAssertTrue(yaml.contains("- name: KeepGroup"))
        XCTAssertFalse(profiles[0].hasCustomization)
    }

    func testConcurrentOfficialFileChangeIsNotOverwritten() async throws {
        let fixture = try Fixture()
        let concurrent = Data("mixed-port: 8888\nrules: []\n".utf8)
        let store = fixture.store { _ in
            await Task.yield()
            try concurrent.write(to: fixture.file, options: .atomic)
        }
        store.save([fixture.profile])
        let originalIndex = try Data(contentsOf: fixture.index)
        let edit = try await store.prepareEdit(.addRule("MATCH,DIRECT"), to: fixture.profile)
        XCTAssertThrowsError(try store.commit(edit, profiles: [fixture.profile]))
        XCTAssertEqual(try Data(contentsOf: fixture.file), concurrent)
        XCTAssertEqual(try Data(contentsOf: fixture.index), originalIndex)
    }

    func testProfileDeletionDuringValidationCannotRecreateTheProfile() async throws {
        let fixture = try Fixture()
        let store = fixture.store { _ in
            await Task.yield()
            try FileManager.default.removeItem(at: fixture.file)
        }
        store.save([fixture.profile])
        let edit = try await store.prepareEdit(.addRule("MATCH,DIRECT"), to: fixture.profile)
        XCTAssertThrowsError(try store.commit(edit, profiles: [])) { error in
            guard case ProfileError.missingProfile = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
    }

    func testMetadataChangeDuringValidationIsNotOverwritten() async throws {
        let fixture = try Fixture()
        let store = fixture.store()
        store.save([fixture.profile])
        let edit = try await store.prepareEdit(.addRule("MATCH,DIRECT"), to: fixture.profile)
        var changed = fixture.profile
        changed.name = "Renamed while validating"
        XCTAssertThrowsError(try store.commit(edit, profiles: [changed]))
        XCTAssertEqual(try Data(contentsOf: fixture.file), Data(fixture.original.utf8))
        // External metadata writes are checked too, not just the in-memory profile.
        let external = Data("[]".utf8)
        try external.write(to: fixture.index, options: .atomic)
        XCTAssertThrowsError(try store.commit(edit, profiles: [fixture.profile]))
        XCTAssertEqual(try Data(contentsOf: fixture.index), external)
    }

    func testMetadataWriteFailureRollsBackOfficialYAML() async throws {
        let fixture = try Fixture()
        fixture.profile.customRules = ["DOMAIN,legacy.test,DIRECT"]
        // A missing parent allows preparation but makes the metadata rename fail.
        let impossibleIndex = fixture.directory.appendingPathComponent("missing/profiles.json")
        let store = ProfileStore(profilesDirectory: fixture.directory, indexURL: impossibleIndex, validate: { _ in })
        let edit = try await store.prepareEdit(.addRule("MATCH,DIRECT"), to: fixture.profile)
        XCTAssertThrowsError(try store.commit(edit, profiles: [fixture.profile]))
        XCTAssertEqual(try Data(contentsOf: fixture.file), Data(fixture.original.utf8))
        XCTAssertTrue(fixture.profile.hasCustomization)
        XCTAssertFalse(FileManager.default.fileExists(atPath: impossibleIndex.path))
    }

    func testMissingProfileFileIsRejectedBeforeValidation() async throws {
        let fixture = try Fixture()
        try FileManager.default.removeItem(at: fixture.file)
        var validated = false
        let store = fixture.store { _ in validated = true }
        do {
            _ = try await store.prepareEdit(.addRule("MATCH,DIRECT"), to: fixture.profile)
            XCTFail("A missing profile must not report success")
        } catch ProfileError.missingProfile { }
        XCTAssertFalse(validated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
    }

    func testLegacyProfilesLoadWithoutRewritingAnyFiles() throws {
        let fixture = try Fixture()
        fixture.profile.customRules = ["DOMAIN,legacy.test,DIRECT"]
        fixture.profile.customGroups = [CustomGroup(name: "Legacy", proxies: ["DIRECT"])]
        let store = fixture.store()
        store.save([fixture.profile])
        let originalIndex = try Data(contentsOf: fixture.index)
        let loaded = store.load()
        XCTAssertEqual(loaded, [fixture.profile])
        XCTAssertEqual(try Data(contentsOf: fixture.index), originalIndex)
        XCTAssertEqual(try Data(contentsOf: fixture.file), Data(fixture.original.utf8))
        let runtime = try ConfigOverlay.apply(rules: loaded[0].customRules ?? [], groups: loaded[0].customGroups ?? [], to: fixture.original)
        XCTAssertTrue(runtime.contains("DOMAIN,legacy.test,DIRECT"))
        XCTAssertTrue(runtime.contains("- name: Legacy"))
    }

    func testCommittingAnEditDoesNotMigrateOtherProfiles() async throws {
        let fixture = try Fixture()
        var other = fixture.profile
        other.id = UUID()
        other.fileName = "other.yaml"
        other.customRules = ["DOMAIN,other-legacy.test,DIRECT"]
        let otherFile = fixture.directory.appendingPathComponent(other.fileName)
        try Data(fixture.original.utf8).write(to: otherFile)
        let store = fixture.store()
        store.save([fixture.profile, other])
        let edit = try await store.prepareEdit(.addRule("DOMAIN,new.test,DIRECT"), to: fixture.profile)
        let profiles = try store.commit(edit, profiles: [fixture.profile, other])
        XCTAssertEqual(profiles[1], other)
        XCTAssertTrue(store.load()[1].hasCustomization)
        XCTAssertEqual(try Data(contentsOf: otherFile), Data(fixture.original.utf8))
    }

    func testStalePreparedEditCannotOverwriteAnEarlierCommit() async throws {
        let fixture = try Fixture()
        let store = fixture.store()
        store.save([fixture.profile])
        let first = try await store.prepareEdit(.addRule("DOMAIN,first.test,DIRECT"), to: fixture.profile)
        let second = try await store.prepareEdit(.addRule("DOMAIN,second.test,DIRECT"), to: fixture.profile)
        let profiles = try store.commit(first, profiles: [fixture.profile])
        XCTAssertThrowsError(try store.commit(second, profiles: profiles))
        let yaml = try String(contentsOf: fixture.file, encoding: .utf8)
        XCTAssertTrue(yaml.contains("DOMAIN,first.test,DIRECT"))
        XCTAssertFalse(yaml.contains("DOMAIN,second.test,DIRECT"))
    }

    func testRuleIsValidatedBeforeOfficialYAMLAndMetadataAreCommitted() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = directory.appendingPathComponent("profiles.json")
        let profile = Profile(name: "Test", kind: .local, fileName: "test.yaml", updatedAt: Date(timeIntervalSince1970: 1_700_000_000), updateInterval: 0)
        let file = directory.appendingPathComponent(profile.fileName)
        let original = "# keep this\nmixed-port: 7890\nrules:\n  - MATCH,DIRECT\ndns:\n  enable: false\n"
        try Data(original.utf8).write(to: file)
        var validations = 0
        let store = ProfileStore(profilesDirectory: directory, indexURL: index) { candidate in
            validations += 1
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original)
            let yaml = try String(contentsOf: candidate, encoding: .utf8)
            XCTAssertTrue(yaml.contains("  - DOMAIN,example.com,DIRECT\n  - MATCH,DIRECT"), yaml)
        }
        store.save([profile])
        let originalIndex = try Data(contentsOf: index)
        let edit = try await store.prepareEdit(.addRule("DOMAIN,example.com,DIRECT"), to: profile)
        XCTAssertEqual(try Data(contentsOf: index), originalIndex)
        let updated = try store.commit(edit, profiles: [profile])
        XCTAssertEqual(validations, 1)
        XCTAssertEqual(updated, store.load())
        let yaml = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(yaml.hasPrefix("# keep this\nmixed-port: 7890\n"))
        XCTAssertTrue(yaml.hasSuffix("dns:\n  enable: false\n"))
        XCTAssertFalse(updated[0].hasCustomization)
    }

    func testEditingRuleReplacesInPlacePreservingIndentCommentAndOrder() async throws {
        let fixture = try Fixture()
        let original = "rules:\n    - DOMAIN-SUFFIX,Google.COM,DIRECT # 谷歌\n    - \"IP-CIDR,10.0.0.0/8,DIRECT,no-resolve\"\n    - MATCH,DIRECT\n"
        try Data(original.utf8).write(to: fixture.file)
        let store = fixture.store()
        store.save([fixture.profile])

        let target = ConfigOverlay.RuleTarget(index: 0, type: "DomainSuffix", payload: "google.com", proxy: "DIRECT")
        XCTAssertEqual(store.ruleText(target, in: fixture.profile), "DOMAIN-SUFFIX,Google.COM,DIRECT")
        let cidr = ConfigOverlay.RuleTarget(index: 1, type: "IPCIDR", payload: "10.0.0.0/8", proxy: "DIRECT")
        XCTAssertEqual(store.ruleText(cidr, in: fixture.profile), "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve")

        var profiles = [fixture.profile]
        let r1 = try await store.prepareEdit(.updateRule(target, "DOMAIN,mail.google.com,REJECT"), to: profiles[0])
        profiles = try store.commit(r1, profiles: profiles)
        let r2 = try await store.prepareEdit(.updateRule(cidr, "IP-CIDR,10.0.0.0/16,REJECT"), to: profiles[0])
        _ = try store.commit(r2, profiles: profiles)
        let yaml = try String(contentsOf: fixture.file, encoding: .utf8)
        XCTAssertEqual(yaml, "rules:\n    - DOMAIN,mail.google.com,REJECT # 谷歌\n    - IP-CIDR,10.0.0.0/16,REJECT\n    - MATCH,DIRECT\n")

        do {
            _ = try await store.prepareEdit(.updateRule(.init(index: 5, type: "Domain", payload: "none.example", proxy: "DIRECT"), "MATCH,DIRECT"), to: profiles[0])
            XCTFail("Editing a missing rule should throw")
        } catch {}
    }

    func testEditingGroupRewritesManagedFieldsAndKeepsOtherKeys() async throws {
        let fixture = try Fixture()
        let original = """
        proxy-groups:
        - name: 香港
          type: url-test
          use:
            - provider1
          proxies: [DIRECT, REJECT]
          lazy: true # 保留
          url: https://cp.cloudflare.com
          interval: 600
          filter: '香港|HK'
        - {"name":"旧组","type":"select","proxies":["DIRECT"],"icon":"x.png"}
        rules:
          - MATCH,香港

        """
        try Data(original.utf8).write(to: fixture.file)
        let store = fixture.store()
        store.save([fixture.profile])

        var hk = try XCTUnwrap(store.group(named: "香港", in: fixture.profile))
        XCTAssertEqual(hk.type, "url-test")
        XCTAssertEqual(hk.proxies, ["DIRECT", "REJECT"])
        XCTAssertEqual(hk.url, "https://cp.cloudflare.com")
        XCTAssertEqual(hk.interval, 600)
        XCTAssertEqual(hk.filter, "香港|HK")
        hk.type = "fallback"
        hk.proxies = ["REJECT"]
        hk.interval = 300

        var profiles = [fixture.profile]
        let r1 = try await store.prepareEdit(.updateGroup("香港", hk), to: profiles[0])
        profiles = try store.commit(r1, profiles: profiles)

        var old = try XCTUnwrap(store.group(named: "旧组", in: profiles[0]))
        XCTAssertEqual(old.proxies, ["DIRECT"])
        old.proxies = ["DIRECT", "REJECT"]
        let r2 = try await store.prepareEdit(.updateGroup("旧组", old), to: profiles[0])
        _ = try store.commit(r2, profiles: profiles)

        let yaml = try String(contentsOf: fixture.file, encoding: .utf8)
        XCTAssertEqual(yaml, """
        proxy-groups:
        - name: 香港
          type: fallback
          proxies:
            - REJECT
          url: https://cp.cloudflare.com
          interval: 300
          filter: '香港|HK'
          use:
            - provider1
          lazy: true # 保留
        - name: 旧组
          type: select
          proxies:
            - DIRECT
            - REJECT
          icon: x.png
        rules:
          - MATCH,香港

        """)
    }

    func testGroupSummariesAndRuleItemsParseBlockAndFlowYAMLForDeferredRestartSync() {
        let blockYAML = """
        proxy-groups:
          - name: Proxy
            type: select
            proxies:
              - 香港
              - DIRECT
          - name: 自动
            type: url-test
            include-all: true
        rules:
          - DOMAIN-SUFFIX,example.com,Proxy
          - RULE-SET,cncidr,DIRECT,no-resolve
          - AND,((DOMAIN,a.com),(DST-PORT,443)),REJECT
          - MATCH,Proxy
        """
        XCTAssertEqual(ConfigOverlay.groupSummaries(in: blockYAML), [
            .init(name: "Proxy", apiType: "Selector", proxies: ["香港", "DIRECT"], includeAll: false),
            .init(name: "自动", apiType: "URLTest", proxies: [], includeAll: true),
        ])
        XCTAssertEqual(ConfigOverlay.ruleItems(in: blockYAML), [
            RuleItem(index: 0, type: "DomainSuffix", payload: "example.com", proxy: "Proxy"),
            RuleItem(index: 1, type: "RuleSet", payload: "cncidr", proxy: "DIRECT"),
            RuleItem(index: 2, type: "AND", payload: "((DOMAIN,a.com),(DST-PORT,443))", proxy: "REJECT"),
            RuleItem(index: 3, type: "Match", payload: "", proxy: "Proxy"),
        ])

        let flowYAML = """
        proxy-groups: [{name: Existing, type: select, proxies: [DIRECT]}, {"name":"Auto","type":"fallback","proxies":["Existing"]}]
        rules: ["DOMAIN,a.test,Existing", 'MATCH,DIRECT']
        """
        XCTAssertEqual(ConfigOverlay.groupSummaries(in: flowYAML), [
            .init(name: "Existing", apiType: "Selector", proxies: ["DIRECT"], includeAll: false),
            .init(name: "Auto", apiType: "Fallback", proxies: ["Existing"], includeAll: false),
        ])
        XCTAssertEqual(ConfigOverlay.ruleItems(in: flowYAML), [
            RuleItem(index: 0, type: "Domain", payload: "a.test", proxy: "Existing"),
            RuleItem(index: 1, type: "Match", payload: "", proxy: "DIRECT"),
        ])
    }

    func testDashboardURLUsesLocalUIAndHTTPParameter() {
        let local = AppState.dashboardURL(port: 19090, secret: "sec-123", useLocalUI: true)
        XCTAssertEqual(local?.absoluteString,
                       "http://127.0.0.1:19090/ui/#/setup?hostname=127.0.0.1&port=19090&secret=sec-123&http=1")

        let remote = AppState.dashboardURL(port: 19090, secret: "sec-123", useLocalUI: false)
        XCTAssertEqual(remote?.absoluteString,
                       "https://metacubex.github.io/metacubexd/#/setup?hostname=127.0.0.1&port=19090&secret=sec-123&http=1")
    }

    func testSanitizedStemAndUniqueFileNameHandleSpecialCharsAndCollisions() throws {
        XCTAssertEqual(ProfileStore.sanitizedStem(for: "  机场 A/主线:1  "), "机场 A-主线-1")
        XCTAssertEqual(ProfileStore.sanitizedStem(for: "..hidden.yaml"), "hidden")
        XCTAssertEqual(ProfileStore.sanitizedStem(for: "   .yml "), "配置")
        XCTAssertEqual(ProfileStore.sanitizedStem(for: "我的配置.YAML"), "我的配置")

        let fixture = try Fixture()
        let store = fixture.store()
        let first = Profile(name: "My Sub", kind: .remote, fileName: "My Sub.yaml", updatedAt: Date())
        let colliding = store.uniqueFileName(for: "my sub", in: [first])
        XCTAssertEqual(colliding, "my sub-2.yaml")

        // Case-only rename for the same profile is allowed on macOS case-insensitive disk
        let renamedSame = store.uniqueFileName(for: "test", currentFileName: "test.yaml", excludingProfileID: fixture.profile.id, in: [fixture.profile])
        XCTAssertEqual(renamedSame, "test.yaml")
    }

    func testSaveProfileRenamesProfileAndRuntimeFilesAndRollsBackOnIndexFailure() throws {
        let fixture = try Fixture()
        let runtimeDir = fixture.directory.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
        let store = ProfileStore(profilesDirectory: fixture.directory, runtimeDirectory: runtimeDir, indexURL: fixture.index, validate: { _ in })
        try Data("runtime: true\n".utf8).write(to: runtimeDir.appendingPathComponent(fixture.profile.fileName))
        store.save([fixture.profile])

        var edited = fixture.profile
        edited.name = "主力订阅"
        let updated = try store.saveProfile(edited, in: [fixture.profile])
        XCTAssertEqual(updated[0].name, "主力订阅")
        XCTAssertEqual(updated[0].fileName, "主力订阅.yaml")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("test.yaml").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("主力订阅.yaml").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtimeDir.appendingPathComponent("test.yaml").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtimeDir.appendingPathComponent("主力订阅.yaml").path))
        XCTAssertEqual(store.load(), updated)

        // Rollback file move if writing profiles.json fails
        let badIndex = fixture.directory.appendingPathComponent("missing/profiles.json")
        let failingStore = ProfileStore(profilesDirectory: fixture.directory, runtimeDirectory: runtimeDir, indexURL: badIndex, validate: { _ in })
        var secondEdit = updated[0]
        secondEdit.name = "失败回滚"
        XCTAssertThrowsError(try failingStore.saveProfile(secondEdit, in: updated))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("主力订阅.yaml").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("失败回滚.yaml").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtimeDir.appendingPathComponent("主力订阅.yaml").path))
    }

    func testReconcileFileNamesMigratesLegacyUUIDFileNamesToMatchDisplayNames() throws {
        let fixture = try Fixture()
        let runtimeDir = fixture.directory.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
        let store = ProfileStore(profilesDirectory: fixture.directory, runtimeDirectory: runtimeDir, indexURL: fixture.index, validate: { _ in })

        let p1 = Profile(name: "公司机场", kind: .remote, fileName: "\(UUID().uuidString).yaml", updatedAt: Date())
        let p2 = Profile(name: "公司机场", kind: .remote, fileName: "\(UUID().uuidString).yaml", updatedAt: Date())
        try Data("a: 1\n".utf8).write(to: fixture.directory.appendingPathComponent(p1.fileName))
        try Data("b: 2\n".utf8).write(to: fixture.directory.appendingPathComponent(p2.fileName))
        store.save([p1, p2])

        let reconciled = store.reconcileFileNames(store.load())
        XCTAssertEqual(reconciled.map(\.fileName), ["公司机场.yaml", "公司机场-2.yaml"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("公司机场.yaml").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("公司机场-2.yaml").path))
        XCTAssertEqual(store.load(), reconciled)
    }
}
