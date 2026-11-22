import Foundation
import XCTest
@testable import TinyClash

/// Inputs that previously crashed the app or silently corrupted YAML on edit.
final class ConfigHardeningTests: XCTestCase {
    // MARK: Subscription header

    func testOutOfRangeSubscriptionValuesDoNotCrash() throws {
        let info = try XCTUnwrap(SubscriptionInfo(header: "upload=1e30; download=inf; total=9223372036854775807; expire=nan"))
        XCTAssertGreaterThan(info.total, 0)
        XCTAssertEqual(info.download, 0)
        XCTAssertNil(info.expire)
        XCTAssertGreaterThan(info.used, 0, "upload + download must not overflow")
    }

    func testSubscriptionHeaderParsesNormalValues() throws {
        let info = try XCTUnwrap(SubscriptionInfo(header: "Upload=1024; download=2048 ;total=4096; expire=1700000000"))
        XCTAssertEqual(info.upload, 1024)
        XCTAssertEqual(info.download, 2048)
        XCTAssertEqual(info.total, 4096)
        XCTAssertEqual(info.expire, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(SubscriptionInfo(header: "upload=-5")?.upload, 0)
    }

    func testClashConfigDetectionIgnoresSubstrings() {
        XCTAssertFalse(ProfileStore.looksLikeClashConfig("<html>transport: none</html>"))
        XCTAssertTrue(ProfileStore.looksLikeClashConfig("# sub\nmixed-port: 7890\n"))
        XCTAssertTrue(ProfileStore.looksLikeClashConfig("proxies:\n  - name: a\n"))
    }

    // MARK: Groups

    func testBlockScalarFilterIsNotEditable() {
        let yaml = """
        proxy-groups:
          - name: HK
            type: url-test
            include-all: true
            filter: >-
              (?i)港|HK
        """
        XCTAssertNil(ConfigOverlay.group(named: "HK", in: yaml))
        var group = CustomGroup()
        group.name = "HK"
        group.type = "url-test"
        XCTAssertThrowsError(try ConfigOverlay.replaceGroup(named: "HK", with: group, in: yaml)) { error in
            guard case ConfigOverlay.OverlayError.unsupportedGroup("HK") = error else { return XCTFail("\(error)") }
        }
    }

    func testAliasAnchorAndMergeKeysAreNotEditable() {
        for body in ["    proxies: *common", "    <<: *base", "    type: !!str select"] {
            let yaml = "proxy-groups:\n  - name: G\n" + (body.contains("type") ? "" : "    type: select\n") + body + "\n"
            XCTAssertNil(ConfigOverlay.group(named: "G", in: yaml), body)
        }
    }

    func testYAMLFlowMappingGroupIsEditable() throws {
        let yaml = "proxy-groups:\n  - {name: G, type: select, proxies: [DIRECT, 'A B'], lazy: true}\nrules: []\n"
        let group = try XCTUnwrap(ConfigOverlay.group(named: "G", in: yaml))
        XCTAssertEqual(group.proxies, ["DIRECT", "A B"])
        var edited = group
        edited.proxies = ["REJECT"]
        let result = try ConfigOverlay.replaceGroup(named: "G", with: edited, in: yaml)
        XCTAssertTrue(result.contains("- REJECT"))
        XCTAssertTrue(result.contains("lazy: true"))
        XCTAssertFalse(result.contains("DIRECT"))
    }

    func testGroupEditKeepsMemberAndFieldComments() throws {
        let yaml = """
        proxy-groups:
          - name: G
            # 手动选择
            type: select
            proxies:
              # 主力
              - A # primary
              - B
              # 末尾说明
        """
        let group = try XCTUnwrap(ConfigOverlay.group(named: "G", in: yaml))
        var edited = group
        edited.proxies = ["B", "A"]
        let result = try ConfigOverlay.replaceGroup(named: "G", with: edited, in: yaml)
        XCTAssertTrue(result.contains("# 手动选择"))
        XCTAssertTrue(result.contains("# 主力\n      - A # primary"))
        XCTAssertTrue(result.contains("# 末尾说明"))
    }

    // MARK: Rules & sections

    func testRuntimeRuleTypesDisplayInYAMLSpelling() {
        let pairs = ["DomainSuffix": "DOMAIN-SUFFIX", "IPCIDR": "IP-CIDR", "GeoIP": "GEOIP", "Process": "PROCESS-NAME",
                     "RuleSet": "RULE-SET", "Match": "MATCH", "SrcIPCIDR": "SRC-IP-CIDR", "Custom": "CUSTOM"]
        for (api, yaml) in pairs { XCTAssertEqual(ConfigOverlay.yamlRuleType(api), yaml, api) }
        // Round trip with the YAML → runtime mapping used for matching.
        for name in RuleEditorPage.types.map(\.name) {
            XCTAssertEqual(ConfigOverlay.yamlRuleType(ConfigOverlay.apiRuleType(name)), name)
        }
    }

    func testStaleIndexDoesNotDeleteWrongCompoundRule() throws {
        let yaml = """
        rules:
          - AND,((DOMAIN,new.com),(NETWORK,TCP)),DIRECT
          - AND,((DOMAIN,old.com),(NETWORK,UDP)),DIRECT
          - MATCH,DIRECT
        """
        // Runtime still shows old.com at index 0 because the file changed externally.
        let target = ConfigOverlay.RuleTarget(index: 0, type: "AND", payload: "((Domain,old.com) && (Network,UDP))", proxy: "DIRECT")
        let result = try ConfigOverlay.removeRule(target, from: yaml)
        XCTAssertTrue(result.contains("new.com"))
        XCTAssertFalse(result.contains("old.com"))
    }

    func testQuotedTopLevelKeyIsFound() throws {
        let yaml = "\"rules\":\n  - MATCH,DIRECT\n"
        let result = try ConfigOverlay.addRule("DOMAIN,a.com,DIRECT", to: yaml)
        XCTAssertEqual(result.components(separatedBy: "rules").count, 2, "must not append a duplicate rules key")
        XCTAssertTrue(result.contains("- DOMAIN,a.com,DIRECT"))
    }

    func testMixedNewlinesAndNextLineFlowAreRejected() {
        XCTAssertThrowsError(try ConfigOverlay.addRule("MATCH,DIRECT", to: "mixed-port: 1\r\nproxies: []\nrules:\n  - MATCH,DIRECT\n")) { error in
            guard case ConfigOverlay.OverlayError.mixedNewlines = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try ConfigOverlay.addRule("MATCH,DIRECT", to: "rules:\n  [DOMAIN,a.com,DIRECT]\n")) { error in
            guard case ConfigOverlay.OverlayError.flowStyle = error else { return XCTFail("\(error)") }
        }
    }

    func testAddRuleBeforeMatchKeepsMatchCommentAndFallback() throws {
        let yaml = "rules:\n  - DOMAIN,a.com,DIRECT\n  # fallback\n  - MATCH,Proxy\nother: 1\n"
        let result = try ConfigOverlay.addRule("DOMAIN,b.com,DIRECT", beforeMatch: true, to: yaml)
        XCTAssertEqual(result, "rules:\n  - DOMAIN,a.com,DIRECT\n  - DOMAIN,b.com,DIRECT\n  # fallback\n  - MATCH,Proxy\nother: 1\n")
    }

    func testMoveRuleKeepsCommentsOptionsAndCRLF() throws {
        let first = "  # private\r\n  - 'IP-CIDR,10.0.0.0/8,DIRECT,no-resolve' # LAN\r\n"
        let second = "  # fallback\r\n  - FINAL,Proxy\r\n"
        let yaml = "rules:\r\n" + first + "\r\n" + second + "port: 7890\r\n"
        let cidr = ConfigOverlay.RuleTarget(index: 0, type: "IPCIDR", payload: "10.0.0.0/8", proxy: "DIRECT")
        let match = ConfigOverlay.RuleTarget(index: 1, type: "Match", payload: "", proxy: "Proxy")
        let moved = try ConfigOverlay.moveRule(cidr, to: match, in: yaml)
        XCTAssertEqual(moved, "rules:\r\n" + second + "\r\n" + first + "port: 7890\r\n")
        XCTAssertThrowsError(try ConfigOverlay.moveRule(cidr, to: match, in: moved))
    }

    func testMoveRuleInFlowListUsesSelectedOccurrence() throws {
        let yaml = "rules: ['DOMAIN,a,DIRECT', \"DOMAIN,a,DIRECT\", 'MATCH,Proxy'] # keep"
        let domain = ConfigOverlay.RuleTarget(index: 1, type: "Domain", payload: "a", proxy: "DIRECT")
        let match = ConfigOverlay.RuleTarget(index: 2, type: "Match", payload: "", proxy: "Proxy")
        XCTAssertEqual(try ConfigOverlay.moveRule(domain, to: match, in: yaml),
                       "rules: ['DOMAIN,a,DIRECT', 'MATCH,Proxy', \"DOMAIN,a,DIRECT\"] # keep")
    }

    func testMoveRuleAcrossMultipleRowsInBothDirections() throws {
        let a = "  # first\n  - DOMAIN,a,DIRECT"
        let b = "  - DOMAIN,b,DIRECT"
        let c = "  # last\n  - DOMAIN,c,DIRECT"
        func yaml(_ rows: [String]) -> String { "rules:\n" + rows.joined(separator: "\n\n") }
        func target(_ i: Int, _ payload: String) -> ConfigOverlay.RuleTarget {
            .init(index: i, type: "Domain", payload: payload, proxy: "DIRECT")
        }
        let down = try ConfigOverlay.moveRule(target(0, "a"), to: target(2, "c"), in: yaml([a, b, c]))
        XCTAssertEqual(down, yaml([b, c, a]))
        XCTAssertEqual(try ConfigOverlay.moveRule(target(2, "a"), to: target(0, "b"), in: down), yaml([a, b, c]))
    }

    func testAddRuleBeforeMatchAppendsWithoutFallback() throws {
        let yaml = "rules:\n  - DOMAIN,a.com,DIRECT\n\nother: 1\n"
        let result = try ConfigOverlay.addRule("DOMAIN,b.com,DIRECT", beforeMatch: true, to: yaml)
        XCTAssertEqual(result, "rules:\n  - DOMAIN,a.com,DIRECT\n  - DOMAIN,b.com,DIRECT\n\nother: 1\n")
    }

    func testAddRuleBeforeMatchInFlowList() throws {
        let flow = "rules: ['DOMAIN,a.com,DIRECT', 'MATCH,DIRECT']\n"
        let result = try ConfigOverlay.addRule("DOMAIN,b.com,DIRECT", beforeMatch: true, to: flow)
        let a = try XCTUnwrap(result.range(of: "a.com")).lowerBound
        let b = try XCTUnwrap(result.range(of: "b.com")).lowerBound
        let m = try XCTUnwrap(result.range(of: "MATCH")).lowerBound
        XCTAssertTrue(a < b && b < m, result)
    }
}
