import Foundation

/// 用户在 App 中添加的代理分组（对应 mihomo proxy-groups 的常用字段）
struct CustomGroup: Codable, Identifiable, Equatable {
    static let types = ["select", "url-test", "fallback", "load-balance"]

    var id = UUID()
    var name = ""
    var type = "select"
    var proxies: [String] = []
    /// 引入全部节点（含 proxy-providers），通常与 filter 配合
    var includeAll = false
    var filter = ""
    var url = ""
    var interval = 300

    var isAutoTest: Bool { type != "select" }

    /// 序列化为单行 YAML（JSON 对象本身就是合法的 YAML 流式映射）
    var yaml: String {
        var dict: [String: Any] = ["name": name, "type": type]
        if !proxies.isEmpty { dict["proxies"] = proxies }
        if includeAll { dict["include-all"] = true }
        if !filter.isEmpty { dict["filter"] = filter }
        if isAutoTest {
            if !url.isEmpty { dict["url"] = url }
            dict["interval"] = interval
        }
        let data = (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// 把自定义分组 / 规则叠加到原配置上，生成内核实际加载的运行时配置。
/// 原配置文件保持不变，订阅更新后自定义内容依然生效。
enum ConfigOverlay {
    enum OverlayError: LocalizedError {
        case flowStyle(String)

        var errorDescription: String? {
            switch self {
            case .flowStyle(let key): return "配置中的 \(key) 使用了单行写法（\(key): [...]），暂不支持插入自定义内容"
            }
        }
    }

    /// 分组追加到 proxy-groups 末尾；规则插入到 rules 最前面（优先级最高）
    static func apply(rules: [String], groups: [CustomGroup], to yaml: String) throws -> String {
        var lines = yaml.components(separatedBy: "\n")
        try insert(groups.map(\.yaml), key: "proxy-groups", atStart: false, into: &lines)
        try insert(rules.map(quote), key: "rules", atStart: true, into: &lines)
        return lines.joined(separator: "\n")
    }

    private static func insert(_ items: [String], key: String, atStart: Bool, into lines: inout [String]) throws {
        guard !items.isEmpty else { return }
        // 只匹配顶格的 key（rule-providers 等下面的缩进键不会误中）
        guard let keyIndex = lines.firstIndex(where: { $0.hasPrefix("\(key):") }) else {
            if lines.last?.isEmpty == false { lines.append("") }
            lines.append("\(key):")
            lines.append(contentsOf: items.map { "  - \($0)" })
            lines.append("")
            return
        }

        let rest = stripComment(String(lines[keyIndex].dropFirst(key.count + 1)))
        if rest == "[]" {
            lines[keyIndex] = "\(key):"
        } else if !rest.isEmpty {
            throw OverlayError.flowStyle(key)
        }

        // 列表结束位置：下一个顶格的 key
        var end = lines.count
        for i in (keyIndex + 1)..<lines.count {
            let line = lines[i]
            guard let first = line.first, first != " ", first != "\t", first != "-", first != "#", first != "\r" else { continue }
            end = i
            break
        }

        // 沿用原列表的缩进（YAML 允许 `- ` 顶格写在 key 下面）
        var indent = "  "
        for line in lines[(keyIndex + 1)..<end] {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("-") { indent = String(line.prefix { $0 == " " }) }
            break
        }

        var at = keyIndex + 1
        if !atStart {
            // 插在最后一个列表项之后，列表后的空行和注释仍留在下一个 key 前
            at = end
            while at > keyIndex + 1 {
                let t = lines[at - 1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard t.isEmpty || t.hasPrefix("#") else { break }
                at -= 1
            }
        }
        lines.insert(contentsOf: items.map { "\(indent)- \($0)" }, at: at)
    }

    private static func stripComment(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("#") { return "" }
        if let hash = t.range(of: " #") { t = String(t[..<hash.lowerBound]) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 以 YAML 双引号字符串写入，避免规则内容里的 `#`、`: ` 等破坏结构
    static func quote(_ rule: String) -> String {
        "\"" + rule.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
