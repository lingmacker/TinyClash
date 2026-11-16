import AppKit
import Foundation

enum AppPaths {
    static let base: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.lingmacker.tinyclash", isDirectory: true)
        return url
    }()
    /// mihomo 的工作目录（-d），provider、cache.db、geo 数据都放在这里
    static let home = base.appendingPathComponent("mihomo", isDirectory: true)
    static let webUI = home.appendingPathComponent("metacubexd", isDirectory: true)
    static let profiles = base.appendingPathComponent("profiles", isDirectory: true)
    static let profilesIndex = base.appendingPathComponent("profiles.json")
    /// Compatibility-only runtime YAML for legacy profiles.json overlays.
    static let runtime = base.appendingPathComponent("runtime", isDirectory: true)
    static let coreDir = base.appendingPathComponent("core", isDirectory: true)
    static let coreBinary = coreDir.appendingPathComponent("mihomo")
    static let logsDir = base.appendingPathComponent("logs", isDirectory: true)
    static let coreLog = logsDir.appendingPathComponent("core.log")
    static let pidFile = base.appendingPathComponent("core.pid")
    /// 订阅覆盖前的本地备份
    static let backups = base.appendingPathComponent("backups", isDirectory: true)

    static func ensure() {
        for dir in [base, home, profiles, runtime, coreDir, logsDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

struct ShellResult {
    var status: Int32
    var output: String
    var ok: Bool { status == 0 }
}

enum Shell {
    /// 同步执行命令，合并 stdout/stderr
    @discardableResult
    static func run(_ launchPath: String, _ args: [String]) -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return ShellResult(status: -1, output: error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return ShellResult(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    static func runAsync(_ launchPath: String, _ args: [String]) async -> ShellResult {
        await Task.detached { run(launchPath, args) }.value
    }

    /// 通过系统授权对话框以管理员身份执行 shell 脚本
    static func runAsAdmin(_ script: String, prompt: String) async -> ShellResult {
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with prompt \"\(prompt)\" with administrator privileges"
        return await runAsync("/usr/bin/osascript", ["-e", source])
    }

    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

enum Format {
    static func bytes(_ value: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(value)
        var i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        return i == 0 ? "\(Int(v)) B" : String(format: v < 10 ? "%.2f %@" : "%.1f %@", v, units[i])
    }

    static func speed(_ value: Int64) -> String { bytes(value) + "/s" }

    /// 菜单栏用的紧凑写法
    static func compactSpeed(_ value: Int64) -> String {
        let units = ["B", "K", "M", "G"]
        var v = Double(value)
        var i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1024; i += 1 }
        return i == 0 ? "\(Int(v))B" : String(format: v < 10 ? "%.1f%@" : "%.0f%@", v, units[i])
    }

    static func date(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: d)
    }

    static func updateAge(_ date: Date, now: Date = Date()) -> String {
        let elapsed = max(0, now.timeIntervalSince(date))
        if elapsed < 60 { return "刚刚" }
        if elapsed < 3600 { return "\(Int(elapsed / 60)) 分钟前" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600)) 小时前" }
        return "\(Int(elapsed / 86400)) 天前"
    }

    static func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}

extension String {
    /// 用于 REST 路径片段（代理名可能包含 / 空格 emoji）
    var pathEscaped: String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }

    var queryEscaped: String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}

/// 异步并发上限：超出上限的调用按先后顺序排队等待
actor AsyncLimiter {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = max(1, limit) }

    func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// 有排队者时名额直接转交给最早的一个
    func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

struct ReleaseInfo: Equatable {
    var version: String
    var tagName: String
    var htmlURL: URL
    var notes: String?
}

enum UpdateError: LocalizedError {
    case badStatus(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "请求失败（HTTP \(code)）"
        case .invalidResponse: return "无法解析版本信息"
        }
    }
}

enum UpdateChecker {
    static let latestAPIURL = URL(string: "https://api.github.com/repos/lingmacker/TinyClash/releases/latest")!
    static let latestPageURL = URL(string: "https://github.com/lingmacker/TinyClash/releases/latest")!

    static func normalizedVersion(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }

    /// 比较远端版本是否比当前版本更新（支持 x.y.z 与预发布后缀）
    static func isNewer(remote: String, than current: String) -> Bool {
        let rNorm = normalizedVersion(remote)
        let cNorm = normalizedVersion(current)
        guard !rNorm.isEmpty, !cNorm.isEmpty, rNorm != cNorm else { return false }

        let rParts = rNorm.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let cParts = cNorm.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let rNums = rParts[0].split(separator: ".").map { Int($0) ?? 0 }
        let cNums = cParts[0].split(separator: ".").map { Int($0) ?? 0 }
        let count = max(rNums.count, cNums.count)
        for i in 0..<count {
            let rv = i < rNums.count ? rNums[i] : 0
            let cv = i < cNums.count ? cNums[i] : 0
            if rv != cv { return rv > cv }
        }
        let rPre = rParts.count > 1 ? String(rParts[1]) : ""
        let cPre = cParts.count > 1 ? String(cParts[1]) : ""
        if rPre.isEmpty && !cPre.isEmpty { return true }
        if !rPre.isEmpty && cPre.isEmpty { return false }
        return rPre.localizedStandardCompare(cPre) == .orderedDescending
    }

    static func fetchLatestRelease(proxyPort: Int?, preferProxy: Bool) async throws -> ReleaseInfo {
        let ports: [Int?] = if let port = proxyPort, port > 0 {
            preferProxy ? [port, nil] : [nil, port]
        } else {
            [nil]
        }
        var lastError: Error = UpdateError.invalidResponse
        for port in ports {
            do {
                return try await fetchLatestRelease(viaProxyPort: port)
            } catch let error as URLError {
                // 只有网络不通时才换一条路径重试；服务器已应答的错误换路径也没用
                lastError = error
            }
        }
        throw lastError
    }

    private struct GitHubReleasePayload: Decodable {
        var tag_name: String
        var html_url: String
        var body: String?
    }

    private static func fetchLatestRelease(viaProxyPort port: Int?) async throws -> ReleaseInfo {
        let cfg = URLSessionConfiguration.ephemeral
        if let port, port > 0 {
            cfg.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable: 1, kCFNetworkProxiesHTTPProxy: "127.0.0.1", kCFNetworkProxiesHTTPPort: port,
                kCFNetworkProxiesHTTPSEnable: 1, kCFNetworkProxiesHTTPSProxy: "127.0.0.1", kCFNetworkProxiesHTTPSPort: port,
            ] as [AnyHashable: Any]
        } else {
            cfg.connectionProxyDictionary = [:]
        }
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 10
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }

        var req = URLRequest(url: latestAPIURL)
        req.setValue("TinyClash", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        if let code = (resp as? HTTPURLResponse)?.statusCode {
            if code == 403 || code == 429 {
                return try await fetchFromRedirect(session: session)
            }
            guard (200..<300).contains(code) else { throw UpdateError.badStatus(code) }
        }
        guard let payload = try? JSONDecoder().decode(GitHubReleasePayload.self, from: data),
              let htmlURL = URL(string: payload.html_url) else {
            throw UpdateError.invalidResponse
        }
        let version = normalizedVersion(payload.tag_name)
        guard !version.isEmpty else { throw UpdateError.invalidResponse }
        return ReleaseInfo(version: version, tagName: payload.tag_name, htmlURL: htmlURL, notes: payload.body)
    }

    private static func fetchFromRedirect(session: URLSession) async throws -> ReleaseInfo {
        var req = URLRequest(url: latestPageURL)
        req.httpMethod = "HEAD"
        req.setValue("TinyClash", forHTTPHeaderField: "User-Agent")
        let (_, resp) = try await session.data(for: req)
        if let code = (resp as? HTTPURLResponse)?.statusCode, !(200..<400).contains(code) {
            throw UpdateError.badStatus(code)
        }
        guard let finalURL = resp.url,
              let range = finalURL.path.range(of: "/releases/tag/") else {
            throw UpdateError.invalidResponse
        }
        let tag = String(finalURL.path[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let version = normalizedVersion(tag)
        guard !version.isEmpty else { throw UpdateError.invalidResponse }
        return ReleaseInfo(version: version, tagName: tag, htmlURL: finalURL, notes: nil)
    }
}
