import Foundation

/// Form-managed fields of a mihomo rule provider. Other YAML keys stay in the profile.
struct RuleProviderDefinition: Equatable, Identifiable {
    static let types = ["http", "file", "inline"]
    static let behaviors = ["domain", "ipcidr", "classical"]
    static let formats = ["yaml", "text", "mrs"]

    var name = ""
    var type = "http"
    var behavior = "domain"
    var format = "yaml"
    var url = ""
    var path = ""
    var interval = 86400
    var payload: [String] = []

    var id: String { name }

    var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请输入规则集名称" }
        if name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }) {
            return "规则集名称不能包含换行或控制字符"
        }
        if !Self.types.contains(type) { return "规则集类型必须是 http、file 或 inline" }
        if !Self.behaviors.contains(behavior) { return "规则集行为必须是 domain、ipcidr 或 classical" }
        if !Self.formats.contains(format) { return "规则集格式必须是 yaml、text 或 mrs" }
        if interval < 0 { return "更新间隔不能为负数" }
        if format == "mrs", behavior == "classical" { return "mrs 格式不支持 classical 行为" }
        if type == "http" {
            guard !url.contains(where: { $0.isWhitespace }),
                  let parsed = URLComponents(string: url),
                  let scheme = parsed.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let host = parsed.host, !host.isEmpty else { return "HTTP 规则集需要包含主机名的 http(s) URL" }
        }
        if type == "file", path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "file 规则集需要文件路径"
        }
        if path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return "文件路径不能包含换行或控制字符"
        }
        if type == "inline", payload.isEmpty { return "inline 规则集至少需要一条 payload" }
        if payload.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.contains(where: { $0.isNewline }) }) {
            return "payload 条目不能为空或包含换行"
        }
        return nil
    }
}
