import Foundation

struct SubscriptionInfo: Codable, Equatable {
    var upload: Int64 = 0
    var download: Int64 = 0
    var total: Int64 = 0
    var expire: Date?

    var used: Int64 { upload + download }

    /// 解析 `subscription-userinfo: upload=1; download=2; total=3; expire=1700000000`
    init?(header: String?) {
        guard let header else { return nil }
        for part in header.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, let n = Double(kv[1]) else { continue }
            switch kv[0].lowercased() {
            case "upload": upload = Int64(n)
            case "download": download = Int64(n)
            case "total": total = Int64(n)
            case "expire": expire = n > 0 ? Date(timeIntervalSince1970: n) : nil
            default: break
            }
        }
    }
}

struct Profile: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case remote, local }

    var id = UUID()
    var name: String
    var kind: Kind
    var url: String?
    var fileName: String
    var updatedAt: Date
    /// 自动更新间隔（小时），0 表示不自动更新
    var updateInterval: Int = 24
    var subscription: SubscriptionInfo?
    var homepage: String?
    /// 用户在 App 中添加的规则，运行时插入到配置 rules 最前面
    var customRules: [String]?
    /// 用户在 App 中添加的分组，运行时追加到配置 proxy-groups 末尾
    var customGroups: [CustomGroup]?

    var hasCustomization: Bool { !(customRules ?? []).isEmpty || !(customGroups ?? []).isEmpty }

    var fileURL: URL { AppPaths.profiles.appendingPathComponent(fileName) }
    var runtimeURL: URL { AppPaths.runtime.appendingPathComponent(fileName) }

    var needsUpdate: Bool {
        kind == .remote && updateInterval > 0 && Date().timeIntervalSince(updatedAt) > Double(updateInterval) * 3600
    }
}

enum ProfileError: LocalizedError {
    case invalidURL, badStatus(Int), notClashConfig, invalidConfig(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的订阅链接"
        case .badStatus(let c): return "下载失败（HTTP \(c)）"
        case .notClashConfig: return "内容不是 mihomo / Clash 格式的 YAML 配置"
        case .invalidConfig(let msg): return "配置校验失败：\n\(msg)"
        }
    }
}

final class ProfileStore {
    static let userAgent = "clash.meta/mihomo TinyClash"

    func load() -> [Profile] {
        guard let data = try? Data(contentsOf: AppPaths.profilesIndex) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Profile].self, from: data)) ?? []
    }

    func save(_ profiles: [Profile]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(profiles).write(to: AppPaths.profilesIndex, options: .atomic)
    }

    struct Download {
        var data: Data
        var suggestedName: String?
        var subscription: SubscriptionInfo?
        var updateInterval: Int?
        var homepage: String?
    }

    func download(_ urlString: String, viaProxyPort: Int?) async throws -> Download {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)), url.scheme?.hasPrefix("http") == true else {
            throw ProfileError.invalidURL
        }
        let cfg = URLSessionConfiguration.ephemeral
        if let port = viaProxyPort, port > 0 {
            cfg.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable: 1, kCFNetworkProxiesHTTPProxy: "127.0.0.1", kCFNetworkProxiesHTTPPort: port,
                kCFNetworkProxiesHTTPSEnable: 1, kCFNetworkProxiesHTTPSProxy: "127.0.0.1", kCFNetworkProxiesHTTPSPort: port,
            ] as [AnyHashable: Any]
        } else {
            cfg.connectionProxyDictionary = [:]
        }
        cfg.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }

        var req = URLRequest(url: url)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        let http = resp as? HTTPURLResponse
        if let code = http?.statusCode, !(200..<300).contains(code) { throw ProfileError.badStatus(code) }

        let headers = http?.allHeaderFields ?? [:]
        func header(_ name: String) -> String? {
            headers.first { ($0.key as? String)?.lowercased() == name }?.value as? String
        }
        return Download(
            data: data,
            suggestedName: Self.fileName(fromDisposition: header("content-disposition")),
            subscription: SubscriptionInfo(header: header("subscription-userinfo")),
            updateInterval: header("profile-update-interval").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) },
            homepage: header("profile-web-page-url")
        )
    }

    /// 写入前做基本校验，再交给内核 -t 校验
    func writeValidated(_ data: Data, to url: URL) async throws {
        let text = String(decoding: data, as: UTF8.self)
        let keys = ["proxies:", "proxy-providers:", "proxy-groups:", "rules:", "mixed-port:", "port:"]
        guard keys.contains(where: { text.contains($0) }) else { throw ProfileError.notClashConfig }

        let tmp = AppPaths.profiles.appendingPathComponent(".validate-\(UUID().uuidString).yaml")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        if FileManager.default.isExecutableFile(atPath: AppPaths.coreBinary.path) {
            let r = await CoreManager.testConfig(tmp.path)
            if !r.ok {
                let lines = r.output.split(separator: "\n").filter { $0.contains("level=error") || $0.contains("level=fatal") || $0.contains("failed") }
                throw ProfileError.invalidConfig((lines.isEmpty ? r.output : lines.joined(separator: "\n")).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        try data.write(to: url, options: .atomic)
    }

    static func fileName(fromDisposition value: String?) -> String? {
        guard let value else { return nil }
        // filename*=UTF-8''xxx 优先
        if let r = value.range(of: "filename*=UTF-8''", options: .caseInsensitive) {
            let raw = value[r.upperBound...].split(separator: ";").first.map(String.init) ?? ""
            if let decoded = raw.removingPercentEncoding, !decoded.isEmpty { return decoded }
        }
        if let r = value.range(of: "filename=", options: .caseInsensitive) {
            let raw = value[r.upperBound...].split(separator: ";").first.map(String.init) ?? ""
            let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            return name.isEmpty ? nil : name
        }
        return nil
    }
}
