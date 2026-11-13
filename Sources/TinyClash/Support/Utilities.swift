import Foundation

enum AppPaths {
    static let base: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.tinyclash.app", isDirectory: true)
        return url
    }()
    /// mihomo 的工作目录（-d），provider、cache.db、geo 数据都放在这里
    static let home = base.appendingPathComponent("mihomo", isDirectory: true)
    static let profiles = base.appendingPathComponent("profiles", isDirectory: true)
    static let profilesIndex = base.appendingPathComponent("profiles.json")
    /// Compatibility-only runtime YAML for legacy profiles.json overlays.
    static let runtime = base.appendingPathComponent("runtime", isDirectory: true)
    static let coreDir = base.appendingPathComponent("core", isDirectory: true)
    static let coreBinary = coreDir.appendingPathComponent("mihomo")
    static let logsDir = base.appendingPathComponent("logs", isDirectory: true)
    static let coreLog = logsDir.appendingPathComponent("core.log")
    static let pidFile = base.appendingPathComponent("core.pid")

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
