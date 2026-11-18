import Foundation
import Testing
@testable import TinyClash

@Suite
struct ProfileNodesTests {
    @Test func parsesBlockAndFlowProxiesWithNestedOptions() {
        let yaml = """
        port: 7890
        proxies:
          - name: "香港 01"
            type: vmess
            server: 1.2.3.4
            port: 443
            udp: true
            ws-opts:
              path: /ws
          - {name: 日本 02, type: ss, server: 5.6.7.8, port: 8388, plugin-opts: {mode: websocket}, udp: false}
          - name: 新加坡 03 # inline comment
            type: trojan
        proxy-groups:
          - name: Proxy
            type: select
            proxies:
              - "香港 01"
        """
        let items = ConfigOverlay.proxyItems(in: yaml)
        #expect(items.map(\.name) == ["香港 01", "日本 02", "新加坡 03"])
        #expect(items.map(\.type) == ["vmess", "ss", "trojan"])
        #expect(items.map(\.udp) == [true, false, nil])
    }

    @Test func parsesProxyProvidersIncludingInlinePayload() {
        let yaml = """
        proxy-providers:
          airport-a:
            type: http
            url: "https://example.com/sub-a"
            path: ./providers/a.yaml
            interval: 3600
          airport-b:
            type: file
            path: /tmp/b.yaml
          local-inline:
            type: inline
            payload:
              - {name: 直连测试, type: vless, server: 9.9.9.9, port: 443, udp: true}
        """
        let providers = ConfigOverlay.proxyProviders(in: yaml)
        #expect(providers.count == 3)
        #expect(providers[0].name == "airport-a")
        #expect(providers[0].type == "http")
        #expect(providers[0].url == "https://example.com/sub-a")
        #expect(providers[0].path == "./providers/a.yaml")
        #expect(providers[1].name == "airport-b")
        #expect(providers[1].type == "file")
        #expect(providers[2].name == "local-inline")
        #expect(providers[2].payload.map(\.name) == ["直连测试"])
        #expect(providers[2].payload.map(\.type) == ["vless"])
    }

    @Test func liveSectionsSeparateMultipleProvidersAndInlineProfileNodes() {
        let profile = Profile(name: "主配置", kind: .remote, url: "https://example.com/sub",
                              fileName: "main.yaml", updatedAt: Date())
        let p1 = ProviderItem(
            name: "ProviderA",
            type: "Proxy",
            vehicleType: "HTTP",
            proxies: [ProxyItem(name: "A-1", type: "Trojan", udp: true)],
            subscriptionInfo: .init(Upload: 1024, Download: 2048, Total: 10_240, Expire: 1_800_000_000)
        )
        let p2 = ProviderItem(
            name: "ProviderB",
            type: "Proxy",
            vehicleType: "File",
            proxies: [ProxyItem(name: "B-1", type: "Shadowsocks")],
            subscriptionInfo: .init(Upload: 512, Download: 1024, Total: 20_480, Expire: 1_900_000_000)
        )
        let proxies: [String: ProxyItem] = [
            "GLOBAL": ProxyItem(name: "GLOBAL", type: "Selector", now: "Proxy", all: ["Proxy", "Inline-2", "Inline-1", "DIRECT"]),
            "Proxy": ProxyItem(name: "Proxy", type: "Selector", now: "A-1", all: ["A-1", "B-1", "Inline-2", "Inline-1"]),
            "DIRECT": ProxyItem(name: "DIRECT", type: "Direct"),
            "PASS": ProxyItem(name: "PASS", type: "Pass"),
            "PASS-RULE": ProxyItem(name: "PASS-RULE", type: "PassRule", udp: true),
            "REJECT-DROP": ProxyItem(name: "REJECT-DROP", type: "RejectDrop"),
            "DNS": ProxyItem(name: "DNS", type: "Dns"),
            "Inline-1": ProxyItem(name: "Inline-1", type: "Vless"),
            "Inline-2": ProxyItem(name: "Inline-2", type: "Hysteria2"),
            // Provider nodes merged into /proxies shouldn't duplicate into the profile section
            "A-1": ProxyItem(name: "A-1", type: "Trojan"),
        ]

        let sections = ProfileNodes.liveSections(for: profile, providers: [p1, p2], proxies: proxies)
        #expect(sections.count == 3)
        #expect(sections[0].title == "ProviderA")
        #expect(sections[0].nodes.map(\.name) == ["A-1"])
        #expect(sections[1].title == "ProviderB")
        #expect(sections[1].nodes.map(\.name) == ["B-1"])
        #expect(sections[2].title == "主配置")
        #expect(sections[2].nodes.map(\.name) == ["Inline-2", "Inline-1"])

        let sub1 = SubscriptionInfo(dto: p1.subscriptionInfo)
        let sub2 = SubscriptionInfo(dto: p2.subscriptionInfo)
        #expect(sub1?.used == 3072)
        #expect(sub1?.total == 10_240)
        #expect(sub1?.expire == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(sub2?.used == 1536)
        #expect(sub2?.total == 20_480)
        #expect(sub2?.expire == Date(timeIntervalSince1970: 1_900_000_000))
    }

    @Test func offlineSectionsReadCachedProviderFilesAndProfileProxies() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("providers"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("proxies:\n  - {name: 节点1, type: ss}\n".utf8)
            .write(to: dir.appendingPathComponent("providers/sub.yaml"))

        let profileURL = dir.appendingPathComponent("main.yaml")
        let yaml = """
        proxy-providers:
          机场订阅:
            type: http
            url: https://example.com/sub
            path: ./providers/sub.yaml
          未缓存订阅:
            type: http
            url: https://example.com/missing
        proxies:
          - name: 自建节点
            type: trojan
        """
        try Data(yaml.utf8).write(to: profileURL)

        let profile = Profile(name: "测试配置", kind: .local, fileName: "main.yaml", updatedAt: Date())
        let sections = ProfileNodes.offlineSections(for: profile, isActiveProfile: true, fileURL: profileURL, home: dir)
        #expect(sections.count == 3)
        #expect(sections[0].title == "机场订阅")
        #expect(sections[0].nodes.map(\.name) == ["节点1"])
        #expect(sections[1].title == "未缓存订阅")
        #expect(sections[1].nodes.isEmpty)
        #expect(sections[1].offlineHint != nil)
        #expect(sections[2].title == "测试配置")
        #expect(sections[2].nodes.map(\.name) == ["自建节点"])
    }

    @Test func pendingOfflineProvidersSurfacesProvidersAddedBeforeCoreReload() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let profileURL = dir.appendingPathComponent("main.yaml")
        let yaml = """
        proxy-providers:
          cc:
            type: http
            url: https://example.com/cc
          c2:
            type: http
            url: https://example.com/c2
        """
        try Data(yaml.utf8).write(to: profileURL)

        let profile = Profile(name: "mihomo_config", kind: .local, fileName: "main.yaml", updatedAt: Date())
        let pending = ProfileNodes.pendingOfflineProviders(for: profile, loadedProviderNames: ["cc"],
                                                            fileURL: profileURL, home: dir)
        #expect(pending.count == 1)
        #expect(pending[0].title == "c2")
        #expect(pending[0].offlineHint?.contains("重新加载") == true)
    }

    @Test func resolveProviderSubscriptionsCoversSameURLAndDistinctMissingProviders() {
        let yamlProviders = [
            ProxyProviderDefinition(name: "cc", type: "http", url: "https://example.com/sub1", path: ""),
            ProxyProviderDefinition(name: "c2", type: "http", url: "https://example.com/sub1", path: ""),
            ProxyProviderDefinition(name: "c3", type: "http", url: "https://example.com/sub2", path: ""),
        ]
        let runtimeProviders = [
            ProviderItem(
                name: "cc",
                type: "Proxy",
                vehicleType: "HTTP",
                subscriptionInfo: .init(Upload: 100, Download: 200, Total: 1000, Expire: 1_800_000_000)
            ),
            ProviderItem(name: "c2", type: "Proxy", vehicleType: "HTTP", subscriptionInfo: nil),
            ProviderItem(name: "c3", type: "Proxy", vehicleType: "HTTP", subscriptionInfo: nil),
        ]

        let resolved = ProfileNodes.resolveProviderSubscriptions(
            yamlProviders: yamlProviders,
            runtimeProviders: runtimeProviders,
            cached: []
        )
        #expect(resolved.subscriptions.map(\.name) == ["cc", "c2"])
        #expect(resolved.subscriptions[0].subscription.total == 1000)
        #expect(resolved.subscriptions[1].subscription.total == 1000)
        #expect(resolved.missingHTTP.map(\.name) == ["c3"])
    }
}
