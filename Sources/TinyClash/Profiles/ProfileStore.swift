import CryptoKit
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
            guard kv.count == 2, let n = Double(kv[1]), n.isFinite else { continue }
            switch kv[0].lowercased() {
            case "upload": upload = Self.clamped(n)
            case "download": download = Self.clamped(n)
            case "total": total = Self.clamped(n)
            // 超出 Date 合理范围的到期时间按「无到期」处理
            case "expire": expire = n > 0 && n < 32_503_680_000 ? Date(timeIntervalSince1970: n) : nil
            default: break
            }
        }
    }

    /// 部分面板用 Int64.max、1e30 等表示「不限量」，直接转换会越界崩溃
    static func clamped(_ value: Double) -> Int64 {
        guard value > 0 else { return 0 }
        return value >= 9.2e18 ? Int64.max / 4 : Int64(value)
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
    /// 最近一次下载写入内容的 SHA-256，用于判断订阅是否在本地被修改过
    var downloadedHash: String?
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
    case missingProfile, profileChanged, profileBusy, missingCore, responseTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的订阅链接"
        case .badStatus(let c): return "下载失败（HTTP \(c)）"
        case .notClashConfig: return "内容不是 mihomo / Clash 格式的 YAML 配置"
        case .invalidConfig(let msg): return "配置校验失败：\n\(msg)"
        case .missingProfile: return "请先选择一个存在的配置"
        case .profileChanged: return "配置在校验期间已变更，请重试"
        case .profileBusy: return "配置正在更新或保存，请稍后重试"
        case .missingCore: return "未找到 mihomo 内核，无法校验配置"
        case .responseTooLarge: return "订阅内容过大（超过 20 MB）"
        }
    }
}

final class ProfileStore {
    static let userAgent = "clash.meta/mihomo TinyClash"
    static let maxDownloadSize = 20 * 1024 * 1024

    private let profilesDirectory: URL
    private let runtimeDirectory: URL
    private let indexURL: URL
    private let validate: (URL) async throws -> Void

    init(profilesDirectory: URL = AppPaths.profiles,
         runtimeDirectory: URL = AppPaths.runtime,
         indexURL: URL = AppPaths.profilesIndex,
         validate: @escaping (URL) async throws -> Void = { url in
             // Unlike import's permissive check, edits must actually pass mihomo -t.
             let result = await CoreManager.testConfig(url.path, strict: true)
             guard result.ok else { throw ProfileError.invalidConfig(result.output) }
         }) {
        self.profilesDirectory = profilesDirectory
        self.runtimeDirectory = runtimeDirectory
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
        case addRuleProvider(RuleProviderDefinition, policy: String? = nil)
        case updateRuleProvider(String, RuleProviderDefinition)
        case deleteRuleProvider(String)
    }

    struct ValidatedEdit {
        fileprivate let profile: Profile
        fileprivate let original: Data
        fileprivate let originalEntry: Profile?
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

    /// Throw rather than hide unsupported YAML or an unreadable profile as an empty list.
    func ruleProviders(in profile: Profile) throws -> [RuleProviderDefinition] {
        let file = profilesDirectory.appendingPathComponent(profile.fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { throw ProfileError.missingProfile }
        let yaml = try String(contentsOf: file, encoding: .utf8)
        let merged = try ConfigOverlay.apply(rules: profile.customRules ?? [], groups: profile.customGroups ?? [], to: yaml)
        return try ConfigOverlay.ruleProviders(in: merged)
    }

    func groupSummaries(in profile: Profile) -> [ConfigOverlay.GroupSummary] {
        let file = profilesDirectory.appendingPathComponent(profile.fileName)
        guard let yaml = try? String(contentsOf: file, encoding: .utf8),
              let merged = try? ConfigOverlay.apply(rules: profile.customRules ?? [], groups: profile.customGroups ?? [], to: yaml)
        else { return [] }
        return ConfigOverlay.groupSummaries(in: merged)
    }

    func ruleItems(in profile: Profile) -> [RuleItem] {
        let file = profilesDirectory.appendingPathComponent(profile.fileName)
        guard let yaml = try? String(contentsOf: file, encoding: .utf8),
              let merged = try? ConfigOverlay.apply(rules: profile.customRules ?? [], groups: profile.customGroups ?? [], to: yaml)
        else { return [] }
        return ConfigOverlay.ruleItems(in: merged)
    }

    /// Preparation never changes the official YAML or metadata. Paths and validation
    /// are injectable so tests need neither AppPaths nor a running core.
    @MainActor
    func prepareEdit(_ edit: ProfileEdit, to profile: Profile) async throws -> ValidatedEdit {
        let file = profilesDirectory.appendingPathComponent(profile.fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { throw ProfileError.missingProfile }
        let original = try Data(contentsOf: file)
        guard let yaml = String(data: original, encoding: .utf8) else { throw ProfileError.notClashConfig }
        let originalEntry = try indexEntry(for: profile.id)
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
        case .addRuleProvider(let provider, let policy): edited = try ConfigOverlay.addRuleProvider(provider, policy: policy, to: migrated)
        case .updateRuleProvider(let name, let provider): edited = try ConfigOverlay.replaceRuleProvider(named: name, with: provider, in: migrated)
        case .deleteRuleProvider(let name): edited = try ConfigOverlay.removeRuleProvider(named: name, from: migrated)
        }
        let data = Data(edited.utf8)
        let temporary = profilesDirectory.appendingPathComponent(".validate-\(UUID().uuidString).yaml")
        try data.write(to: temporary, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await validate(temporary)
        try Task.checkCancellation()
        return ValidatedEdit(profile: profile, original: original, originalEntry: originalEntry,
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
              // 只比较本配置的记录，其他配置同时写入索引不应让本次编辑误报冲突
              try indexEntry(for: edit.profile.id) == edit.originalEntry else { throw ProfileError.profileChanged }
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

    private func indexEntry(for id: UUID) throws -> Profile? {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = (try? decoder.decode([Profile].self, from: Data(contentsOf: indexURL))) ?? []
        return entries.first { $0.id == id }
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 订阅文件与最近一次下载的内容不同，说明在 App 内或外部编辑器中改过
    func isLocallyModified(_ profile: Profile) -> Bool {
        guard profile.kind == .remote, let expected = profile.downloadedHash,
              let data = try? Data(contentsOf: profilesDirectory.appendingPathComponent(profile.fileName)) else { return false }
        return Self.hash(data) != expected
    }

    /// 覆盖前把当前文件备份到 `backups/`，每个配置只保留最近一份
    func backup(_ profile: Profile, to directory: URL = AppPaths.backups) {
        let source = profilesDirectory.appendingPathComponent(profile.fileName)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(profile.fileName + ".bak")
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.copyItem(at: source, to: target)
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

    /// 将展示名称清洗为安全、无路径分隔符的配置文件主干名（不含 `.yaml` 扩展名）
    static func sanitizedStem(for name: String) -> String {
        var cleaned = ""
        for scalar in name.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars {
            if scalar == "/" || scalar == ":" || scalar == "\0" || CharacterSet.controlCharacters.contains(scalar) {
                cleaned.append("-")
            } else {
                cleaned.unicodeScalars.append(scalar)
            }
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        for ext in [".yaml", ".yml"] where cleaned.lowercased().hasSuffix(ext) {
            cleaned = String(cleaned.dropLast(ext.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        while cleaned.hasPrefix(".") {
            cleaned.removeFirst()
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if cleaned.utf8.count > 180 {
            var truncated = ""
            for ch in cleaned {
                let s = String(ch)
                if truncated.utf8.count + s.utf8.count > 180 { break }
                truncated.append(ch)
            }
            cleaned = truncated.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned.isEmpty ? "配置" : cleaned
    }

    /// 为配置生成与展示名一致且不冲突的 `.yaml` 文件名（按 macOS 默认大小写不敏感盘查重）
    func uniqueFileName(for name: String,
                        currentFileName: String? = nil,
                        excludingProfileID: UUID? = nil,
                        in profiles: [Profile]) -> String {
        let stem = Self.sanitizedStem(for: name)
        let usedLowercased = Set(
            profiles.filter { $0.id != excludingProfileID }.map { $0.fileName.lowercased() }
        )
        let currentLowercased = currentFileName?.lowercased()
        let fm = FileManager.default

        func available(_ candidate: String) -> Bool {
            let lower = candidate.lowercased()
            if usedLowercased.contains(lower) { return false }
            if let currentLowercased, lower == currentLowercased { return true }
            return !fm.fileExists(atPath: profilesDirectory.appendingPathComponent(candidate).path)
        }

        let base = "\(stem).yaml"
        if available(base) { return base }
        var index = 2
        while true {
            let candidate = "\(stem)-\(index).yaml"
            if available(candidate) { return candidate }
            index += 1
        }
    }

    private func moveFileIfExists(from oldName: String, to newName: String, in directory: URL) throws -> Bool {
        guard oldName != newName else { return false }
        let fm = FileManager.default
        let oldURL = directory.appendingPathComponent(oldName)
        let newURL = directory.appendingPathComponent(newName)
        guard fm.fileExists(atPath: oldURL.path) else { return false }
        try fm.moveItem(at: oldURL, to: newURL)
        return true
    }

    /// 更新配置信息并在名称变化时同步重命名磁盘上的 YAML（及 legacy runtime YAML）
    func saveProfile(_ profile: Profile, in profiles: [Profile]) throws -> [Profile] {
        guard let i = profiles.firstIndex(where: { $0.id == profile.id }) else { return profiles }
        var updatedProfile = profile
        let trimmedName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedProfile.name = trimmedName.isEmpty ? profiles[i].name : trimmedName

        let oldFileName = profiles[i].fileName
        let targetFileName = uniqueFileName(
            for: updatedProfile.name,
            currentFileName: oldFileName,
            excludingProfileID: updatedProfile.id,
            in: profiles
        )

        var movedProfileFile = false
        var movedRuntimeFile = false
        if targetFileName != oldFileName {
            movedProfileFile = try moveFileIfExists(from: oldFileName, to: targetFileName, in: profilesDirectory)
            do {
                movedRuntimeFile = try moveFileIfExists(from: oldFileName, to: targetFileName, in: runtimeDirectory)
            } catch {
                if movedProfileFile {
                    _ = try? moveFileIfExists(from: targetFileName, to: oldFileName, in: profilesDirectory)
                }
                throw error
            }
            updatedProfile.fileName = targetFileName
        }

        var updated = profiles
        updated[i] = updatedProfile
        do {
            let metadata = try encode(updated)
            try metadata.write(to: indexURL, options: .atomic)
        } catch {
            if movedProfileFile {
                _ = try? moveFileIfExists(from: targetFileName, to: oldFileName, in: profilesDirectory)
            }
            if movedRuntimeFile {
                _ = try? moveFileIfExists(from: targetFileName, to: oldFileName, in: runtimeDirectory)
            }
            throw error
        }
        return updated
    }

    /// 启动时将历史 `<UUID>.yaml` 等与展示名不一致的文件名统一成 `<name>.yaml`
    func reconcileFileNames(_ profiles: [Profile]) -> [Profile] {
        guard !profiles.isEmpty else { return profiles }
        var updated = profiles
        var changed = false
        let fm = FileManager.default
        for i in updated.indices {
            let oldFileName = updated[i].fileName
            let oldURL = profilesDirectory.appendingPathComponent(oldFileName)
            guard fm.fileExists(atPath: oldURL.path) else { continue }
            let desired = uniqueFileName(
                for: updated[i].name,
                currentFileName: oldFileName,
                excludingProfileID: updated[i].id,
                in: updated
            )
            guard desired != oldFileName else { continue }
            do {
                let moved = try moveFileIfExists(from: oldFileName, to: desired, in: profilesDirectory)
                if moved {
                    _ = try? moveFileIfExists(from: oldFileName, to: desired, in: runtimeDirectory)
                    updated[i].fileName = desired
                    changed = true
                }
            } catch {
                continue
            }
        }
        if changed {
            do {
                try encode(updated).write(to: indexURL, options: .atomic)
            } catch {
                // 索引写入失败时把文件名改回去，避免下次启动找不到配置文件
                for (old, new) in zip(profiles, updated) where old.fileName != new.fileName {
                    _ = try? moveFileIfExists(from: new.fileName, to: old.fileName, in: profilesDirectory)
                    _ = try? moveFileIfExists(from: new.fileName, to: old.fileName, in: runtimeDirectory)
                }
                return profiles
            }
        }
        return updated
    }

    struct Download {
        var data: Data
        var suggestedName: String?
        var subscription: SubscriptionInfo?
        var updateInterval: Int?
        var homepage: String?
    }

    func download(_ urlString: String, viaProxyPort: Int?) async throws -> Download {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false else {
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
        cfg.timeoutIntervalForResource = 120
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }

        var req = URLRequest(url: url)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        let http = resp as? HTTPURLResponse
        if let code = http?.statusCode, !(200..<300).contains(code) { throw ProfileError.badStatus(code) }
        guard data.count <= Self.maxDownloadSize else { throw ProfileError.responseTooLarge }

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
        guard Self.looksLikeClashConfig(String(decoding: data, as: UTF8.self)) else { throw ProfileError.notClashConfig }
        guard FileManager.default.isExecutableFile(atPath: AppPaths.coreBinary.path) else { throw ProfileError.missingCore }

        let original = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        let tmp = profilesDirectory.appendingPathComponent(".validate-\(UUID().uuidString).yaml")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let r = await CoreManager.testConfig(tmp.path)
        if !r.ok {
            let lines = r.output.split(separator: "\n").filter { $0.contains("level=error") || $0.contains("level=fatal") || $0.contains("failed") }
            throw ProfileError.invalidConfig((lines.isEmpty ? r.output : lines.joined(separator: "\n")).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        try Task.checkCancellation()
        try beforeCommit?()
        let current = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        guard current == original else { throw ProfileError.profileChanged }
        try data.write(to: url, options: .atomic)
    }

    /// 顶层出现任一常见键才视为 Clash 配置；按行首匹配，避免 `transport:` 之类的子串误判
    static func looksLikeClashConfig(_ text: String) -> Bool {
        let keys: Set = ["proxies", "proxy-providers", "proxy-groups", "rules", "mixed-port", "port"]
        return text.split(whereSeparator: \.isNewline).contains { line in
            guard let colon = line.firstIndex(of: ":") else { return false }
            return keys.contains(String(line[..<colon]))
        }
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
