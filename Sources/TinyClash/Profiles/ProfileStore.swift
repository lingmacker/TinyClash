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
    /// Legacy profiles.json overlays only. New additions are written to YAML;
    /// these fields are cleared after a validated, successful one-time conversion.
    var customRules: [String]?
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
    case missingProfile, profileChanged, profileBusy

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的订阅链接"
        case .badStatus(let c): return "下载失败（HTTP \(c)）"
        case .notClashConfig: return "内容不是 mihomo / Clash 格式的 YAML 配置"
        case .invalidConfig(let msg): return "配置校验失败：\n\(msg)"
        case .missingProfile: return "请先选择一个存在的配置"
        case .profileChanged: return "配置在校验期间已变更，请重试"
        case .profileBusy: return "配置正在更新或保存，请稍后重试"
        }
    }
}

final class ProfileStore {
    static let userAgent = "clash.meta/mihomo TinyClash"

    private let profilesDirectory: URL
    private let indexURL: URL
    private let validate: (URL) async throws -> Void

    init(profilesDirectory: URL = AppPaths.profiles,
         indexURL: URL = AppPaths.profilesIndex,
         validate: @escaping (URL) async throws -> Void = { url in
             // Unlike import's permissive check, edits must actually pass mihomo -t.
             let result = await CoreManager.testConfig(url.path, strict: true)
             guard result.ok else { throw ProfileError.invalidConfig(result.output) }
         }) {
        self.profilesDirectory = profilesDirectory
        self.indexURL = indexURL
        self.validate = validate
    }

    enum ProfileEdit {
        case addRule(String)
        case deleteRule(ConfigOverlay.RuleTarget)
        case updateRule(ConfigOverlay.RuleTarget, String)
        case addGroup(CustomGroup)
        case deleteGroup(String)
        case updateGroup(String, CustomGroup)
    }

    struct ValidatedEdit {
        fileprivate let profile: Profile
        fileprivate let original: Data
        fileprivate let originalIndex: Data?
        fileprivate let data: Data
        fileprivate let fileURL: URL
        fileprivate let indexURL: URL
    }

    /// The rule as written in the profile (including legacy overlays), for editing.
    func ruleText(_ target: ConfigOverlay.RuleTarget, in profile: Profile) -> String? {
        let file = profilesDirectory.appendingPathComponent(profile.fileName)
        guard let yaml = try? String(contentsOf: file, encoding: .utf8),
              let merged = try? ConfigOverlay.apply(rules: profile.customRules ?? [], groups: profile.customGroups ?? [], to: yaml)
        else { return nil }
        return ConfigOverlay.ruleText(target, in: merged)
    }

    func group(named name: String, in profile: Profile) -> CustomGroup? {
        let file = profilesDirectory.appendingPathComponent(profile.fileName)
        guard let yaml = try? String(contentsOf: file, encoding: .utf8),
              let merged = try? ConfigOverlay.apply(rules: profile.customRules ?? [], groups: profile.customGroups ?? [], to: yaml)
        else { return nil }
        return ConfigOverlay.group(named: name, in: merged)
    }

    /// Preparation never changes the official YAML or metadata. Paths and validation
    /// are injectable so tests need neither AppPaths nor a running core.
    @MainActor
    func prepareEdit(_ edit: ProfileEdit, to profile: Profile) async throws -> ValidatedEdit {
        let file = profilesDirectory.appendingPathComponent(profile.fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { throw ProfileError.missingProfile }
        let original = try Data(contentsOf: file)
        guard let yaml = String(data: original, encoding: .utf8) else { throw ProfileError.notClashConfig }
        let originalIndex = try indexData()
        // Merge legacy overlays first, then apply the requested edit so additions,
        // deletions, and runtime indices all match the same consolidated YAML.
        let migrated = try ConfigOverlay.apply(rules: profile.customRules ?? [], groups: profile.customGroups ?? [], to: yaml)
        let edited: String
        switch edit {
        case .addRule(let rule): edited = try ConfigOverlay.addRule(rule, to: migrated)
        case .deleteRule(let target): edited = try ConfigOverlay.removeRule(target, from: migrated)
        case .updateRule(let target, let rule): edited = try ConfigOverlay.replaceRule(target, with: rule, in: migrated)
        case .addGroup(let group): edited = try ConfigOverlay.addGroup(group, to: migrated)
        case .deleteGroup(let name): edited = try ConfigOverlay.removeGroup(named: name, from: migrated)
        case .updateGroup(let name, let group): edited = try ConfigOverlay.replaceGroup(named: name, with: group, in: migrated)
        }
        let data = Data(edited.utf8)
        let temporary = profilesDirectory.appendingPathComponent(".validate-\(UUID().uuidString).yaml")
        try data.write(to: temporary, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await validate(temporary)
        try Task.checkCancellation()
        return ValidatedEdit(profile: profile, original: original, originalIndex: originalIndex,
                             data: data, fileURL: file, indexURL: indexURL)
    }

    /// No suspension between optimistic checks and commit. AppState also excludes
    /// subscription updates for this profile while an edit is being validated.
    @MainActor
    func commit(_ edit: ValidatedEdit, profiles: [Profile]) throws -> [Profile] {
        guard let i = profiles.firstIndex(where: { $0.id == edit.profile.id }) else { throw ProfileError.missingProfile }
        guard profiles[i] == edit.profile,
              edit.fileURL == profilesDirectory.appendingPathComponent(profiles[i].fileName),
              edit.indexURL == indexURL,
              FileManager.default.fileExists(atPath: edit.fileURL.path),
              try Data(contentsOf: edit.fileURL) == edit.original,
              try indexData() == edit.originalIndex else { throw ProfileError.profileChanged }
        try Task.checkCancellation()
        var updated = profiles
        updated[i].customRules = nil
        updated[i].customGroups = nil
        let metadata = try encode(updated)
        try edit.data.write(to: edit.fileURL, options: .atomic)
        do {
            try metadata.write(to: indexURL, options: .atomic)
        } catch {
            // Keep the old index/overlays usable if metadata persistence fails.
            try edit.original.write(to: edit.fileURL, options: .atomic)
            throw error
        }
        return updated
    }

    private func indexData() throws -> Data? {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return nil }
        return try Data(contentsOf: indexURL)
    }

    private func encode(_ profiles: [Profile]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(profiles)
    }

    func load() -> [Profile] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Profile].self, from: data)) ?? []
    }

    func save(_ profiles: [Profile]) {
        try? encode(profiles).write(to: indexURL, options: .atomic)
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
    @MainActor
    func writeValidated(_ data: Data, to url: URL, beforeCommit: (() throws -> Void)? = nil) async throws {
        let text = String(decoding: data, as: UTF8.self)
        let keys = ["proxies:", "proxy-providers:", "proxy-groups:", "rules:", "mixed-port:", "port:"]
        guard keys.contains(where: { text.contains($0) }) else { throw ProfileError.notClashConfig }

        let original = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        let tmp = profilesDirectory.appendingPathComponent(".validate-\(UUID().uuidString).yaml")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        if FileManager.default.isExecutableFile(atPath: AppPaths.coreBinary.path) {
            let r = await CoreManager.testConfig(tmp.path)
            if !r.ok {
                let lines = r.output.split(separator: "\n").filter { $0.contains("level=error") || $0.contains("level=fatal") || $0.contains("failed") }
                throw ProfileError.invalidConfig((lines.isEmpty ? r.output : lines.joined(separator: "\n")).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        try Task.checkCancellation()
        try beforeCommit?()
        let current = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        guard current == original else { throw ProfileError.profileChanged }
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
