import Foundation

/// 负责 mihomo 内核二进制的安装、提权与进程生命周期
final class CoreManager: @unchecked Sendable {
    private(set) var process: Process?
    private(set) var api: MihomoAPI?
    private var logHandle: FileHandle?
    /// 主动停止时置位，避免把正常退出当成崩溃
    private var stopping = false

    var onUnexpectedExit: ((Int32, String) -> Void)?

    var isRunning: Bool { process?.isRunning ?? false }

    // MARK: - Binary

    var bundledCore: URL? {
        let url = Bundle.main.resourceURL?.appendingPathComponent("mihomo")
        return url.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }

    var coreInstalled: Bool { FileManager.default.isExecutableFile(atPath: AppPaths.coreBinary.path) }

    /// 内核是否为 root 所有且带 setuid 位（TUN 模式需要）
    var isPrivileged: Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: AppPaths.coreBinary.path) else { return false }
        let owner = (attrs[.ownerAccountID] as? NSNumber)?.intValue ?? -1
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        return owner == 0 && perms & 0o4000 != 0
    }

    static func version(of binary: URL) -> String? {
        let r = Shell.run(binary.path, ["-v"])
        guard r.ok else { return nil }
        // "Mihomo Meta v1.19.34 darwin arm64 with go..."
        return r.output.split(separator: " ").first { $0.hasPrefix("v") }.map(String.init)
    }

    /// 首次运行或 App 内置内核版本变化时，将内置内核复制到 Application Support
    func installBundledCoreIfNeeded() throws {
        guard let bundled = bundledCore else { return }
        if coreInstalled, Self.version(of: bundled) == Self.version(of: AppPaths.coreBinary) { return }
        try replaceCore(with: bundled)
    }

    /// 将 App 内置的 Geo 数据库复制到内核工作目录（已存在则保留，内核会自行更新）
    func installBundledGeoIfNeeded() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("geo"),
              let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in files {
            let target = AppPaths.home.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: target.path) { continue }
            try? FileManager.default.copyItem(at: dir.appendingPathComponent(name), to: target)
        }
    }

    /// 替换内核文件（替换后 setuid 权限会丢失，需要重新授权）
    func replaceCore(with source: URL) throws {
        let fm = FileManager.default
        let tmp = AppPaths.coreDir.appendingPathComponent("mihomo.new")
        try? fm.removeItem(at: tmp)
        try fm.copyItem(at: source, to: tmp)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
        try? fm.removeItem(at: AppPaths.coreBinary)
        try fm.moveItem(at: tmp, to: AppPaths.coreBinary)
    }

    func grantPrivilege() async -> ShellResult {
        let path = Shell.quote(AppPaths.coreBinary.path)
        return await Shell.runAsAdmin("chown root:admin \(path) && chmod 4755 \(path)",
                                      prompt: "TinyClash 需要授权内核以启用 TUN 模式")
    }

    func revokePrivilege() async -> ShellResult {
        let path = Shell.quote(AppPaths.coreBinary.path)
        let user = Shell.quote(NSUserName())
        // 以 root 运行时写入的 cache.db 等文件也要归还给当前用户
        let home = Shell.quote(AppPaths.home.path)
        return await Shell.runAsAdmin("chmod 0755 \(path) && chown \(user):staff \(path) && chown -R \(user):staff \(home)",
                                      prompt: "TinyClash 将撤销内核的管理员权限")
    }

    // MARK: - Process

    /// 清理上次异常退出遗留的内核进程
    func killStaleProcess() {
        guard let text = try? String(contentsOf: AppPaths.pidFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return }
        let comm = Shell.run("/bin/ps", ["-p", "\(pid)", "-o", "comm="]).output
        if comm.contains(AppPaths.coreBinary.path) || comm.hasSuffix("mihomo\n") {
            kill(pid, SIGTERM)
            for _ in 0..<20 where kill(pid, 0) == 0 { usleep(100_000) }
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
        try? FileManager.default.removeItem(at: AppPaths.pidFile)
    }

    func start(configPath: String) async throws -> MihomoAPI {
        stop()
        killStaleProcess()

        let port = Self.freePort() ?? 19090
        let secret = UUID().uuidString
        let api = MihomoAPI(port: port, secret: secret)

        FileManager.default.createFile(atPath: AppPaths.coreLog.path, contents: nil)
        let log = try FileHandle(forWritingTo: AppPaths.coreLog)

        let p = Process()
        p.executableURL = AppPaths.coreBinary
        p.arguments = ["-d", AppPaths.home.path, "-f", configPath,
                       "-ext-ctl", "127.0.0.1:\(port)", "-secret", secret]
        p.currentDirectoryURL = AppPaths.home
        p.standardOutput = log
        p.standardError = log
        var env = ProcessInfo.processInfo.environment
        // 内核自身下载 provider 时不应走（可能指向自己的）环境代理
        for key in ["http_proxy", "https_proxy", "all_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"] { env[key] = nil }
        p.environment = env
        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            // 只有当前进程且非主动停止时才视为崩溃
            if self.process === proc && !self.stopping {
                self.onUnexpectedExit?(proc.terminationStatus, Self.tailLog())
            }
        }
        stopping = false
        try p.run()
        process = p
        logHandle = log
        try? "\(p.processIdentifier)".write(to: AppPaths.pidFile, atomically: true, encoding: .utf8)

        // 等待控制接口就绪
        for _ in 0..<100 {
            if !p.isRunning { break }
            if (try? await api.version()) != nil {
                self.api = api
                return api
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let tail = Self.tailLog()
        stop()
        throw NSError(domain: "TinyClash", code: 1, userInfo: [NSLocalizedDescriptionKey: "内核启动失败\n\(tail)"])
    }

    func stop() {
        api = nil
        guard let p = process else { return }
        stopping = true
        if p.isRunning {
            p.terminate()
            let deadline = Date().addingTimeInterval(3)
            while p.isRunning && Date() < deadline { usleep(50_000) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        process = nil
        try? logHandle?.close()
        logHandle = nil
        try? FileManager.default.removeItem(at: AppPaths.pidFile)
    }

    static func tailLog(lines: Int = 12) -> String {
        guard let text = try? String(contentsOf: AppPaths.coreLog, encoding: .utf8) else { return "" }
        return text.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }

    /// 测试配置文件是否可被内核解析；首次解析可能需要下载 Geo 数据库，超时视为通过
    static func testConfig(_ path: String, timeout: TimeInterval = 30) async -> ShellResult {
        await Task.detached {
            let p = Process()
            p.executableURL = AppPaths.coreBinary
            p.arguments = ["-t", "-d", AppPaths.home.path, "-f", path]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do { try p.run() } catch { return ShellResult(status: -1, output: error.localizedDescription) }
            let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            timer.cancel()
            let output = String(decoding: data, as: UTF8.self)
            if p.terminationReason == .uncaughtSignal { return ShellResult(status: 0, output: output) }
            // Geo 数据库下载失败属于网络问题而非配置错误，内核启动后会重试
            if p.terminationStatus != 0 && isGeoDownloadFailure(output) { return ShellResult(status: 0, output: output) }
            return ShellResult(status: p.terminationStatus, output: output)
        }.value
    }

    static func isGeoDownloadFailure(_ output: String) -> Bool {
        let lower = output.lowercased()
        let geo = ["mmdb", "geoip", "geosite", "asn", "geodata"].contains { lower.contains($0) }
        let net = ["download", "timeout", "deadline exceeded", "connection", "no such host", "eof"].contains { lower.contains($0) }
        return geo && net
    }

    static func freePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
        }
        return bound ? Int(UInt16(bigEndian: addr.sin_port)) : nil
    }
}
