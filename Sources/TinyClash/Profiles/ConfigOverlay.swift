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

    /// 标准多行块级 YAML
    func yamlLines(indent: String) -> [String] {
        let pad = indent + "  "
        var lines = ["\(indent)- name: \(ConfigOverlay.yamlScalar(name))"]
        lines.append("\(pad)type: \(ConfigOverlay.yamlScalar(type))")
        if !proxies.isEmpty {
            lines.append("\(pad)proxies:")
            for proxy in proxies {
                lines.append("\(pad)  - \(ConfigOverlay.yamlScalar(proxy))")
            }
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

/// Minimal, text-preserving edits on official top-level YAML sections.
/// Also used to read legacy profiles.json overlays until that profile is edited.
/// This intentionally is not a general YAML parser; mihomo validates the result.
enum ConfigOverlay {
    struct RuleTarget: Equatable {
        var index: Int?
        var type: String
        var payload: String
        var proxy: String
    }

    struct GroupSummary: Equatable {
        var name: String
        var apiType: String
        var proxies: [String]
        var includeAll: Bool
    }

    static func apiGroupType(_ raw: String) -> String {
        switch raw.lowercased() {
        case "select": return "Selector"
        case "url-test": return "URLTest"
        case "fallback": return "Fallback"
        case "load-balance": return "LoadBalance"
        default: return raw
        }
    }

    static func apiRuleType(_ raw: String) -> String {
        switch normalizeType(raw) {
        case "domain": return "Domain"
        case "domainsuffix": return "DomainSuffix"
        case "domainkeyword": return "DomainKeyword"
        case "domainregex": return "DomainRegex"
        case "domainwildcard": return "DomainWildcard"
        case "geosite": return "GeoSite"
        case "geoip": return "GeoIP"
        case "ipcidr": return "IPCIDR"
        case "ipcidr6": return "IPCIDR6"
        case "ipasn": return "IPASN"
        case "srcipcidr": return "SrcIPCIDR"
        case "srcport": return "SrcPort"
        case "dstport": return "DstPort"
        case "inport": return "InPort"
        case "intype": return "InType"
        case "inuser": return "InUser"
        case "inname": return "InName"
        case "processname": return "Process"
        case "processpath": return "ProcessPath"
        case "network": return "Network"
        case "uid": return "UID"
        case "ruleset": return "RuleSet"
        case "and": return "AND"
        case "or": return "OR"
        case "not": return "NOT"
        case "subrule": return "SubRule"
        case "match", "final": return "Match"
        default: return raw
        }
    }

    enum OverlayError: LocalizedError {
        case flowStyle(String)
        case duplicateGroup(String)
        case groupNotFound(String)
        case ruleNotFound

        var errorDescription: String? {
            switch self {
            case .flowStyle(let key):
                return "配置中的 \(key) 使用了暂不支持安全修改的 YAML 写法，请先改为普通列表"
            case .duplicateGroup(let name):
                return "配置中已存在名为「\(name)」的策略组"
            case .groupNotFound(let name):
                return "未在当前配置文件中找到策略组「\(name)」"
            case .ruleNotFound:
                return "未在当前配置文件中找到该规则（可能来自规则集或配置已变更）"
            }
        }
    }

    // MARK: - Public operations

    /// 兼容旧版 profiles.json 覆盖层与测试：去重合并规则（插入最前）与策略组（追加末尾）
    static func apply(rules: [String], groups: [CustomGroup], to yaml: String) throws -> String {
        guard !rules.isEmpty || !groups.isEmpty else { return yaml }
        let newline = yaml.contains("\r\n") ? "\r\n" : "\n"
        var lines = yaml.components(separatedBy: newline)
        try insertGroups(groups, deduplicate: true, into: &lines)
        try insertRules(rules, deduplicate: true, into: &lines)
        return lines.joined(separator: newline)
    }

    static func addRule(_ rule: String, to yaml: String) throws -> String {
        let newline = yaml.contains("\r\n") ? "\r\n" : "\n"
        var lines = yaml.components(separatedBy: newline)
        try insertRules([rule], deduplicate: false, into: &lines)
        return lines.joined(separator: newline)
    }

    static func addGroup(_ group: CustomGroup, to yaml: String) throws -> String {
        let newline = yaml.contains("\r\n") ? "\r\n" : "\n"
        var lines = yaml.components(separatedBy: newline)
        try insertGroups([group], deduplicate: false, into: &lines)
        return lines.joined(separator: newline)
    }

    static func removeGroup(named name: String, from yaml: String) throws -> String {
        let newline = yaml.contains("\r\n") ? "\r\n" : "\n"
        var lines = yaml.components(separatedBy: newline)
        guard let keyIndex = topLevelKeyIndex("proxy-groups", in: lines) else {
            throw OverlayError.groupNotFound(name)
        }
        let rawAfterKey = String(lines[keyIndex].dropFirst("proxy-groups:".count))
        let (rest, inlineComment) = splitComment(rawAfterKey)

        if rest.hasPrefix("["), rest.hasSuffix("]"), let range = lines[keyIndex].range(of: rest) {
            let inner = String(rest.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            var items = splitFlowSequence(inner)
            guard let idx = items.firstIndex(where: { flowGroupName($0) == name }) else {
                throw OverlayError.groupNotFound(name)
            }
            items.remove(at: idx)
            lines[keyIndex].replaceSubrange(range, with: "[\(items.joined(separator: ", "))]")
            return lines.joined(separator: newline)
        } else if !rest.isEmpty {
            throw OverlayError.flowStyle("proxy-groups")
        }

        let end = sectionEnd(after: keyIndex, in: lines)
        let blocks = parseGroupBlocks(in: lines, range: (keyIndex + 1)..<end)
        guard let target = blocks.first(where: { $0.name == name }) else {
            throw OverlayError.groupNotFound(name)
        }
        lines.removeSubrange(target.removeStart..<target.removeEnd)

        let newEnd = sectionEnd(after: keyIndex, in: lines)
        if parseGroupBlocks(in: lines, range: (keyIndex + 1)..<newEnd).isEmpty {
            lines[keyIndex] = "proxy-groups: []" + inlineComment
        }
        return lines.joined(separator: newline)
    }

    /// 读取配置文件中的策略组，供编辑表单预填；无法安全解析的写法返回 nil
    static func group(named name: String, in yaml: String) -> CustomGroup? {
        let lines = yaml.components(separatedBy: yaml.contains("\r\n") ? "\r\n" : "\n")
        guard let keyIndex = topLevelKeyIndex("proxy-groups", in: lines) else { return nil }
        let (rest, _) = splitComment(String(lines[keyIndex].dropFirst("proxy-groups:".count)))
        if rest.hasPrefix("["), rest.hasSuffix("]") {
            let items = splitFlowSequence(String(rest.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces))
            return items.first { flowGroupName($0) == name }.flatMap(jsonMapping).map { groupFields(from: $0).group }
        }
        guard rest.isEmpty else { return nil }
        let end = sectionEnd(after: keyIndex, in: lines)
        guard let block = parseGroupBlocks(in: lines, range: (keyIndex + 1)..<end).first(where: { $0.name == name }) else { return nil }
        return parseGroupBody(lines[block.removeStart..<block.contentEnd], dashIndent: block.dashIndent)?.group
    }

    /// 读取配置文件中的策略组摘要列表，用于重启内核前在 UI 中同步最新策略组状态
    static func groupSummaries(in yaml: String) -> [GroupSummary] {
        let lines = yaml.components(separatedBy: yaml.contains("\r\n") ? "\r\n" : "\n")
        guard let keyIndex = topLevelKeyIndex("proxy-groups", in: lines) else { return [] }
        let (rest, _) = splitComment(String(lines[keyIndex].dropFirst("proxy-groups:".count)))
        if rest.hasPrefix("["), rest.hasSuffix("]") {
            let inner = String(rest.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            let items = inner.isEmpty ? [] : splitFlowSequence(inner)
            return items.compactMap(flowGroupSummary)
        }
        guard rest.isEmpty else { return [] }
        let end = sectionEnd(after: keyIndex, in: lines)
        return parseGroupBlocks(in: lines, range: (keyIndex + 1)..<end).compactMap { block in
            guard let name = block.name, !name.isEmpty else { return nil }
            if let g = parseGroupBody(lines[block.removeStart..<block.contentEnd], dashIndent: block.dashIndent)?.group {
                return GroupSummary(name: g.name, apiType: apiGroupType(g.type), proxies: g.proxies, includeAll: g.includeAll)
            }
            return GroupSummary(name: name, apiType: "Selector", proxies: [], includeAll: false)
        }
    }

    private static func flowGroupSummary(_ mapping: String) -> GroupSummary? {
        if let map = jsonMapping(mapping) {
            let g = groupFields(from: map).group
            guard !g.name.isEmpty else { return nil }
            return GroupSummary(name: g.name, apiType: apiGroupType(g.type), proxies: g.proxies, includeAll: g.includeAll)
        }
        let trimmed = mapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return nil }
        let inner = String(trimmed.dropFirst().dropLast())
        var name = ""
        var type = "select"
        var proxies: [String] = []
        var includeAll = false
        for pair in splitFlowSequence(inner) {
            guard let (key, val) = splitFlowPair(pair) else { continue }
            switch key {
            case "name": name = unquoteScalar(val)
            case "type": type = unquoteScalar(val)
            case "include-all": includeAll = unquoteScalar(val).lowercased() == "true"
            case "proxies":
                let v = val.trimmingCharacters(in: .whitespaces)
                if v.hasPrefix("["), v.hasSuffix("]") {
                    let seq = String(v.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                    proxies = seq.isEmpty ? [] : splitFlowSequence(seq).map(unquoteScalar)
                }
            default: break
            }
        }
        guard !name.isEmpty else { return nil }
        return GroupSummary(name: name, apiType: apiGroupType(type), proxies: proxies, includeAll: includeAll)
    }

    private static func splitFlowPair(_ pair: String) -> (key: String, value: String)? {
        var quote: Character?
        var escaped = false
        for idx in pair.indices {
            let c = pair[idx]
            if escaped { escaped = false; continue }
            if quote == "\"", c == "\\" { escaped = true; continue }
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "'" || c == "\"" {
                quote = c
            } else if c == ":" {
                let key = unquoteScalar(String(pair[..<idx]))
                let val = String(pair[pair.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
                return (key, val)
            }
        }
        return nil
    }

    /// 原位替换策略组：表单管理的字段按标准 YAML 重写，其余字段（use、lazy 等）原样保留
    static func replaceGroup(named name: String, with group: CustomGroup, in yaml: String) throws -> String {
        let newline = yaml.contains("\r\n") ? "\r\n" : "\n"
        var lines = yaml.components(separatedBy: newline)
        guard let keyIndex = topLevelKeyIndex("proxy-groups", in: lines) else { throw OverlayError.groupNotFound(name) }
        let (rest, _) = splitComment(String(lines[keyIndex].dropFirst("proxy-groups:".count)))

        if rest.hasPrefix("["), rest.hasSuffix("]"), let range = lines[keyIndex].range(of: rest) {
            var items = splitFlowSequence(String(rest.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces))
            guard let idx = items.firstIndex(where: { flowGroupName($0) == name }), let mapping = jsonMapping(items[idx]) else {
                throw OverlayError.groupNotFound(name)
            }
            items[idx] = group.flowYAML(keeping: groupFields(from: mapping).extras)
            lines[keyIndex].replaceSubrange(range, with: "[\(items.joined(separator: ", "))]")
            return lines.joined(separator: newline)
        } else if !rest.isEmpty {
            throw OverlayError.flowStyle("proxy-groups")
        }

        let end = sectionEnd(after: keyIndex, in: lines)
        guard let block = parseGroupBlocks(in: lines, range: (keyIndex + 1)..<end).first(where: { $0.name == name }),
              let parsed = parseGroupBody(lines[block.removeStart..<block.contentEnd], dashIndent: block.dashIndent) else {
            throw OverlayError.groupNotFound(name)
        }
        let pad = block.dashIndent + "  "
        var replacement = group.yamlLines(indent: block.dashIndent)
        for extra in parsed.extras {
            replacement.append(pad + extra.head)
            replacement.append(contentsOf: extra.children.map { reindent($0, by: pad.count - parsed.keyIndent) })
        }
        lines.replaceSubrange(block.removeStart..<block.contentEnd, with: replacement)
        return lines.joined(separator: newline)
    }

    static func removeRule(_ target: RuleTarget, from yaml: String) throws -> String {
        try editRule(target, in: yaml, replacement: nil)
    }

    /// 原位替换规则，保留缩进、行尾注释与匹配顺序
    static func replaceRule(_ target: RuleTarget, with rule: String, in yaml: String) throws -> String {
        try editRule(target, in: yaml, replacement: rule)
    }

    /// 配置文件中与运行时规则对应的原始文本（未经内核规范化）
    static func ruleText(_ target: RuleTarget, in yaml: String) -> String? {
        let lines = yaml.components(separatedBy: yaml.contains("\r\n") ? "\r\n" : "\n")
        guard let keyIndex = topLevelKeyIndex("rules", in: lines) else { return nil }
        let (rest, _) = splitComment(String(lines[keyIndex].dropFirst("rules:".count)))
        if rest.hasPrefix("["), rest.hasSuffix("]") {
            let texts = splitFlowSequence(String(rest.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)).map(unquoteScalar)
            let match = selectRuleMatch(target: target, entries: texts.enumerated().map { ($0.offset, parseRuleFields($0.element)) })
            return match.map { texts[$0] }
        }
        guard rest.isEmpty else { return nil }
        let entries = parseRuleEntries(in: lines, range: (keyIndex + 1)..<sectionEnd(after: keyIndex, in: lines))
        let match = selectRuleMatch(target: target, entries: entries.enumerated().map { ($0.offset, $0.element.parsed) })
        return match.map { entries[$0].text }
    }

    /// 读取配置文件中的规则列表，用于重启内核前在 UI 中同步最新规则顺序与条目
    static func ruleItems(in yaml: String) -> [RuleItem] {
        let lines = yaml.components(separatedBy: yaml.contains("\r\n") ? "\r\n" : "\n")
        guard let keyIndex = topLevelKeyIndex("rules", in: lines) else { return [] }
        let (rest, _) = splitComment(String(lines[keyIndex].dropFirst("rules:".count)))
        let parsedList: [ParsedRule?]
        if rest.hasPrefix("["), rest.hasSuffix("]") {
            let inner = String(rest.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            parsedList = inner.isEmpty ? [] : splitFlowSequence(inner).map { parseRuleFields(unquoteScalar($0)) }
        } else if rest.isEmpty {
            let entries = parseRuleEntries(in: lines, range: (keyIndex + 1)..<sectionEnd(after: keyIndex, in: lines))
            parsedList = entries.map(\.parsed)
        } else {
            return []
        }
        return parsedList.enumerated().compactMap { idx, parsed in
            guard let parsed else { return nil }
            return RuleItem(index: idx, type: apiRuleType(parsed.rawType), payload: parsed.payload, proxy: parsed.proxy)
        }
    }

    private static func editRule(_ target: RuleTarget, in yaml: String, replacement: String?) throws -> String {
        let newline = yaml.contains("\r\n") ? "\r\n" : "\n"
        var lines = yaml.components(separatedBy: newline)
        guard let keyIndex = topLevelKeyIndex("rules", in: lines) else {
            throw OverlayError.ruleNotFound
        }
        let rawAfterKey = String(lines[keyIndex].dropFirst("rules:".count))
        let (rest, inlineComment) = splitComment(rawAfterKey)

        if rest.hasPrefix("["), rest.hasSuffix("]"), let range = lines[keyIndex].range(of: rest) {
            let inner = String(rest.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            var items = splitFlowSequence(inner)
            let parsed = items.enumerated().map { (offset, raw) in
                (offset: offset, parsed: parseRuleFields(unquoteScalar(raw)))
            }
            guard let match = selectRuleMatch(target: target, entries: parsed.map { ($0.offset, $0.parsed) }) else {
                throw OverlayError.ruleNotFound
            }
            if let replacement { items[match] = quote(replacement) } else { items.remove(at: match) }
            lines[keyIndex].replaceSubrange(range, with: "[\(items.joined(separator: ", "))]")
            return lines.joined(separator: newline)
        } else if !rest.isEmpty {
            throw OverlayError.flowStyle("rules")
        }

        let end = sectionEnd(after: keyIndex, in: lines)
        let entries = parseRuleEntries(in: lines, range: (keyIndex + 1)..<end)
        guard let match = selectRuleMatch(target: target, entries: entries.map { ($0.lineIndex, $0.parsed) }) else {
            throw OverlayError.ruleNotFound
        }
        if let replacement {
            let line = lines[match]
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            let afterDash = String(line.drop { $0 == " " || $0 == "\t" }.dropFirst()).trimmingCharacters(in: .whitespaces)
            let (_, comment) = splitComment(afterDash)
            lines[match] = indent + "- " + yamlRuleScalar(replacement) + comment
            return lines.joined(separator: newline)
        }
        lines.remove(at: match)

        let newEnd = sectionEnd(after: keyIndex, in: lines)
        if parseRuleEntries(in: lines, range: (keyIndex + 1)..<newEnd).isEmpty {
            lines[keyIndex] = "rules: []" + inlineComment
        }
        return lines.joined(separator: newline)
    }

    // MARK: - Insertion

    private static func insertRules(_ rules: [String], deduplicate: Bool, into lines: inout [String]) throws {
        guard !rules.isEmpty else { return }
        guard let keyIndex = topLevelKeyIndex("rules", in: lines) else {
            if lines.last?.isEmpty == false { lines.append("") }
            lines.append("rules:")
            lines.append(contentsOf: rules.map { "  - \(yamlRuleScalar($0))" })
            lines.append("")
            return
        }

        let rawAfterKey = String(lines[keyIndex].dropFirst("rules:".count))
        let (rest, inlineComment) = splitComment(rawAfterKey)
        if rest.hasPrefix("["), rest.hasSuffix("]"), let range = lines[keyIndex].range(of: rest) {
            let inner = String(rest.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            if inner.isEmpty {
                // 空流式列表 `rules: []` 转为标准块级列表
                lines[keyIndex] = "rules:" + inlineComment
                lines.insert(contentsOf: rules.map { "  - \(yamlRuleScalar($0))" }, at: keyIndex + 1)
                return
            }
            let existing = Set(splitFlowSequence(inner).map(unquoteScalar))
            var seen = deduplicate ? existing : Set<String>()
            let items = rules.filter { !deduplicate || seen.insert($0).inserted }.map(quote)
            guard !items.isEmpty else { return }
            lines[keyIndex].replaceSubrange(range, with: "[\(items.joined(separator: ", ")), \(inner)]")
            return
        } else if !rest.isEmpty {
            throw OverlayError.flowStyle("rules")
        }

        let end = sectionEnd(after: keyIndex, in: lines)
        let existing = Set(parseRuleEntries(in: lines, range: (keyIndex + 1)..<end).map(\.text))
        var seen = deduplicate ? existing : Set<String>()
        let filtered = deduplicate ? rules.filter { seen.insert($0).inserted } : rules
        guard !filtered.isEmpty else { return }

        let indent = listIndent(in: lines, range: (keyIndex + 1)..<end)
        lines.insert(contentsOf: filtered.map { "\(indent)- \(yamlRuleScalar($0))" }, at: keyIndex + 1)
    }

    private static func insertGroups(_ groups: [CustomGroup], deduplicate: Bool, into lines: inout [String]) throws {
        guard !groups.isEmpty else { return }
        guard let keyIndex = topLevelKeyIndex("proxy-groups", in: lines) else {
            if lines.last?.isEmpty == false { lines.append("") }
            lines.append("proxy-groups:")
            for group in groups {
                lines.append(contentsOf: group.yamlLines(indent: "  "))
            }
            lines.append("")
            return
        }

        let rawAfterKey = String(lines[keyIndex].dropFirst("proxy-groups:".count))
        let (rest, inlineComment) = splitComment(rawAfterKey)
        if rest.hasPrefix("["), rest.hasSuffix("]"), let range = lines[keyIndex].range(of: rest) {
            let inner = String(rest.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            if inner.isEmpty {
                // 空流式列表 `proxy-groups: []` 转为标准块级列表
                lines[keyIndex] = "proxy-groups:" + inlineComment
                let inserted = groups.flatMap { $0.yamlLines(indent: "  ") }
                lines.insert(contentsOf: inserted, at: keyIndex + 1)
                return
            }
            let existingNames = Set(splitFlowSequence(inner).compactMap(flowGroupName))
            var seen = existingNames
            var toAdd: [CustomGroup] = []
            for group in groups {
                if seen.contains(group.name) {
                    if deduplicate { continue }
                    throw OverlayError.duplicateGroup(group.name)
                }
                seen.insert(group.name)
                toAdd.append(group)
            }
            guard !toAdd.isEmpty else { return }
            let added = toAdd.map(\.flowYAML).joined(separator: ", ")
            lines[keyIndex].replaceSubrange(range, with: "[\(inner), \(added)]")
            return
        } else if !rest.isEmpty {
            throw OverlayError.flowStyle("proxy-groups")
        }

        let end = sectionEnd(after: keyIndex, in: lines)
        let existingNames = Set(parseGroupBlocks(in: lines, range: (keyIndex + 1)..<end).compactMap(\.name))
        var seen = existingNames
        var toAdd: [CustomGroup] = []
        for group in groups {
            if seen.contains(group.name) {
                if deduplicate { continue }
                throw OverlayError.duplicateGroup(group.name)
            }
            seen.insert(group.name)
            toAdd.append(group)
        }
        guard !toAdd.isEmpty else { return }

        let indent = listIndent(in: lines, range: (keyIndex + 1)..<end)
        var at = end
        while at > keyIndex + 1 {
            let t = lines[at - 1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.isEmpty || t.hasPrefix("#") else { break }
            at -= 1
        }
        let inserted = toAdd.flatMap { $0.yamlLines(indent: indent) }
        lines.insert(contentsOf: inserted, at: at)
    }

    // MARK: - Section & Block Helpers

    private static func topLevelKeyIndex(_ key: String, in lines: [String]) -> Int? {
        lines.firstIndex { $0.hasPrefix("\(key):") }
    }

    private static func sectionEnd(after keyIndex: Int, in lines: [String]) -> Int {
        for i in (keyIndex + 1)..<lines.count {
            let line = lines[i]
            guard let first = line.first, first != " ", first != "\t", first != "-", first != "#", first != "\r" else { continue }
            return i
        }
        return lines.count
    }

    private static func listIndent(in lines: [String], range: Range<Int>) -> String {
        for line in lines[range] {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("-") { return String(line.prefix { $0 == " " }) }
            break
        }
        return "  "
    }

    private struct GroupBlock {
        var name: String?
        var removeStart: Int
        var removeEnd: Int
        var contentEnd: Int
        var dashIndent: String
    }

    private static func parseGroupBlocks(in lines: [String], range: Range<Int>) -> [GroupBlock] {
        var dashIndent: String?
        var starts: [Int] = []
        for i in range {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = String(line.prefix { $0 == " " })
            if let expected = dashIndent {
                if indent == expected && isDashItemLine(trimmed) {
                    starts.append(i)
                }
            } else if isDashItemLine(trimmed) {
                dashIndent = indent
                starts.append(i)
            } else {
                break
            }
        }
        guard let dashIndent else { return [] }
        return starts.enumerated().map { idx, start in
            let nextStart = idx + 1 < starts.count ? starts[idx + 1] : range.upperBound
            var contentEnd = nextStart
            while contentEnd > start + 1 {
                let t = lines[contentEnd - 1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard t.isEmpty || t.hasPrefix("#") else { break }
                contentEnd -= 1
            }
            // 删除时带走紧随其后的一行空行（如有），保留下一组前的注释
            let removeEnd: Int
            if contentEnd < nextStart && lines[contentEnd].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                removeEnd = contentEnd + 1
            } else {
                removeEnd = contentEnd
            }
            let name = extractGroupName(from: lines[start..<contentEnd], dashIndent: dashIndent)
            return GroupBlock(name: name, removeStart: start, removeEnd: removeEnd,
                              contentEnd: contentEnd, dashIndent: dashIndent)
        }
    }

    private static let managedGroupKeys: Set<String> = ["name", "type", "proxies", "url", "interval", "include-all", "filter"]

    /// 表单未管理的键：首行（不含缩进的 `key: value`）及其下级行（保留原缩进）
    private struct ExtraKey {
        var head: String
        var children: [String]
    }

    /// 解析块级策略组条目；单行 `- {...}`（JSON 写法）转换后同样支持
    private static func parseGroupBody(_ block: ArraySlice<String>, dashIndent: String)
        -> (group: CustomGroup, extras: [ExtraKey], keyIndent: Int)? {
        guard let first = block.first else { return nil }
        let afterDashRaw = String(first.dropFirst(dashIndent.count).dropFirst())
        let spaces = afterDashRaw.prefix { $0 == " " }.count
        let firstRaw = String(afterDashRaw.dropFirst(spaces)).trimmingCharacters(in: .newlines)
        let (firstContent, _) = splitComment(firstRaw)
        if firstContent.hasPrefix("{") {
            guard let mapping = jsonMapping(block.joined(separator: " ").drop { $0 != "{" }.description) else { return nil }
            let fields = groupFields(from: mapping)
            let extras = fields.extras.sorted { $0.key < $1.key }.map { ExtraKey(head: "\($0.key): \(jsonText($0.value))", children: []) }
            return (fields.group, extras, dashIndent.count + 2)
        }

        // 按键拆分：(去注释行内容用于解析, 保留注释的原始行, 下级行)
        var chunks: [(content: String, raw: String, children: [String])] = []
        var keyIndent: Int?
        if !firstContent.isEmpty {
            keyIndent = dashIndent.count + 1 + spaces
            chunks.append((firstContent, firstRaw, []))
        }
        for line in block.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let indent = line.prefix { $0 == " " }.count
            if keyIndent == nil, !trimmed.isEmpty, !trimmed.hasPrefix("#") { keyIndent = indent }
            if let keyIndent, indent == keyIndent, !trimmed.isEmpty, !trimmed.hasPrefix("#"), !isDashItemLine(trimmed) {
                chunks.append((splitComment(trimmed).content, trimmed, []))
            } else if !chunks.isEmpty {
                chunks[chunks.count - 1].children.append(line)
            }
        }
        guard let keyIndent else { return nil }

        var group = CustomGroup()
        var extras: [ExtraKey] = []
        for chunk in chunks {
            guard let colon = chunk.content.firstIndex(of: ":") else { return nil }
            let key = unquoteScalar(String(chunk.content[..<colon]))
            let value = String(chunk.content[chunk.content.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "name": group.name = unquoteScalar(value)
            case "type": group.type = unquoteScalar(value)
            case "url": group.url = unquoteScalar(value)
            case "interval": group.interval = Int(unquoteScalar(value)) ?? group.interval
            case "include-all": group.includeAll = unquoteScalar(value).lowercased() == "true"
            case "filter": group.filter = unquoteScalar(value)
            case "proxies":
                if value.hasPrefix("[") && value.hasSuffix("]") {
                    group.proxies = splitFlowSequence(String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)).map(unquoteScalar)
                } else {
                    group.proxies = chunk.children.compactMap { line in
                        let t = line.trimmingCharacters(in: .whitespaces)
                        guard isDashItemLine(t) else { return nil }
                        let item = splitComment(String(t.dropFirst()).trimmingCharacters(in: .whitespaces)).content
                        return item.isEmpty ? nil : unquoteScalar(item)
                    }
                }
            default:
                extras.append(ExtraKey(head: chunk.raw, children: chunk.children))
            }
        }
        return (group, extras, keyIndent)
    }

    private static func jsonMapping(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    private static func jsonText(_ value: Any) -> String {
        if let s = value as? String { return yamlScalar(s) }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func groupFields(from mapping: [String: Any]) -> (group: CustomGroup, extras: [String: Any]) {
        var group = CustomGroup()
        group.name = mapping["name"] as? String ?? ""
        group.type = mapping["type"] as? String ?? "select"
        group.proxies = mapping["proxies"] as? [String] ?? []
        group.url = mapping["url"] as? String ?? ""
        group.interval = (mapping["interval"] as? NSNumber)?.intValue ?? group.interval
        group.includeAll = (mapping["include-all"] as? Bool) ?? false
        group.filter = mapping["filter"] as? String ?? ""
        return (group, mapping.filter { !managedGroupKeys.contains($0.key) })
    }

    private static func reindent(_ line: String, by delta: Int) -> String {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
        if delta >= 0 { return String(repeating: " ", count: delta) + line }
        let removable = min(-delta, line.prefix { $0 == " " }.count)
        return String(line.dropFirst(removable))
    }

    private static func isDashItemLine(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("-") else { return false }
        let rest = trimmed.dropFirst()
        return rest.isEmpty || rest.first == " " || rest.first == "\t"
    }

    private static func extractGroupName(from blockLines: ArraySlice<String>, dashIndent: String) -> String? {
        guard let firstLine = blockLines.first else { return nil }
        let afterIndent = String(firstLine.dropFirst(dashIndent.count))
        guard afterIndent.hasPrefix("-") else { return nil }
        let afterDashRaw = String(afterIndent.dropFirst())
        let spacesAfterDash = afterDashRaw.prefix { $0 == " " }
        let afterDash = String(afterDashRaw.dropFirst(spacesAfterDash.count))
        let (firstContent, _) = splitComment(afterDash)

        if firstContent.hasPrefix("{") {
            let fullFlow = blockLines.joined(separator: " ")
            if let start = fullFlow.firstIndex(of: "{"), let end = fullFlow.lastIndex(of: "}") {
                return flowGroupName(String(fullFlow[start...end]))
            }
            return nil
        }

        var keyIndentCount: Int?
        if !firstContent.isEmpty {
            if let value = extractKeyValue(key: "name", from: firstContent) {
                return value
            }
            keyIndentCount = dashIndent.count + 1 + spacesAfterDash.count
        }

        for line in blockLines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indentCount = line.prefix { $0 == " " }.count
            if keyIndentCount == nil { keyIndentCount = indentCount }
            guard indentCount == keyIndentCount else { continue }
            let (content, _) = splitComment(trimmed)
            if let value = extractKeyValue(key: "name", from: content) {
                return value
            }
        }
        return nil
    }

    private static func extractKeyValue(key: String, from lineContent: String) -> String? {
        for candidate in [key, "'\(key)'", "\"\(key)\""] {
            guard lineContent.hasPrefix(candidate) else { continue }
            let afterKey = lineContent.dropFirst(candidate.count).drop { $0 == " " }
            guard afterKey.hasPrefix(":") else { continue }
            let rawValue = String(afterKey.dropFirst()).trimmingCharacters(in: .whitespaces)
            return rawValue.isEmpty ? nil : unquoteScalar(rawValue)
        }
        return nil
    }

    // MARK: - Rule Parsing & Matching

    private struct ParsedRule {
        var rawType: String
        var normalizedType: String
        var payload: String
        var proxy: String
    }

    private struct RuleEntry {
        var lineIndex: Int
        var text: String
        var parsed: ParsedRule?
    }

    private static func parseRuleEntries(in lines: [String], range: Range<Int>) -> [RuleEntry] {
        var result: [RuleEntry] = []
        for i in range {
            let trimmed = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard isDashItemLine(trimmed) else { continue }
            let afterDash = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            let (rawScalar, _) = splitComment(afterDash)
            guard !rawScalar.isEmpty else { continue }
            let text = unquoteScalar(rawScalar)
            result.append(RuleEntry(lineIndex: i, text: text, parsed: parseRuleFields(text)))
        }
        return result
    }

    private static func parseRuleFields(_ text: String) -> ParsedRule? {
        let fields = splitTopLevelCommas(text).map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count >= 2 else { return nil }
        let normType = normalizeType(fields[0])
        if normType == "match" || normType == "final" {
            return ParsedRule(rawType: fields[0], normalizedType: normType, payload: "", proxy: fields[1])
        }
        guard fields.count >= 3 else { return nil }
        return ParsedRule(rawType: fields[0], normalizedType: normType, payload: fields[1], proxy: fields[2])
    }

    private static func selectRuleMatch<ID>(target: RuleTarget, entries: [(ID, ParsedRule?)]) -> ID? {
        let targetType = normalizeType(target.type)
        let compoundTypes: Set<String> = ["and", "or", "not", "subrule"]

        func matches(_ parsed: ParsedRule, allowCompoundPayloadMismatch: Bool) -> Bool {
            guard parsed.normalizedType == targetType, parsed.proxy == target.proxy else { return false }
            if allowCompoundPayloadMismatch && compoundTypes.contains(targetType) { return true }
            return parsed.payload.lowercased() == target.payload.lowercased()
        }

        if let index = target.index, entries.indices.contains(index),
           let parsed = entries[index].1, matches(parsed, allowCompoundPayloadMismatch: true) {
            return entries[index].0
        }

        // 先尝试 payload 大小写完全一致，再退回不区分大小写匹配
        if let exact = entries.first(where: { entry in
            guard let p = entry.1 else { return false }
            return p.normalizedType == targetType && p.proxy == target.proxy && p.payload == target.payload
        }) {
            return exact.0
        }
        return entries.first(where: { entry in
            guard let p = entry.1 else { return false }
            return matches(p, allowCompoundPayloadMismatch: false)
        })?.0
    }

    private static func normalizeType(_ type: String) -> String {
        type.lowercased().replacingOccurrences(of: "-", with: "")
    }

    // MARK: - Flow & Scalar Helpers

    private static func splitFlowSequence(_ inner: String) -> [String] {
        var result: [String] = []
        var current = ""
        var braceDepth = 0
        var bracketDepth = 0
        var quote: Character?
        var escaped = false

        for c in inner {
            if escaped {
                current.append(c)
                escaped = false
                continue
            }
            if quote == "\"", c == "\\" {
                current.append(c)
                escaped = true
                continue
            }
            if let q = quote {
                current.append(c)
                if c == q { quote = nil }
                continue
            }
            if c == "'" || c == "\"" {
                quote = c
                current.append(c)
            } else if c == "{" {
                braceDepth += 1
                current.append(c)
            } else if c == "}" {
                braceDepth = max(0, braceDepth - 1)
                current.append(c)
            } else if c == "[" {
                bracketDepth += 1
                current.append(c)
            } else if c == "]" {
                bracketDepth = max(0, bracketDepth - 1)
                current.append(c)
            } else if c == ",", braceDepth == 0, bracketDepth == 0 {
                let item = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !item.isEmpty { result.append(item) }
                current = ""
            } else {
                current.append(c)
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result
    }

    private static func flowGroupName(_ mapping: String) -> String? {
        let trimmed = mapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return nil }
        let inner = String(trimmed.dropFirst().dropLast())
        for pair in splitFlowSequence(inner) {
            // 按最外层冒号切分键值
            var quote: Character?
            var escaped = false
            for idx in pair.indices {
                let c = pair[idx]
                if escaped { escaped = false; continue }
                if quote == "\"", c == "\\" { escaped = true; continue }
                if let q = quote {
                    if c == q { quote = nil }
                } else if c == "'" || c == "\"" {
                    quote = c
                } else if c == ":" {
                    let key = unquoteScalar(String(pair[..<idx]))
                    if key == "name" {
                        let val = String(pair[pair.index(after: idx)...])
                        let unquoted = unquoteScalar(val)
                        return unquoted.isEmpty ? nil : unquoted
                    }
                    break
                }
            }
        }
        return nil
    }

    static func splitTopLevelCommas(_ s: String) -> [String] {
        var result: [String] = []
        var current = ""
        var parenDepth = 0
        var quote: Character?
        var escaped = false

        for c in s {
            if escaped {
                current.append(c)
                escaped = false
                continue
            }
            if quote == "\"", c == "\\" {
                current.append(c)
                escaped = true
                continue
            }
            if let q = quote {
                current.append(c)
                if c == q { quote = nil }
                continue
            }
            if c == "'" || c == "\"" {
                quote = c
                current.append(c)
            } else if c == "(" {
                parenDepth += 1
                current.append(c)
            } else if c == ")" {
                parenDepth = max(0, parenDepth - 1)
                current.append(c)
            } else if c == ",", parenDepth == 0 {
                result.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        result.append(current)
        return result
    }

    private static func splitComment(_ s: String) -> (content: String, comment: String) {
        var quote: Character?
        var escaped = false
        for i in s.indices {
            let c = s[i]
            if escaped { escaped = false; continue }
            if quote == "\"", c == "\\" { escaped = true; continue }
            if let current = quote {
                if c == current { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "#", i == s.startIndex || s[s.index(before: i)].isWhitespace {
                let rawContent = s[..<i]
                let content = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
                let leadingSpace = i > s.startIndex && s[s.index(before: i)].isWhitespace ? " " : ""
                let comment = leadingSpace + s[i...].trimmingCharacters(in: .newlines)
                return (content, comment)
            }
        }
        return (s.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    static func unquoteScalar(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 2, s.hasPrefix("'"), s.hasSuffix("'") {
            return String(s.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") {
            if let decoded = try? JSONSerialization.jsonObject(with: Data(s.utf8), options: [.fragmentsAllowed]) as? String {
                return decoded
            }
            return String(s.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return s
    }

    /// 块级规则：普通内容不加引号（如 DOMAIN-SUFFIX,google.com,DIRECT），仅含 YAML 特殊字符时加引号
    static func yamlRuleScalar(_ rule: String) -> String {
        yamlScalar(rule, allowComma: true)
    }

    /// 块级 YAML 标量：安全时直接输出原文本，含特殊字符/布尔/数字字面量时加单引号或双引号
    static func yamlScalar(_ value: String, allowComma: Bool = false) -> String {
        if value.isEmpty { return "\"\"" }
        let hasControl = value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
        if hasControl { return quote(value) }
        if value.first?.isWhitespace == true || value.last?.isWhitespace == true {
            return singleQuote(value)
        }
        let reserved: Set<String> = ["true", "false", "yes", "no", "on", "off", "y", "n", "null", "~", ".nan", ".inf", "-.inf", "+.inf"]
        if reserved.contains(value.lowercased()) || Double(value) != nil ||
            value.hasPrefix("0x") || value.hasPrefix("0o") || value.hasPrefix("0b") {
            return singleQuote(value)
        }
        let leadingIndicators: Set<Character> = ["-", "?", ":", ",", "[", "]", "{", "}", "#", "&", "*", "!", "|", ">", "'", "\"", "%", "@", "`"]
        if let first = value.first, leadingIndicators.contains(first) {
            return singleQuote(value)
        }
        if value.contains(": ") || value.contains(" #") || value.hasSuffix(":") {
            return singleQuote(value)
        }
        var unsafeChars: Set<Character> = ["[", "]", "{", "}", "|", "'", "\"", "*", "&", "#", "\\", "$", "?"]
        if !allowComma { unsafeChars.insert(",") }
        if value.contains(where: { unsafeChars.contains($0) }) {
            return singleQuote(value)
        }
        return value
    }

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

    private static func singleQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    /// 以 JSON/YAML 双引号字符串输出（用于流式数组或包含控制字符的标量）
    static func quote(_ rule: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: rule, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}
