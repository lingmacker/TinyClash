import Foundation

/// 通过 networksetup 设置 macOS 系统代理与 DNS
enum SystemProxy {
    static let tool = "/usr/sbin/networksetup"

    static let defaultBypass = [
        "127.0.0.1", "192.168.0.0/16", "10.0.0.0/8", "172.16.0.0/12", "100.64.0.0/10",
        "localhost", "*.local", "*.crashlytics.com", "captive.apple.com",
    ]

    /// 所有已启用的网络服务（Wi-Fi、以太网等）
    static func services() -> [String] {
        let out = Shell.run(tool, ["-listallnetworkservices"]).output
        return out.split(separator: "\n").dropFirst().map(String.init).filter { !$0.hasPrefix("*") && !$0.isEmpty }
    }

    static func enable(host: String = "127.0.0.1", httpPort: Int, socksPort: Int, bypass: [String]) async throws {
        var cmds: [[String]] = []
        for s in services() {
            if httpPort > 0 {
                cmds.append(["-setwebproxy", s, host, "\(httpPort)"])
                cmds.append(["-setsecurewebproxy", s, host, "\(httpPort)"])
            }
            if socksPort > 0 {
                cmds.append(["-setsocksfirewallproxy", s, host, "\(socksPort)"])
            } else {
                cmds.append(["-setsocksfirewallproxystate", s, "off"])
            }
            cmds.append(["-setproxybypassdomains", s] + (bypass.isEmpty ? ["Empty"] : bypass))
        }
        try await execute(cmds)
    }

    static func disable() async throws {
        var cmds: [[String]] = []
        for s in services() {
            cmds.append(["-setwebproxystate", s, "off"])
            cmds.append(["-setsecurewebproxystate", s, "off"])
            cmds.append(["-setsocksfirewallproxystate", s, "off"])
        }
        try await execute(cmds)
    }

    /// 当前系统代理是否指向给定端口（用于判断是否由我们设置）
    static func isPointing(toPort port: Int) -> Bool {
        guard port > 0 else { return false }
        for s in services() {
            let out = Shell.run(tool, ["-getwebproxy", s]).output
            if out.contains("Enabled: Yes") && out.contains("Server: 127.0.0.1") && out.contains("Port: \(port)\n") {
                return true
            }
        }
        return false
    }

    // MARK: - DNS（TUN 模式下把系统 DNS 指向可被劫持的地址）

    static func currentDNS() -> [String: [String]] {
        var result: [String: [String]] = [:]
        for s in services() {
            let out = Shell.run(tool, ["-getdnsservers", s]).output
            result[s] = out.contains("There aren't any") ? [] : out.split(separator: "\n").map(String.init)
        }
        return result
    }

    static func setDNS(_ servers: [String: [String]]) async throws {
        try await execute(servers.map { ["-setdnsservers", $0.key] + ($0.value.isEmpty ? ["Empty"] : $0.value) })
    }

    static func setDNSAll(_ servers: [String]) async throws {
        try await execute(services().map { ["-setdnsservers", $0] + servers })
    }

    // MARK: -

    private static func execute(_ cmds: [[String]]) async throws {
        guard !cmds.isEmpty else { return }
        var failed: [[String]] = []
        for c in cmds {
            let r = await Shell.runAsync(tool, c)
            if !r.ok || r.output.localizedCaseInsensitiveContains("error") { failed.append(c) }
        }
        guard !failed.isEmpty else { return }
        // 普通用户执行失败时回退到管理员授权
        let script = failed.map { ([tool] + $0).map(Shell.quote).joined(separator: " ") }.joined(separator: " && ")
        let r = await Shell.runAsAdmin(script, prompt: "TinyClash 需要修改网络设置")
        if !r.ok {
            throw NSError(domain: "TinyClash", code: 2, userInfo: [NSLocalizedDescriptionKey: "修改网络设置失败：\(r.output)"])
        }
    }
}
