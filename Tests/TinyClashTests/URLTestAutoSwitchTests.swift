import Foundation
import XCTest
@testable import TinyClash

@MainActor
final class URLTestAutoSwitchTests: XCTestCase {
    private func node(_ name: String, type: String = "Shadowsocks", delay: Int? = nil) -> ProxyItem {
        var item = ProxyItem(name: name, type: type)
        if let delay {
            item.history = [.init(delay: delay, time: "2026-11-25T10:00:00Z")]
        }
        return item
    }

    private func group(_ name: String, type: String, now: String?, all: [String], testUrl: String? = nil, delay: Int? = nil) -> ProxyItem {
        var item = ProxyItem(name: name, type: type, now: now, all: all)
        item.testUrl = testUrl
        if let delay {
            item.history = [.init(delay: delay, time: "2026-11-25T09:00:00Z")]
        }
        return item
    }

    func testSwitchPlanPicksLowestPositiveDelayAndIgnoresTimeoutsAndUntested() {
        let proxies: [String: ProxyItem] = [
            "Auto": group("Auto", type: "URLTest", now: "N1", all: ["REJECT", "N1", "N2", "N3", "N4"]),
            "Manual": group("Manual", type: "Selector", now: "N1", all: ["N1", "N3"]),
            "Failover": group("Failover", type: "Fallback", now: "N1", all: ["N1", "N3"]),
            "N1": node("N1", delay: 120),
            "N2": node("N2", delay: 0),
            "N3": node("N3", delay: 35),
            "N4": node("N4", delay: nil),
            "REJECT": node("REJECT", type: "Reject", delay: 1),
        ]

        let plan = AppState.urlTestSwitchPlan(
            in: proxies,
            probedNodes: ["N1", "N2", "N3"],
            explicitGroups: ["Auto", "Manual", "Failover"]
        )
        XCTAssertEqual(plan.map(\.group), ["Auto"])
        XCTAssertEqual(plan.map(\.target), ["N3"])
    }

    func testSwitchPlanKeepsCurrentWhenTiedForMinimumAndLeavesUnrelatedGroupsUntouched() {
        let proxies: [String: ProxyItem] = [
            "HKAuto": group("HKAuto", type: "URLTest", now: "HK2", all: ["HK1", "HK2"]),
            "JPAuto": group("JPAuto", type: "URLTest", now: "JP1", all: ["JP1", "JP2"]),
            "HK1": node("HK1", delay: 28),
            "HK2": node("HK2", delay: 28),
            "JP1": node("JP1", delay: 90),
            "JP2": node("JP2", delay: 20),
        ]

        let plan = AppState.urlTestSwitchPlan(
            in: proxies,
            probedNodes: ["HK1", "HK2"],
            explicitGroups: ["HKAuto"]
        )
        XCTAssertTrue(plan.isEmpty)
    }

    func testSwitchPlanResolvesNestedURLTestGroupsBottomUp() {
        let proxies: [String: ProxyItem] = [
            "BestRegion": group("BestRegion", type: "URLTest", now: "USAuto", all: ["HKAuto", "USAuto"]),
            "HKAuto": group("HKAuto", type: "URLTest", now: "HK1", all: ["HK1", "HK2"]),
            "USAuto": group("USAuto", type: "URLTest", now: "US1", all: ["US1", "US2"]),
            "HK1": node("HK1", delay: 180),
            "HK2": node("HK2", delay: 24),
            "US1": node("US1", delay: 140),
            "US2": node("US2", delay: 110),
        ]

        let plan = AppState.urlTestSwitchPlan(
            in: proxies,
            probedNodes: ["HK1", "HK2", "US1", "US2"],
            explicitGroups: ["BestRegion", "HKAuto", "USAuto"]
        )
        XCTAssertEqual(plan.map { "\($0.group)->\($0.target)" }, [
            "HKAuto->HK2",
            "USAuto->US2",
            "BestRegion->HKAuto",
        ])
    }

    func testEffectiveDelayUsesResolvedLeafInsteadOfStaleGroupHistory() {
        let proxies: [String: ProxyItem] = [
            "Auto": group("Auto", type: "URLTest", now: "Fast", all: ["Slow", "Fast"], delay: 240),
            "Slow": node("Slow", delay: 240),
            "Fast": node("Fast", delay: 22),
        ]
        XCTAssertEqual(AppState.effectiveDelay(of: "Auto", proxies: proxies), 22)
    }

    func testSwitchPlanHandlesCyclicGroupsSafely() {
        let proxies: [String: ProxyItem] = [
            "A": group("A", type: "URLTest", now: "B", all: ["B", "N1"]),
            "B": group("B", type: "URLTest", now: "A", all: ["A", "N2"]),
            "N1": node("N1", delay: 60),
            "N2": node("N2", delay: 30),
        ]
        let plan = AppState.urlTestSwitchPlan(in: proxies, probedNodes: ["N1", "N2"])
        XCTAssertFalse(plan.isEmpty)
    }

    // MARK: - End-to-end AppState integration tests with mocked MihomoAPI

    func testManualSingleNodeAndGroupTestsSwitchURLTestGroupToLowestLatencyNode() async throws {
        let server = MockMihomoServer(
            groups: [
                .init(name: "GLOBAL", type: "Selector", now: "Proxy", all: ["Proxy", "Auto"]),
                .init(name: "Proxy", type: "Selector", now: "Auto", all: ["Auto", "HK1", "HK2"]),
                .init(name: "Auto", type: "URLTest", now: "HK1", all: ["HK1", "HK2", "ProvFast"],
                      testUrl: "http://cp.cloudflare.com/generate_204"),
            ],
            inlineNodes: ["HK1": 150, "HK2": 42],
            providerNodes: ["SubA": ["ProvFast": 18]]
        )
        let api = server.makeAPI()
        let state = AppState.shared
        let previousOverride = state.testAPIOverride
        let previousProxies = state.proxies
        let previousGroups = state.groupNames
        state.testAPIOverride = api
        defer {
            state.testAPIOverride = previousOverride
            state.proxies = previousProxies
            state.groupNames = previousGroups
            api.session.invalidateAndCancel()
        }

        await state.refreshProxies()
        XCTAssertEqual(state.proxies["Auto"]?.now, "HK1")

        // 1) 在自动选择分组内手动点击单个节点「HK2」测速：HK2(42ms) 成为已测最低延迟节点，立即切到 HK2
        await state.testProxy("HK2", inGroup: "Auto")
        XCTAssertEqual(state.proxies["Auto"]?.now, "HK2")
        XCTAssertEqual(server.selections.last, .init(group: "Auto", proxy: "HK2"))
        XCTAssertTrue(server.probedURLs["HK2"]?.contains("http://cp.cloudflare.com/generate_204") == true)

        // 2) 在父策略组「Proxy」中点击子策略「Auto」卡片上的测速：测试全部成员（含 Provider 节点）并切到 ProvFast(18ms)
        await state.testProxy("Auto", inGroup: "Proxy")
        XCTAssertEqual(state.proxies["Auto"]?.now, "ProvFast")
        XCTAssertEqual(state.delay(of: "Auto"), 18)
        XCTAssertEqual(server.selections.last, .init(group: "Auto", proxy: "ProvFast"))

        // 3) 当前选中的 ProvFast 超时（0ms），手动单测 ProvFast 后自动回退到其余已测最低延迟节点 HK2(42ms)
        server.liveDelays["ProvFast"] = 0
        await state.testProxy("ProvFast", inGroup: "Auto")
        XCTAssertEqual(state.proxies["Auto"]?.now, "HK2")
        XCTAssertEqual(server.selections.last, .init(group: "Auto", proxy: "HK2"))

        // 4) 对父策略组「Proxy」执行整组测速时，也会展开并更新子 URLTest 分组「Auto」到最新最低延迟节点 HK1(12ms)
        server.liveDelays["HK1"] = 12
        await state.testGroup("Proxy")
        XCTAssertEqual(state.proxies["Auto"]?.now, "HK1")
        XCTAssertEqual(server.selections.last, .init(group: "Auto", proxy: "HK1"))
    }
}

private final class MockMihomoServer: @unchecked Sendable {
    struct GroupSpec {
        var name: String
        var type: String
        var now: String
        var all: [String]
        var testUrl: String? = nil
    }

    struct Selection: Equatable {
        var group: String
        var proxy: String
    }

    private let lock = NSLock()
    var groups: [GroupSpec]
    var liveDelays: [String: Int]
    let providerMap: [String: [String]]
    private var recordedDelays: [String: Int] = [:]
    private(set) var selections: [Selection] = []
    private(set) var probedURLs: [String: [String]] = [:]

    init(groups: [GroupSpec], inlineNodes: [String: Int], providerNodes: [String: [String: Int]]) {
        self.groups = groups
        var delays = inlineNodes
        var pmap: [String: [String]] = [:]
        for (prov, nodes) in providerNodes {
            pmap[prov] = nodes.keys.sorted()
            for (k, v) in nodes { delays[k] = v }
        }
        self.liveDelays = delays
        self.providerMap = pmap
    }

    func makeAPI() -> MihomoAPI {
        MockMihomoURLProtocol.server = self
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockMihomoURLProtocol.self]
        return MihomoAPI(host: "mock.mihomo", port: 9090, secret: "secret", sessionConfiguration: cfg)
    }

    func handle(_ request: URLRequest) -> (Int, Data) {
        lock.lock()
        defer { lock.unlock() }

        let url = request.url!
        let method = request.httpMethod ?? "GET"
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let parts = comps.percentEncodedPath.split(separator: "/").map {
            String($0).removingPercentEncoding ?? String($0)
        }

        if method == "GET", parts == ["proxies"] {
            var dict: [String: Any] = [:]
            let providerNodeSet = Set(providerMap.values.joined())
            for g in groups {
                var item: [String: Any] = [
                    "name": g.name,
                    "type": g.type,
                    "now": g.now,
                    "all": g.all,
                    "history": [],
                ]
                if let testUrl = g.testUrl { item["testUrl"] = testUrl }
                dict[g.name] = item
            }
            for name in liveDelays.keys where !providerNodeSet.contains(name) {
                dict[name] = nodeJSON(name)
            }
            let data = try! JSONSerialization.data(withJSONObject: ["proxies": dict])
            return (200, data)
        }

        if method == "GET", parts == ["providers", "proxies"] {
            var providers: [String: Any] = [:]
            for (prov, names) in providerMap {
                providers[prov] = [
                    "name": prov,
                    "type": "Proxy",
                    "vehicleType": "File",
                    "proxies": names.map(nodeJSON),
                ]
            }
            let data = try! JSONSerialization.data(withJSONObject: ["providers": providers])
            return (200, data)
        }

        // GET /proxies/{name}/delay or GET /providers/proxies/{prov}/{name}/healthcheck
        if method == "GET",
           (parts.count == 3 && parts[0] == "proxies" && parts[2] == "delay")
            || (parts.count == 5 && parts[0] == "providers" && parts[1] == "proxies" && parts[4] == "healthcheck") {
            let name = parts.count == 3 ? parts[1] : parts[3]
            let testURL = comps.queryItems?.first(where: { $0.name == "url" })?.value ?? ""
            probedURLs[name, default: []].append(testURL)
            let d = liveDelays[name] ?? 0
            recordedDelays[name] = d
            if d > 0 {
                let data = try! JSONSerialization.data(withJSONObject: ["delay": d])
                return (200, data)
            } else {
                let data = try! JSONSerialization.data(withJSONObject: ["message": "Timeout"])
                return (504, data)
            }
        }

        // PUT /proxies/{group}
        if method == "PUT", parts.count == 2, parts[0] == "proxies" {
            let groupName = parts[1]
            let bodyData = Self.readBody(from: request)
            let body = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any]
            if let target = body?["name"] as? String,
               let idx = groups.firstIndex(where: { $0.name == groupName }) {
                groups[idx].now = target
                selections.append(.init(group: groupName, proxy: target))
                return (204, Data())
            }
            return (400, Data())
        }

        return (404, Data("Unhandled \(method) \(url.path)".utf8))
    }

    private func nodeJSON(_ name: String) -> [String: Any] {
        var history: [[String: Any]] = []
        if let d = recordedDelays[name] {
            history.append(["delay": d, "time": "2026-11-25T10:05:00Z"])
        }
        return [
            "name": name,
            "type": "Shadowsocks",
            "history": history,
        ]
    }

    private static func readBody(from request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }
}

private final class MockMihomoURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var server: MockMihomoServer?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let server = Self.server else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (code, data) = server.handle(request)
        let resp = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
