import Foundation
import Testing
@testable import TinyClash

@Suite @MainActor
struct RuleProviderPersistenceTests {
    private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var profile = Profile(name: "Test", kind: .local, fileName: "test.yaml",
                              updatedAt: Date(timeIntervalSince1970: 1_700_000_000), updateInterval: 0)
        var index: URL { directory.appendingPathComponent("profiles.json") }
        var file: URL { directory.appendingPathComponent(profile.fileName) }
        let original: String

        init(_ yaml: String = "# untouched\nmixed-port: 7890\nrules:\n  - MATCH,DIRECT\n") throws {
            original = yaml
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(yaml.utf8).write(to: file)
        }

        func store(validate: @escaping (URL) async throws -> Void = { _ in }) -> ProfileStore {
            ProfileStore(profilesDirectory: directory, indexURL: index, validate: validate)
        }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    @Test func editingPreservesUnknownFieldsCommentsCRLFAndOtherSections() throws {
        let original = "# heading\r\nmixed-port: 7890\r\nrule-providers:    # providers\r\n    'first #1': # name\r\n        type: http\r\n        url: https://example.com/old.yaml\r\n        interval: 60\r\n        header: # custom header\r\n            User-Agent:\r\n                - 'TinyClash # test'\r\n        proxy: DIRECT # download proxy\r\n        size-limit: 100000\r\n        # provider tail\r\n    second:\r\n        type: file\r\n        path: ./rules/second.yaml\r\n# section tail\r\nrules:\r\n  - MATCH,DIRECT\r\n# document tail\r\n"
        let providers = try ConfigOverlay.ruleProviders(in: original)
        #expect(providers.map(\.name) == ["first #1", "second"])
        #expect(providers[0].interval == 60)
        #expect(providers[1].type == "file")
        var changed = providers[0]
        changed.url = "https://example.com/new.yaml"
        changed.interval = 3600
        let updated = try ConfigOverlay.replaceRuleProvider(named: changed.name, with: changed, in: original)
        #expect(updated.hasPrefix("# heading\r\nmixed-port: 7890\r\nrule-providers:    # providers\r\n    'first #1': # name\r\n"))
        #expect(updated.contains("        header: # custom header\r\n            User-Agent:\r\n                - 'TinyClash # test'\r\n        proxy: DIRECT # download proxy\r\n        size-limit: 100000\r\n        # provider tail\r\n"))
        #expect(updated.hasSuffix("    second:\r\n        type: file\r\n        path: ./rules/second.yaml\r\n# section tail\r\nrules:\r\n  - MATCH,DIRECT\r\n# document tail\r\n"))
        let added = try ConfigOverlay.addRuleProvider(RuleProviderDefinition(name: "third", type: "file", path: "./third.yaml"), to: updated)
        #expect(added.contains("rule-providers:    # providers\r\n"))
        #expect(!added.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        let removed = try ConfigOverlay.removeRuleProvider(named: "first #1", from: added)
        #expect(removed.contains("        # provider tail\r\n"))
        #expect(try ConfigOverlay.ruleProviders(in: removed).map(\.name) == ["second", "third"])
        #expect(removed.hasSuffix("# document tail\r\n"))
    }

    @Test func inlinePayloadSupportsBlockIndentlessAndFlowStringLists() throws {
        let yaml = "rule-providers:\n  'inline: rules':\n    type: inline\n    behavior: classical\n    payload:\n    - 'DOMAIN,example.com'\n    - 'DOMAIN-SUFFIX,example.org' # keep\n    - 'DOMAIN,can''t.example'\n  flow:\n    type: inline\n    payload: [\"+.example.com\", 'example # test', example.org]\n# trailing comment\n"
        let providers = try ConfigOverlay.ruleProviders(in: yaml)
        #expect(providers[0].payload == ["DOMAIN,example.com", "DOMAIN-SUFFIX,example.org", "DOMAIN,can't.example"])
        #expect(providers[1].payload == ["+.example.com", "example # test", "example.org"])
        var changed = providers[0]
        changed.payload = ["DOMAIN,new.example", "DOMAIN,with # hash.example"]
        let updated = try ConfigOverlay.replaceRuleProvider(named: changed.name, with: changed, in: yaml)
        #expect(try ConfigOverlay.ruleProviders(in: updated) == [changed, providers[1]])
        #expect(updated.contains("# keep"))
        #expect(updated.hasSuffix("# trailing comment\n"))
    }

    @Test func duplicatesMissingNamesAndRenamesAreExplicitErrors() throws {
        let provider = RuleProviderDefinition(name: "existing", type: "file", path: "./existing.yaml")
        let yaml = try ConfigOverlay.addRuleProvider(provider, to: "rule-providers: {} # section\n# tail\n")
        #expect(throws: ConfigOverlay.RuleProviderError.self) { try ConfigOverlay.addRuleProvider(provider, to: yaml) }
        #expect(throws: ConfigOverlay.RuleProviderError.self) { try ConfigOverlay.removeRuleProvider(named: "missing", from: yaml) }
        #expect(throws: ConfigOverlay.RuleProviderError.self) { try ConfigOverlay.replaceRuleProvider(named: "missing", with: provider, in: yaml) }
        var renamed = provider
        renamed.name = "renamed"
        #expect(throws: ConfigOverlay.RuleProviderError.self) { try ConfigOverlay.replaceRuleProvider(named: "existing", with: renamed, in: yaml) }
        let duplicate = "rule-providers:\n  existing:\n    type: file\n    path: ./one.yaml\n  'existing':\n    type: file\n    path: ./two.yaml\n"
        #expect(throws: ConfigOverlay.RuleProviderError.self) { try ConfigOverlay.ruleProviders(in: duplicate) }
        #expect(throws: ConfigOverlay.RuleProviderError.self) { try ConfigOverlay.removeRuleProvider(named: "existing", from: duplicate) }
        let removed = try ConfigOverlay.removeRuleProvider(named: "existing", from: yaml)
        #expect(removed.contains("rule-providers: {}"))
        #expect(removed.hasSuffix("# tail\n"))
        #expect(try ConfigOverlay.ruleProviders(in: "mixed-port: 7890\n").isEmpty)
    }

    @Test func unsupportedYAMLNeverBecomesAPartialOrEmptyList() throws {
        let examples = [
            "rule-providers: *providers\n",
            "rule-providers: {one: {type: http, url: https://example.com}}\n",
            "rule-providers: {\"one\":{\"type\":\"file\",\"path\":\"./one.yaml\"}}\n",
            "rule-providers:\n  one: &provider\n    type: file\n    path: ./one.yaml\n",
            "rule-providers:\n  one:\n    <<: *provider\n",
            "rule-providers:\n  one:\n    type: inline\n    payload: *payload\n",
            "rule-providers:\n  one:\n    type: inline\n    payload:\n      - {domain: example.com}\n",
            "rule-providers:\n  one:\n    type: inline\n    payload:\n      - |\n        example.com\n",
            "rule-providers:\n  one:\n    type: inline\n    payload: [example.com,,example.org]\n",
            "rule-providers:\n  one:\n    type: inline\n    payload: [\"unclosed]\n",
            "rule-providers:\n  one:\n    type: file\n    path: >\n      ./one.yaml\n",
            "rule-providers:\n  one:\n    type: file\n    path: ./one.yaml\n    interval: not-an-integer\n",
            "rule-providers:\n  one:\n    type: file\n    type: http\n",
            "rule-providers:\n\tone:\n\t  type: file\n",
            "rule-providers: {}\nrule-providers: {}\n",
            "'rule-providers': {}\n",
            "\"rule\\u002dproviders\": {}\n",
            "- rule-providers: {}\n",
            "<< : *defaults\n",
            "  rule-providers: {}\n",
            "defaults: &defaults\n  rule-providers: {}\n<<: *defaults\n",
            "{\"rule-providers\": {}}\n",
            "rule-providers: {}\n---\nrule-providers: {}\n",
            "rule-providers:\n  good:\n    type: file\n    path: ./good.yaml\n  bad: *alias\n",
        ]
        let added = RuleProviderDefinition(name: "new", type: "file", path: "./new.yaml")
        for yaml in examples {
            #expect(throws: ConfigOverlay.RuleProviderError.self) { try ConfigOverlay.ruleProviders(in: yaml) }
            #expect(throws: ConfigOverlay.RuleProviderError.self) { try ConfigOverlay.addRuleProvider(added, to: yaml) }
            #expect(throws: ConfigOverlay.RuleProviderError.self) { try ConfigOverlay.removeRuleProvider(named: "good", from: yaml) }
        }
    }

    @Test func similarlyNamedNestedUnknownFieldsRemainOpaque() throws {
        let yaml = "rule-providers:\n  file:\n    type: file\n    path: ./rules.yaml\n    header:\n      rule-providers: [custom, header]\n      multiline: |\n        ---\n# tail\n"
        let provider = try #require(ConfigOverlay.ruleProviders(in: yaml).first)
        let updated = try ConfigOverlay.replaceRuleProvider(named: "file", with: provider, in: yaml)
        #expect(updated.contains("    header:\n      rule-providers: [custom, header]\n      multiline: |\n        ---\n# tail\n"))
    }

    @Test func modelValidationRejectsInvalidDefinitionsWithoutTouchingDisk() async throws {
        let fixture = try Fixture()
        var validations = 0
        let store = fixture.store { _ in validations += 1 }
        store.save([fixture.profile])
        let originalIndex = try Data(contentsOf: fixture.index)
        let invalid = [
            RuleProviderDefinition(),
            RuleProviderDefinition(name: " \t", url: "https://example.com"),
            RuleProviderDefinition(name: "bad\nname", url: "https://example.com"),
            RuleProviderDefinition(name: "rules", type: "unknown", url: "https://example.com"),
            RuleProviderDefinition(name: "rules", behavior: "unknown", url: "https://example.com"),
            RuleProviderDefinition(name: "rules", format: "unknown", url: "https://example.com"),
            RuleProviderDefinition(name: "rules", url: "ftp://example.com/rules"),
            RuleProviderDefinition(name: "rules", url: "https:///"),
            RuleProviderDefinition(name: "rules", url: "https://example.com/a b"),
            RuleProviderDefinition(name: "rules", type: "file"),
            RuleProviderDefinition(name: "rules", type: "file", path: "bad\npath"),
            RuleProviderDefinition(name: "rules", type: "inline"),
            RuleProviderDefinition(name: "rules", type: "inline", payload: [" "]),
            RuleProviderDefinition(name: "rules", type: "inline", payload: ["one\ntwo"]),
            RuleProviderDefinition(name: "rules", behavior: "classical", format: "mrs", url: "https://example.com"),
            RuleProviderDefinition(name: "rules", url: "https://example.com", interval: -1),
        ]
        for provider in invalid {
            #expect(provider.validationMessage != nil)
            do {
                _ = try await store.prepareEdit(.addRuleProvider(provider), to: fixture.profile)
                Issue.record("Invalid provider prepared a commit: \(provider)")
            } catch is ConfigOverlay.RuleProviderError { }
        }
        #expect(validations == 0)
        #expect(try Data(contentsOf: fixture.file) == Data(fixture.original.utf8))
        #expect(try Data(contentsOf: fixture.index) == originalIndex)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).allSatisfy { !$0.hasPrefix(".validate-") })
        let valid = RuleProviderDefinition(name: "rules", url: "https://example.com", interval: 0)
        #expect(valid.id == "rules")
        #expect(valid.validationMessage == nil)
        #expect(valid.type == "http" && valid.behavior == "domain" && valid.format == "yaml")
        #expect(RuleProviderDefinition(name: "rules", type: "file", path: "./rules.yaml").validationMessage == nil)
        #expect(RuleProviderDefinition(name: "rules", type: "inline", payload: ["+.example.com"]).validationMessage == nil)
        #expect(RuleProviderDefinition().interval == 86400)
    }

    @Test func strictValidationFailureAndReferencedDeletionLeaveFilesUnchanged() async throws {
        let original = "mixed-port: 7890\nrule-providers:\n  domains:\n    type: inline\n    payload:\n      - '+.example.com'\nrules:\n  - RULE-SET,domains,DIRECT\n# last comment\n"
        let fixture = try Fixture(original)
        fixture.profile.customRules = ["DOMAIN,legacy.test,DIRECT"]
        var candidates: [String] = []
        let store = fixture.store { candidate in
            #expect(try String(contentsOf: fixture.file, encoding: .utf8) == original)
            candidates.append(try String(contentsOf: candidate, encoding: .utf8))
            throw ProfileError.invalidConfig("rule provider [domains] not found or invalid")
        }
        store.save([fixture.profile])
        let originalIndex = try Data(contentsOf: fixture.index)
        for kind in [ProfileStore.ProfileEdit.deleteRuleProvider("domains"),
                     .updateRuleProvider("domains", RuleProviderDefinition(name: "domains", type: "inline", payload: ["changed.example"])),
                     .addRuleProvider(RuleProviderDefinition(name: "new", type: "file", path: "./new.yaml"))] {
            do {
                _ = try await store.prepareEdit(kind, to: fixture.profile)
                Issue.record("Strict validation failure must not prepare a commit")
            } catch ProfileError.invalidConfig { }
        }
        #expect(candidates.count == 3)
        #expect(candidates[0].contains("RULE-SET,domains,DIRECT"))
        #expect(!candidates[0].contains("  domains:"))
        #expect(try Data(contentsOf: fixture.file) == Data(original.utf8))
        #expect(try Data(contentsOf: fixture.index) == originalIndex)
        #expect(store.load()[0].hasCustomization)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).allSatisfy { !$0.hasPrefix(".validate-") })
    }

    @Test func optimisticCommitRejectsStaleProviderEdits() async throws {
        let fixture = try Fixture()
        let store = fixture.store()
        store.save([fixture.profile])
        let first = try await store.prepareEdit(.addRuleProvider(.init(name: "first", type: "file", path: "./first.yaml")), to: fixture.profile)
        let stale = try await store.prepareEdit(.addRuleProvider(.init(name: "stale", type: "file", path: "./stale.yaml")), to: fixture.profile)
        let profiles = try store.commit(first, profiles: [fixture.profile])
        #expect(throws: ProfileError.self) { try store.commit(stale, profiles: profiles) }
        #expect(try store.ruleProviders(in: profiles[0]).map(\.name) == ["first"])
        let prepared = try await store.prepareEdit(.deleteRuleProvider("first"), to: profiles[0])
        let externalIndex = Data("[]".utf8)
        try externalIndex.write(to: fixture.index)
        #expect(throws: ProfileError.self) { try store.commit(prepared, profiles: profiles) }
        #expect(try Data(contentsOf: fixture.index) == externalIndex)
        #expect(try store.ruleProviders(in: profiles[0]).map(\.name) == ["first"])
    }

    @Test func readPropagatesUnsupportedAndMissingProfileErrors() throws {
        let fixture = try Fixture("rule-providers: *providers\n")
        let store = fixture.store()
        #expect(throws: ConfigOverlay.RuleProviderError.self) { try store.ruleProviders(in: fixture.profile) }
        try FileManager.default.removeItem(at: fixture.file)
        #expect(throws: ProfileError.self) { try store.ruleProviders(in: fixture.profile) }
    }

    @Test func providerAndPolicyRuleAreValidatedAndCommittedTogether() async throws {
        let fixture = try Fixture()
        fixture.profile.customRules = ["DOMAIN,legacy.test,DIRECT"]
        let provider = RuleProviderDefinition(name: "domains", type: "inline", payload: ["+.example.com"])
        var validations = 0
        let store = fixture.store { candidate in
            validations += 1
            let yaml = try String(contentsOf: candidate, encoding: .utf8)
            #expect(try ConfigOverlay.ruleProviders(in: yaml) == [provider])
            let rules = ConfigOverlay.ruleItems(in: yaml)
            #expect(rules.map(\.payload) == ["domains", "legacy.test", ""])
            #expect(rules[0].proxy == "自动选择")
            #expect(try String(contentsOf: fixture.file, encoding: .utf8) == fixture.original)
        }
        store.save([fixture.profile])
        let edit = try await store.prepareEdit(.addRuleProvider(provider, policy: "自动选择"), to: fixture.profile)
        #expect(validations == 1)
        #expect(try String(contentsOf: fixture.file, encoding: .utf8) == fixture.original)
        let profiles = try store.commit(edit, profiles: [fixture.profile])
        #expect(!profiles[0].hasCustomization)
        #expect(try store.ruleProviders(in: store.load()[0]) == [provider])
        #expect(store.ruleItems(in: profiles[0]).first?.proxy == "自动选择")
    }

    @Test func invalidTargetPolicyRollsBackBothProviderAndRule() async throws {
        let fixture = try Fixture()
        var validations = 0
        let store = fixture.store { candidate in
            validations += 1
            let yaml = try String(contentsOf: candidate, encoding: .utf8)
            #expect(yaml.contains("RULE-SET,domains,missing-policy"))
            #expect(try ConfigOverlay.ruleProviders(in: yaml).first?.name == "domains")
            throw ProfileError.invalidConfig("proxy [missing-policy] not found")
        }
        store.save([fixture.profile])
        let index = try Data(contentsOf: fixture.index)
        do {
            _ = try await store.prepareEdit(.addRuleProvider(.init(name: "domains", type: "inline", payload: ["example.com"]),
                                                            policy: "missing-policy"), to: fixture.profile)
            Issue.record("Invalid policy must reject the entire addition")
        } catch ProfileError.invalidConfig { }
        #expect(validations == 1)
        #expect(try String(contentsOf: fixture.file, encoding: .utf8) == fixture.original)
        #expect(try Data(contentsOf: fixture.index) == index)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).allSatisfy { !$0.hasPrefix(".validate-") })
    }

    @Test func combinedCreationPreservesCRLFCommentsAndExistingRuleOrder() throws {
        let provider = RuleProviderDefinition(name: "远程 Rules #1", type: "inline", payload: ["example.com"])
        for rules in ["rules:\r\n  - DOMAIN,keep.test,DIRECT # keep\r\n  - MATCH,DIRECT",
                      "rules: [\"DOMAIN,keep.test,DIRECT\", \"MATCH,DIRECT\"] # keep"] {
            let yaml = "rule-providers: {} # providers\r\n\(rules)\r\n# tail\r\n"
            let updated = try ConfigOverlay.addRuleProvider(provider, policy: "香港策略", to: yaml)
            #expect(try ConfigOverlay.ruleProviders(in: updated) == [provider])
            #expect(ConfigOverlay.ruleItems(in: updated).map(\.payload) == [provider.name, "keep.test", ""])
            #expect(ConfigOverlay.ruleItems(in: updated).first?.proxy == "香港策略")
            #expect(updated.contains("# providers") && updated.contains("# keep"))
            #expect(updated.hasSuffix("# tail\r\n"))
            #expect(!updated.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        }
    }

    @Test func malformedAutomaticRuleFieldsAreRejectedBeforeValidation() async throws {
        let fixture = try Fixture()
        var validations = 0
        let store = fixture.store { _ in validations += 1 }
        let provider = RuleProviderDefinition(name: "domains", type: "inline", payload: ["example.com"])
        for policy in ["", "  ", "DIRECT,no-resolve", "DIRECT\n"] {
            do {
                _ = try await store.prepareEdit(.addRuleProvider(provider, policy: policy), to: fixture.profile)
                Issue.record("Malformed policy prepared a commit")
            } catch is ConfigOverlay.RuleProviderError { }
        }
        var malformed = provider
        malformed.name = "domains,other"
        #expect(throws: ConfigOverlay.RuleProviderError.self) {
            try ConfigOverlay.addRuleProvider(malformed, policy: "DIRECT", to: fixture.original)
        }
        #expect(validations == 0)
        #expect(try String(contentsOf: fixture.file, encoding: .utf8) == fixture.original)
    }

    @Test func unsupportedRulesPreventPartialProviderWrites() async throws {
        let fixture = try Fixture("mixed-port: 7890\nrules: *existingRules\n")
        var validations = 0
        let store = fixture.store { _ in validations += 1 }
        do {
            _ = try await store.prepareEdit(.addRuleProvider(.init(name: "domains", type: "inline", payload: ["example.com"]),
                                                            policy: "DIRECT"), to: fixture.profile)
            Issue.record("Unsupported rules must not save a provider by itself")
        } catch is ConfigOverlay.OverlayError { }
        #expect(validations == 0)
        #expect(try String(contentsOf: fixture.file, encoding: .utf8) == fixture.original)
    }

    @Test func providerCRUDPersistsAcrossReloads() async throws {
        let fixture = try Fixture()
        var validations = 0
        let store = fixture.store { _ in validations += 1 }
        store.save([fixture.profile])
        var profiles = [fixture.profile]
        let provider = RuleProviderDefinition(name: "domains", url: "https://example.com/rules.yaml")
        let add = try await store.prepareEdit(.addRuleProvider(provider), to: profiles[0])
        #expect(try String(contentsOf: fixture.file, encoding: .utf8) == fixture.original)
        profiles = try store.commit(add, profiles: profiles)
        #expect(try store.ruleProviders(in: store.load()[0]) == [provider])
        var changed = provider
        changed.interval = 3600
        let update = try await store.prepareEdit(.updateRuleProvider("domains", changed), to: profiles[0])
        profiles = try store.commit(update, profiles: profiles)
        #expect(try store.ruleProviders(in: profiles[0]) == [changed])
        let delete = try await store.prepareEdit(.deleteRuleProvider("domains"), to: profiles[0])
        profiles = try store.commit(delete, profiles: profiles)
        #expect(try store.ruleProviders(in: profiles[0]).isEmpty)
        #expect(try String(contentsOf: fixture.file, encoding: .utf8).contains("rule-providers: {}"))
        #expect(validations == 3)
    }
}
