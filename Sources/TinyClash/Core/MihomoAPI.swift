import Foundation

// MARK: - Models

struct RuntimeConfig: Decodable {
    var port: Int = 0
    var socksPort: Int = 0
    var mixedPort: Int = 0
    var allowLan: Bool = false
    var mode: String = "rule"
    var logLevel: String = "info"
    var ipv6: Bool = false
    var tun: TunConfig?

    struct TunConfig: Decodable {
        var enable: Bool
        var stack: String?
        var device: String?
        var inet4Address: [String]?

        enum CodingKeys: String, CodingKey {
            case enable, stack, device
            case inet4Address = "inet4-address"
        }
    }

    enum CodingKeys: String, CodingKey {
        case port, mode, ipv6, tun
        case socksPort = "socks-port"
        case mixedPort = "mixed-port"
        case allowLan = "allow-lan"
        case logLevel = "log-level"
    }

    /// 系统代理使用的 HTTP 端口与 SOCKS 端口
    var httpPort: Int { mixedPort > 0 ? mixedPort : port }
    var socksProxyPort: Int { mixedPort > 0 ? mixedPort : socksPort }
}

struct ProxyItem: Decodable, Identifiable {
    var id: String { name }
    var name: String
    var type: String
    var now: String?
    var all: [String]?
    var hidden: Bool?
    var udp: Bool?
    var history: [DelayHistory]?
    /// 用非默认测速地址测得的结果按地址分别存放：extra[url].history
    var extra: [String: ExtraInfo]?
    var testUrl: String?

    struct DelayHistory: Decodable {
        var delay: Int
        var time: String?
    }

    struct ExtraInfo: Decodable { var history: [DelayHistory]? }

    var isGroup: Bool { all != nil }
    var isSelectable: Bool { type == "Selector" }

    /// 最近一次测速结果（默认地址与各自定义地址中取时间最新的一条）
    var lastDelay: Int? {
        let candidates = ([history?.last] + (extra ?? [:]).values.map { $0.history?.last }).compactMap { $0 }
        return candidates.max { ($0.time ?? "") < ($1.time ?? "") }?.delay
    }
}

extension ProxyItem {
    init(name: String, type: String, now: String? = nil, all: [String]? = nil) {
        self.name = name
        self.type = type
        self.now = now
        self.all = all
        self.hidden = nil
        self.udp = nil
        self.history = nil
        self.extra = nil
        self.testUrl = nil
    }
}

struct ProxiesResponse: Decodable { var proxies: [String: ProxyItem] }

struct RuleItem: Decodable, Identifiable, Hashable {
    var id: String { "\(index ?? 0)-\(type)-\(payload)" }
    var index: Int?
    var type: String
    var payload: String
    var proxy: String
}

struct RulesResponse: Decodable { var rules: [RuleItem] }

struct ProviderItem: Decodable, Identifiable {
    var id: String { name }
    var name: String
    var type: String
    var vehicleType: String
    var updatedAt: String?
    var proxies: [ProxyItem]?
    var ruleCount: Int?
    var behavior: String?
    var subscriptionInfo: SubscriptionInfoDTO?

    struct SubscriptionInfoDTO: Decodable {
        var Upload: Int64?
        var Download: Int64?
        var Total: Int64?
        var Expire: Int64?
    }
}

struct ProvidersResponse: Decodable { var providers: [String: ProviderItem] }

struct ConnectionsSnapshot: Decodable {
    var downloadTotal: Int64
    var uploadTotal: Int64
    var connections: [Connection]?
    var memory: Int64?
}

struct Connection: Decodable, Identifiable {
    var id: String
    var metadata: Metadata
    var upload: Int64
    var download: Int64
    var start: String
    var chains: [String]
    var rule: String
    var rulePayload: String

    struct Metadata: Decodable {
        var network: String
        var type: String
        var sourceIP: String
        var destinationIP: String
        var destinationPort: String
        var host: String
        var process: String?
        var sniffHost: String?

        var displayHost: String {
            let h = host.isEmpty ? (sniffHost?.isEmpty == false ? sniffHost! : destinationIP) : host
            return "\(h):\(destinationPort)"
        }
    }

    var startDate: Date? { ISO8601DateFormatter.mihomo.date(from: start) }
}

extension ISO8601DateFormatter {
    static let mihomo: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

struct TrafficSample: Decodable { var up: Int64; var down: Int64 }
struct MemorySample: Decodable { var inuse: Int64 }
struct LogMessage: Decodable { var type: String; var payload: String }

// MARK: - Client

enum APIError: LocalizedError {
    case http(Int, String)
    case notRunning

    var errorDescription: String? {
        switch self {
        case .http(let code, let msg): return "HTTP \(code): \(msg)"
        case .notRunning: return "内核未运行"
        }
    }
}

final class MihomoAPI: @unchecked Sendable {
    let host: String
    let port: Int
    let secret: String
    let session: URLSession

    init(host: String = "127.0.0.1", port: Int, secret: String) {
        self.host = host
        self.port = port
        self.secret = secret
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:] // 控制接口绝不能走代理
        cfg.timeoutIntervalForRequest = 15
        session = URLSession(configuration: cfg)
    }

    var baseURL: String { "http://\(host):\(port)" }

    private func request(_ method: String, _ path: String, body: Any? = nil, timeout: TimeInterval? = nil) async throws -> Data {
        var req = URLRequest(url: URL(string: baseURL + path)!)
        req.httpMethod = method
        req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        if let timeout { req.timeoutInterval = timeout }
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            var msg = String(decoding: data, as: UTF8.self)
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let m = obj["message"] as? String {
                msg = m
            }
            throw APIError.http(code, msg)
        }
        return data
    }

    private func get<T: Decodable>(_ path: String, as: T.Type, timeout: TimeInterval? = nil) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await request("GET", path, timeout: timeout))
    }

    func version() async throws -> String {
        let data = try await request("GET", "/version", timeout: 1)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj?["version"] as? String ?? "unknown"
    }

    func configs() async throws -> RuntimeConfig { try await get("/configs", as: RuntimeConfig.self) }

    func patchConfigs(_ body: [String: Any]) async throws {
        _ = try await request("PATCH", "/configs", body: body)
    }

    func reloadConfig(path: String) async throws {
        _ = try await request("PUT", "/configs?force=true", body: ["path": path])
    }

    func updateGeo() async throws {
        _ = try await request("POST", "/configs/geo", body: [:], timeout: 120)
    }

    func proxies() async throws -> [String: ProxyItem] { try await get("/proxies", as: ProxiesResponse.self).proxies }

    func select(group: String, proxy: String) async throws {
        _ = try await request("PUT", "/proxies/\(group.pathEscaped)", body: ["name": proxy])
    }

    func groupDelay(group: String, url: String, timeout: Int) async throws -> [String: Int] {
        let data = try await request("GET", "/group/\(group.pathEscaped)/delay?url=\(url.queryEscaped)&timeout=\(timeout)",
                                     timeout: TimeInterval(timeout) / 1000 + 30)
        return (try? JSONDecoder().decode([String: Int].self, from: data)) ?? [:]
    }

    func proxyDelay(name: String, url: String, timeout: Int) async throws -> Int {
        let data = try await request("GET", "/proxies/\(name.pathEscaped)/delay?url=\(url.queryEscaped)&timeout=\(timeout)",
                                     timeout: TimeInterval(timeout) / 1000 + 5)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj?["delay"] as? Int ?? 0
    }

    func rules() async throws -> [RuleItem] { try await get("/rules", as: RulesResponse.self).rules }

    func proxyProviders() async throws -> [ProviderItem] {
        try await get("/providers/proxies", as: ProvidersResponse.self).providers.values
            .filter { $0.vehicleType != "Compatible" }
            .sorted { $0.name < $1.name }
    }

    func ruleProviders() async throws -> [ProviderItem] {
        try await get("/providers/rules", as: ProvidersResponse.self).providers.values.sorted { $0.name < $1.name }
    }

    func updateProxyProvider(_ name: String) async throws {
        _ = try await request("PUT", "/providers/proxies/\(name.pathEscaped)", timeout: 60)
    }

    func healthcheckProvider(_ name: String) async throws {
        _ = try await request("GET", "/providers/proxies/\(name.pathEscaped)/healthcheck", timeout: 60)
    }

    func updateRuleProvider(_ name: String) async throws {
        _ = try await request("PUT", "/providers/rules/\(name.pathEscaped)", timeout: 60)
    }

    func closeConnection(_ id: String) async throws { _ = try await request("DELETE", "/connections/\(id)") }
    func closeAllConnections() async throws { _ = try await request("DELETE", "/connections") }
    func flushFakeIP() async throws { _ = try await request("POST", "/cache/fakeip/flush") }
    func flushDNS() async throws { _ = try await request("POST", "/cache/dns/flush") }

    func webSocketURL(_ path: String, query: String = "") -> URL {
        var q = "token=\(secret.queryEscaped)"
        if !query.isEmpty { q += "&" + query }
        return URL(string: "ws://\(host):\(port)\(path)?\(q)")!
    }
}

/// 自动重连的 WebSocket 流
final class StreamClient: @unchecked Sendable {
    private let url: URL
    private let session: URLSession
    private let onMessage: @Sendable (Data) -> Void
    private var task: URLSessionWebSocketTask?
    private var active = false
    private let lock = NSLock()

    init(url: URL, session: URLSession, onMessage: @escaping @Sendable (Data) -> Void) {
        self.url = url
        self.session = session
        self.onMessage = onMessage
    }

    func start() {
        lock.lock(); active = true; lock.unlock()
        connect()
    }

    func stop() {
        lock.lock(); active = false; let t = task; task = nil; lock.unlock()
        t?.cancel(with: .goingAway, reason: nil)
    }

    private var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }

    private func connect() {
        guard isActive else { return }
        let t = session.webSocketTask(with: url)
        lock.lock(); task = t; lock.unlock()
        t.resume()
        receive(t)
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let msg):
                switch msg {
                case .string(let s): self.onMessage(Data(s.utf8))
                case .data(let d): self.onMessage(d)
                @unknown default: break
                }
                self.receive(t)
            case .failure:
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self, self.isActive else { return }
                    self.lock.lock(); let same = self.task === t; self.lock.unlock()
                    if same { self.connect() }
                }
            }
        }
    }
}
