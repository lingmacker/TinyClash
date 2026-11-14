import Foundation

/// rule-providers 的严格编辑：遇到无法安全修改的写法一律报错
extension ConfigOverlay {
    // MARK: - Rule providers

    enum RuleProviderError: LocalizedError {
        case unsupportedYAML(String)
        case duplicate(String)
        case notFound(String)
        case invalid(String)
        case rename

        var errorDescription: String? {
            switch self {
            case .unsupportedYAML(let detail):
                return "rule-providers 使用了暂不支持安全编辑的 YAML 写法（\(detail)），请先改为普通块映射"
            case .duplicate(let name): return "配置中已存在名为「\(name)」的规则集"
            case .notFound(let name): return "未在当前配置文件中找到规则集「\(name)」"
            case .invalid(let message): return message
            case .rename: return "规则集名称不可修改，请新建规则集并手动调整引用"
            }
        }
    }

    /// Deliberately throws for unsupported syntax rather than presenting a partial list.
    static func ruleProviders(in yaml: String) throws -> [RuleProviderDefinition] {
        try providerSection(in: providerLines(yaml)).blocks.map(\.definition)
    }

    static func addRuleProvider(_ provider: RuleProviderDefinition, policy: String? = nil, to yaml: String) throws -> String {
        try validateProvider(provider)
        if let policy {
            guard !policy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RuleProviderError.invalid("请选择规则集的目标策略")
            }
            guard !provider.name.contains(","), !policy.contains(","), !policy.contains(where: \.isNewline) else {
                throw RuleProviderError.invalid("自动创建 RULE-SET 规则时，规则集名称和策略不能包含逗号或换行")
            }
        }
        let newline = yaml.contains("\r\n") ? "\r\n" : "\n"
        var lines = providerLines(yaml)
        let section = try providerSection(in: lines)
        guard !section.blocks.contains(where: { $0.definition.name == provider.name }) else {
            throw RuleProviderError.duplicate(provider.name)
        }
        if let key = section.key {
            let (rest, _) = splitComment(String(lines[key].dropFirst("rule-providers:".count)))
            if rest == "{}", let range = lines[key].range(of: "{}") {
                lines[key].removeSubrange(range)
            }
            let indent = section.blocks.first?.indent ?? 2
            var insertion = section.end
            while insertion > key + 1, providerTrivia(lines[insertion - 1]) { insertion -= 1 }
            lines.insert(contentsOf: providerYAMLLines(provider, indent: indent), at: insertion)
        } else {
            // A new section goes before the document's trailing comments, not after them.
            var insertion = lines.count
            while insertion > 0, providerTrivia(lines[insertion - 1]) { insertion -= 1 }
            lines.insert(contentsOf: ["rule-providers:"] + providerYAMLLines(provider, indent: 2), at: insertion)
        }
        let added = lines.joined(separator: newline)
        guard let policy else { return added }
        return try addRule("RULE-SET,\(provider.name),\(policy)", to: added)
    }

    static func replaceRuleProvider(named name: String, with provider: RuleProviderDefinition, in yaml: String) throws -> String {
        guard name == provider.name else { throw RuleProviderError.rename }
        try validateProvider(provider)
        let newline = yaml.contains("\r\n") ? "\r\n" : "\n"
        var lines = providerLines(yaml)
        let section = try providerSection(in: lines)
        guard let block = section.blocks.first(where: { $0.definition.name == name }) else {
            throw RuleProviderError.notFound(name)
        }
        // Preserve the original name line, every unknown field (including its children),
        // and all full-line comments. Only managed field content is replaced.
        var retained: [String] = []
        for i in (block.start + 1)..<block.end {
            if !block.managedLines.contains(i) || providerTrivia(lines[i]) {
                retained.append(lines[i])
            } else {
                // A comment on a replaced scalar/payload item survives as a full line;
                // never attach it to a different payload value by guessing its index.
                let (_, comment) = splitComment(lines[i])
                if !comment.isEmpty {
                    let indent = lines[i].prefix { $0 == " " }
                    retained.append(String(indent) + comment.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        let replacement = [lines[block.start]] + providerFieldLines(provider, indent: block.fieldIndent) + retained
        lines.replaceSubrange(block.start..<block.end, with: replacement)
        return lines.joined(separator: newline)
    }

    static func removeRuleProvider(named name: String, from yaml: String) throws -> String {
        let newline = yaml.contains("\r\n") ? "\r\n" : "\n"
        var lines = providerLines(yaml)
        let section = try providerSection(in: lines)
        guard let key = section.key, let block = section.blocks.first(where: { $0.definition.name == name }) else {
            throw RuleProviderError.notFound(name)
        }
        // References are intentionally untouched: ProfileStore's strict mihomo validation
        // rejects dangling RULE-SET references, including compound rules and sub-rules.
        let comments = lines[block.start..<block.end].filter(providerTrivia)
        lines.replaceSubrange(block.start..<block.end, with: comments)
        if section.blocks.count == 1 {
            let (_, comment) = splitComment(String(lines[key].dropFirst("rule-providers:".count)))
            lines[key] = "rule-providers: {}" + comment
        }
        return lines.joined(separator: newline)
    }

    private static let managedProviderKeys: Set<String> = ["type", "behavior", "format", "url", "path", "interval", "payload"]

    private struct ProviderBlock {
        var definition: RuleProviderDefinition
        var start: Int
        var end: Int
        var indent: Int
        var fieldIndent: Int
        var managedLines: Set<Int>
    }

    private struct ProviderSection {
        var key: Int?
        var end: Int
        var blocks: [ProviderBlock]
    }

    private static func providerLines(_ yaml: String) -> [String] {
        yaml.components(separatedBy: yaml.contains("\r\n") ? "\r\n" : "\n")
    }

    private static func providerTrivia(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces)
        return text.isEmpty || text.hasPrefix("#")
    }

    private static func validateProvider(_ provider: RuleProviderDefinition) throws {
        if let message = provider.validationMessage { throw RuleProviderError.invalid(message) }
    }

    private static func providerYAMLLines(_ provider: RuleProviderDefinition, indent: Int) -> [String] {
        [String(repeating: " ", count: indent) + yamlScalar(provider.name) + ":"] + providerFieldLines(provider, indent: indent + 2)
    }

    private static func providerFieldLines(_ provider: RuleProviderDefinition, indent: Int) -> [String] {
        let pad = String(repeating: " ", count: indent)
        var result = ["\(pad)type: \(provider.type)", "\(pad)behavior: \(provider.behavior)", "\(pad)format: \(provider.format)"]
        if !provider.url.isEmpty { result.append("\(pad)url: \(yamlScalar(provider.url))") }
        if !provider.path.isEmpty { result.append("\(pad)path: \(yamlScalar(provider.path))") }
        result.append("\(pad)interval: \(provider.interval)")
        if !provider.payload.isEmpty {
            result.append("\(pad)payload:")
            result.append(contentsOf: provider.payload.map { "\(pad)  - \(yamlScalar($0))" })
        }
        return result
    }

    private static func providerSection(in lines: [String]) throws -> ProviderSection {
        var keys: [Int] = []
        var documentMarkerSeen = false
        var rootIndent: Int?
        for (i, line) in lines.enumerated() where !providerTrivia(line) {
            let text = splitComment(line.trimmingCharacters(in: .whitespaces)).content
            let indent = line.prefix { $0 == " " }.count
            if text == "---", rootIndent == nil, !documentMarkerSeen {
                documentMarkerSeen = true
                continue
            }
            if rootIndent == nil {
                guard !isDashItemLine(text) else { throw RuleProviderError.unsupportedYAML("文档级序列") }
                rootIndent = indent
            }
            // Nested unknown values stay opaque, including keys that happen to share
            // the section name and literal block content that resembles YAML markers.
            guard indent == rootIndent else { continue }
            if text == "---" || text == "..." { throw RuleProviderError.unsupportedYAML("多文档 YAML") }
            // A flow map, merge, or alias could conceal providers and incorrectly look
            // like an absent section. Decode quoted root keys before checking the name.
            if ["{", "[", "*", "&", "!", "?", "%"].contains(where: { text.hasPrefix($0) }) {
                throw RuleProviderError.unsupportedYAML("文档级流式映射、锚点或合并")
            }
            if isDashItemLine(text) { continue } // indentless sequences belonging to other sections
            if let pair = try? providerPair(text) {
                let name = try providerScalar(pair.key)
                if name == "<<" { throw RuleProviderError.unsupportedYAML("文档级合并") }
                if name == "rule-providers" {
                    guard line.hasPrefix("rule-providers:") else { throw RuleProviderError.unsupportedYAML("带引号或缩进的 rule-providers 键") }
                    keys.append(i)
                }
            } else if text.hasPrefix("\"") || text.hasPrefix("'") || text.hasPrefix("rule-providers") {
                throw RuleProviderError.unsupportedYAML("无法安全解析文档键")
            }
        }
        guard keys.count <= 1 else { throw RuleProviderError.unsupportedYAML("重复的 rule-providers 键") }
        guard let key = keys.first else { return ProviderSection(key: nil, end: lines.count, blocks: []) }
        let end = sectionEnd(after: key, in: lines)
        let (rest, _) = splitComment(String(lines[key].dropFirst("rule-providers:".count)))
        if rest == "{}" {
            guard lines[(key + 1)..<end].allSatisfy(providerTrivia) else { throw RuleProviderError.unsupportedYAML("流式映射后包含额外内容") }
            return ProviderSection(key: key, end: end, blocks: [])
        }
        guard rest.isEmpty else { throw RuleProviderError.unsupportedYAML("rule-providers 必须是块映射或空 {}") }
        var starts: [Int] = []
        var indent: Int?
        for i in (key + 1)..<end where !providerTrivia(lines[i]) {
            guard !lines[i].prefix(while: { $0.isWhitespace }).contains("\t") else { throw RuleProviderError.unsupportedYAML("Tab 缩进") }
            let currentIndent = lines[i].prefix { $0 == " " }.count
            if indent == nil {
                guard currentIndent > 0 else { throw RuleProviderError.unsupportedYAML("规则集名称需要缩进") }
                indent = currentIndent
            }
            guard currentIndent >= indent! else { throw RuleProviderError.unsupportedYAML("不一致的规则集缩进") }
            if currentIndent == indent { starts.append(i) }
        }
        var blocks: [ProviderBlock] = []
        var names: Set<String> = []
        for (offset, start) in starts.enumerated() {
            let next = offset + 1 < starts.count ? starts[offset + 1] : end
            var contentEnd = next
            while contentEnd > start + 1, providerTrivia(lines[contentEnd - 1]) { contentEnd -= 1 }
            let block = try providerBlock(in: lines, start: start, end: contentEnd, indent: indent!)
            guard names.insert(block.definition.name).inserted else { throw RuleProviderError.duplicate(block.definition.name) }
            blocks.append(block)
        }
        return ProviderSection(key: key, end: end, blocks: blocks)
    }

    private static func providerBlock(in lines: [String], start: Int, end: Int, indent: Int) throws -> ProviderBlock {
        let head = splitComment(lines[start].trimmingCharacters(in: .whitespaces)).content
        let pair = try providerPair(head)
        let name = try providerScalar(pair.key)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !name.contains(where: { $0.isNewline }), pair.value.isEmpty, name != "<<" else {
            throw RuleProviderError.unsupportedYAML("规则集条目必须是具名块映射")
        }
        var definition = RuleProviderDefinition(name: name)
        var fields: [Int] = []
        var fieldIndent: Int?
        for i in (start + 1)..<end where !providerTrivia(lines[i]) {
            let currentIndent = lines[i].prefix { $0 == " " }.count
            if fieldIndent == nil { fieldIndent = currentIndent }
            guard currentIndent > indent, currentIndent >= fieldIndent! else { throw RuleProviderError.unsupportedYAML("不一致的字段缩进") }
            // YAML permits a sequence at the same indent as its owning mapping key.
            // It remains a child of that field, not another field to be discarded.
            if currentIndent == fieldIndent, !isDashItemLine(lines[i].trimmingCharacters(in: .whitespaces)) { fields.append(i) }
            else if fields.isEmpty { throw RuleProviderError.unsupportedYAML("规则集内容必须是字段映射") }
        }
        var seen: Set<String> = []
        var managedLines: Set<Int> = []
        for (offset, field) in fields.enumerated() {
            let next = offset + 1 < fields.count ? fields[offset + 1] : end
            let pair = try providerPair(splitComment(lines[field].trimmingCharacters(in: .whitespaces)).content)
            let key = try providerScalar(pair.key)
            guard key != "<<", seen.insert(key).inserted else { throw RuleProviderError.unsupportedYAML("合并或重复字段 \(key)") }
            guard managedProviderKeys.contains(key) else { continue }
            managedLines.formUnion(field..<next)
            let children = lines[(field + 1)..<next].filter { !providerTrivia($0) }
            if key == "payload" {
                if pair.value.isEmpty {
                    var payload: [String] = []
                    var itemIndent: Int?
                    for line in children {
                        let text = line.trimmingCharacters(in: .whitespaces)
                        let currentIndent = line.prefix { $0 == " " }.count
                        if itemIndent == nil { itemIndent = currentIndent }
                        guard isDashItemLine(text), currentIndent == itemIndent, currentIndent >= fieldIndent! else {
                            throw RuleProviderError.unsupportedYAML("payload 必须是单行字符串列表")
                        }
                        payload.append(try providerScalar(splitComment(String(text.dropFirst())).content))
                    }
                    definition.payload = payload
                } else {
                    guard children.isEmpty else { throw RuleProviderError.unsupportedYAML("多行流式 payload") }
                    definition.payload = try providerPayload(pair.value)
                }
                continue
            }
            guard children.isEmpty else { throw RuleProviderError.unsupportedYAML("多行字段 \(key)") }
            if key == "interval" {
                let raw = pair.value.hasPrefix("'") || pair.value.hasPrefix("\"") ? try providerScalar(pair.value) : pair.value
                guard raw.range(of: "^-?[0-9]+$", options: .regularExpression) != nil, let value = Int(raw) else {
                    throw RuleProviderError.unsupportedYAML("interval 必须是整数")
                }
                definition.interval = value
            } else {
                let value = try providerScalar(pair.value)
                switch key {
                case "type": definition.type = value
                case "behavior": definition.behavior = value
                case "format": definition.format = value
                case "url": definition.url = value
                case "path": definition.path = value
                default: break
                }
            }
        }
        return ProviderBlock(definition: definition, start: start, end: end, indent: indent,
                             fieldIndent: fieldIndent ?? indent + 2, managedLines: managedLines)
    }

    /// A block key separator, not a colon embedded in a quoted name or URL.
    private static func providerPair(_ text: String) throws -> (key: String, value: String) {
        var quote: Character?
        var escaped = false
        for i in text.indices {
            let c = text[i]
            if escaped { escaped = false; continue }
            if quote == "\"", c == "\\" { escaped = true; continue }
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "'" || c == "\"" {
                quote = c
            } else if c == ":" {
                let next = text.index(after: i)
                if next == text.endIndex || text[next].isWhitespace {
                    return (String(text[..<i]).trimmingCharacters(in: .whitespaces), String(text[next...]).trimmingCharacters(in: .whitespaces))
                }
            }
        }
        throw RuleProviderError.unsupportedYAML("无法解析映射键")
    }

    /// Accept only scalars whose decoded value is known exactly. No anchors, tags,
    /// aliases, multiline folding, implicit nulls, or nested collections.
    private static func providerScalar(_ raw: String) throws -> String {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("\""), let value = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed) as? String {
            return value
        }
        if text.hasPrefix("'"), text.hasSuffix("'"), text.count >= 2 {
            let inner = String(text.dropFirst().dropLast())
            guard !inner.replacingOccurrences(of: "''", with: "").contains("'") else { throw RuleProviderError.unsupportedYAML("单引号字符串") }
            return inner.replacingOccurrences(of: "''", with: "'")
        }
        let indicators: Set<Character> = ["-", "?", ":", ",", "[", "]", "{", "}", "#", "&", "*", "!", "|", ">", "'", "\"", "%", "@", "`"]
        let implicit = ["null", "~", "true", "false", "yes", "no", "on", "off"]
        guard let first = text.first, !indicators.contains(first),
              !text.contains("'") && !text.contains("\""), !text.contains(": "), !text.hasSuffix(":"),
              !implicit.contains(text.lowercased()), Double(text) == nil,
              !text.contains(where: { $0.isNewline }) else { throw RuleProviderError.unsupportedYAML("需要普通或带引号的单行字符串") }
        return text
    }

    private static func providerPayload(_ raw: String) throws -> [String] {
        guard raw.hasPrefix("["), raw.hasSuffix("]") else { throw RuleProviderError.unsupportedYAML("payload 必须是字符串列表") }
        let inner = String(raw.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        if inner.isEmpty { return [] }
        // Unlike splitFlowSequence, do not silently discard empty items or unmatched quotes.
        var items: [String] = []
        var start = inner.startIndex
        var quote: Character?
        var escaped = false
        for i in inner.indices {
            let c = inner[i]
            if escaped { escaped = false; continue }
            if quote == "\"", c == "\\" { escaped = true; continue }
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "'" || c == "\"" {
                quote = c
            } else if c == "," {
                items.append(try providerScalar(String(inner[start..<i])))
                start = inner.index(after: i)
            } else if "[]{}".contains(c) {
                throw RuleProviderError.unsupportedYAML("嵌套 payload")
            }
        }
        guard quote == nil else { throw RuleProviderError.unsupportedYAML("未闭合的 payload 字符串") }
        items.append(try providerScalar(String(inner[start...])))
        return items
    }
}
