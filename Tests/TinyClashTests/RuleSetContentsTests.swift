import Foundation
import Testing
@testable import TinyClash

@Suite
struct RuleSetContentsTests {
    private let home = URL(fileURLWithPath: "/tmp/tinyclash-home", isDirectory: true)

    @Test func httpProviderWithoutPathUsesCoreCacheName() {
        let provider = RuleProviderDefinition(name: "ai", type: "http",
                                              url: "https://raw.githubusercontent.com/lingmacker/Rule/refs/heads/master/stash/AI.yaml")
        let url = RuleSetContents.fileURL(for: provider, home: home)
        #expect(url?.path == "/tmp/tinyclash-home/rules/e907286ec1a2d56d970216fc4bfd17f3")
    }

    @Test func explicitPathResolvesAgainstHome() {
        var provider = RuleProviderDefinition(name: "local", type: "file", path: "./ruleset/local.txt")
        #expect(RuleSetContents.fileURL(for: provider, home: home)?.standardizedFileURL.path == "/tmp/tinyclash-home/ruleset/local.txt")
        provider.path = "/etc/rules.yaml"
        #expect(RuleSetContents.fileURL(for: provider, home: home)?.path == "/etc/rules.yaml")
    }

    @Test func yamlPayloadSkipsCommentsAndQuotes() throws {
        let yaml = """
        # NAME: Example
        # TOTAL: 4
        payload:
          # group
          - DOMAIN,example.com
          - 'DOMAIN-SUFFIX,it''s.example'

          - "IP-CIDR,1.1.1.0/24,no-resolve"
          - DOMAIN-KEYWORD,ads # trailing
        other: value
          - ignored
        """
        #expect(try RuleSetContents.yamlEntries(yaml) == [
            "DOMAIN,example.com", "DOMAIN-SUFFIX,it's.example",
            "IP-CIDR,1.1.1.0/24,no-resolve", "DOMAIN-KEYWORD,ads",
        ])
    }

    @Test func yamlPayloadAcceptsUnindentedAndFlowItems() throws {
        #expect(try RuleSetContents.yamlEntries("payload:\n- '+.a.com'\n- b.com\n") == ["+.a.com", "b.com"])
        #expect(try RuleSetContents.yamlEntries("payload: ['+.a.com', b.com]\n") == ["+.a.com", "b.com"])
        #expect(throws: RuleSetContents.LoadError.unsupportedYAML) { try RuleSetContents.yamlEntries("rules:\n  - x\n") }
    }

    @Test func textSkipsBlankAndCommentLines() {
        #expect(RuleSetContents.textEntries("# head\n+.a.com\r\n\n  // note\n1.1.1.0/24  \n") == ["+.a.com", "1.1.1.0/24"])
    }

    @Test func loadReadsInlineFileAndRejectsMRS() throws {
        let inline = RuleProviderDefinition(name: "inline", type: "inline", payload: ["DOMAIN,a.com"])
        #expect(try RuleSetContents.load(inline, home: home).entries == ["DOMAIN,a.com"])

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("payload:\n  - DOMAIN,b.com\n".utf8).write(to: dir.appendingPathComponent("b.yaml"))
        let file = RuleProviderDefinition(name: "b", type: "file", path: "b.yaml")
        let loaded = try RuleSetContents.load(file, home: dir)
        #expect(loaded.entries == ["DOMAIN,b.com"])
        #expect(loaded.modified != nil)

        let missing = RuleProviderDefinition(name: "c", type: "file", path: "c.yaml")
        #expect(throws: RuleSetContents.LoadError.self) { try RuleSetContents.load(missing, home: dir) }
        let mrs = RuleProviderDefinition(name: "d", type: "http", format: "mrs", url: "https://example.com/d.mrs")
        #expect(throws: RuleSetContents.LoadError.binaryFormat) { try RuleSetContents.load(mrs, home: dir) }
    }
}
