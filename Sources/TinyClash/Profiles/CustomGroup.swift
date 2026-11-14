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

    /// 仅用于文件本身已是单行流式数组 `proxy-groups: [...]` 的场景
    var flowYAML: String { flowYAML(keeping: [:]) }

    func flowYAML(keeping extras: [String: Any]) -> String {
        var dict: [String: Any] = extras.merging(["name": name, "type": type]) { $1 }
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

    struct ProxyComment: Equatable {
        var leading: [String]
        var trailing: String
    }

    /// 标准多行块级 YAML；`proxyComments` 用于原位编辑时保留成员注释
    func yamlLines(indent: String, proxyComments: [String: ProxyComment] = [:]) -> [String] {
        let pad = indent + "  "
        var lines = ["\(indent)- name: \(ConfigOverlay.yamlScalar(name))"]
        lines.append("\(pad)type: \(ConfigOverlay.yamlScalar(type))")
        if !proxies.isEmpty {
            lines.append("\(pad)proxies:")
            for proxy in proxies {
                let comment = proxyComments[proxy]
                lines.append(contentsOf: (comment?.leading ?? []).map { "\(pad)  \($0)" })
                lines.append("\(pad)  - \(ConfigOverlay.yamlScalar(proxy))" + (comment?.trailing ?? ""))
            }
            lines.append(contentsOf: (proxyComments[""]?.leading ?? []).map { "\(pad)  \($0)" })
        }
        if isAutoTest {
            if !url.isEmpty { lines.append("\(pad)url: \(ConfigOverlay.yamlScalar(url))") }
            lines.append("\(pad)interval: \(interval)")
        }
        if includeAll {
            lines.append("\(pad)include-all: true")
        }
        if !filter.isEmpty {
            lines.append("\(pad)filter: \(ConfigOverlay.yamlScalar(filter))")
        }
        return lines
    }
}
