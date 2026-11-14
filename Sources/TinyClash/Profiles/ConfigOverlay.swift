import Foundation

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

    /// 内核 /rules 返回的类型名（DomainSuffix、IPCIDR…）还原成 YAML 写法，界面与配置文件用同一套名称
    static func yamlRuleType(_ apiType: String) -> String {
        let names: [String: String] = [
            "domain": "DOMAIN", "domainsuffix": "DOMAIN-SUFFIX", "domainkeyword": "DOMAIN-KEYWORD",
            "domainregex": "DOMAIN-REGEX", "domainwildcard": "DOMAIN-WILDCARD", "geosite": "GEOSITE",
            "geoip": "GEOIP", "ipcidr": "IP-CIDR", "ipcidr6": "IP-CIDR6", "ipasn": "IP-ASN",
            "ipsuffix": "IP-SUFFIX", "srcipcidr": "SRC-IP-CIDR", "srcport": "SRC-PORT", "dstport": "DST-PORT",
            "inport": "IN-PORT", "intype": "IN-TYPE", "inuser": "IN-USER", "inname": "IN-NAME",
            "process": "PROCESS-NAME", "processname": "PROCESS-NAME", "processpath": "PROCESS-PATH",
            "network": "NETWORK", "uid": "UID", "ruleset": "RULE-SET", "and": "AND", "or": "OR", "not": "NOT",
            "subrule": "SUB-RULE", "match": "MATCH",
        ]
        return names[normalizeType(apiType)] ?? apiType.uppercased()
    }

    enum OverlayError: LocalizedError {
        case flowStyle(String)
        case duplicateGroup(String)
        case groupNotFound(String)
        case ruleNotFound
        case unsupportedGroup(String)
        case mixedNewlines

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
            case .unsupportedGroup(let name):
                return "策略组「\(name)」使用了暂不支持安全修改的 YAML 写法（如多行字符串、锚点或别名），请在外部编辑器中修改"
            case .mixedNewlines:
                return "配置文件混用了 CRLF 与 LF 换行，请先在编辑器中统一换行符"
            }
        }
    }

    // MARK: - Public operations

    /// 兼容旧版 profiles.json 覆盖层与测试：去重合并规则（插入最前）与策略组（追加末尾）
    static func apply(rules: [String], groups: [CustomGroup], to yaml: String) throws -> String {
        guard !rules.isEmpty || !groups.isEmpty else { return yaml }
        var (lines, newline) = try editableLines(yaml)
        try insertGroups(groups, deduplicate: true, into: &lines)
        try insertRules(rules, deduplicate: true, into: &lines)
        return lines.joined(separator: newline)
    }

    static func addRule(_ rule: String, to yaml: String) throws -> String {
        var (lines, newline) = try editableLines(yaml)
        try insertRules([rule], deduplicate: false, into: &lines)
        return lines.joined(separator: newline)
    }

    static func addGroup(_ group: CustomGroup, to yaml: String) throws -> String {
        var (lines, newline) = try editableLines(yaml)
        try insertGroups([group], deduplicate: false, into: &lines)
        return lines.joined(separator: newline)
    }

    static func removeGroup(named name: String, from yaml: String) throws -> String {
        var (lines, newline) = try editableLines(yaml)
        guard let keyIndex = topLevelKeyIndex("proxy-groups", in: lines) else {
            throw OverlayError.groupNotFound(name)
        }
        let rawAfterKey = valueAfterKey(lines[keyIndex])
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
        if sectionStartsWithFlow(lines, range: (keyIndex + 1)..<end) { throw OverlayError.flowStyle("proxy-groups") }
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
        let lines = readableLines(yaml)
        guard let keyIndex = topLevelKeyIndex("proxy-groups", in: lines) else { return nil }
        let (rest, _) = splitComment(valueAfterKey(lines[keyIndex]))
        if rest.hasPrefix("["), rest.hasSuffix("]") {
            let items = splitFlowSequence(String(rest.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces))
            return items.first { flowGroupName($0) == name }.flatMap(flowMapping).map { groupFields(from: $0).group }
        }
        guard rest.isEmpty else { return nil }
        let end = sectionEnd(after: keyIndex, in: lines)
        guard let block = parseGroupBlocks(in: lines, range: (keyIndex + 1)..<end).first(where: { $0.name == name }) else { return nil }
        return parseGroupBody(lines[block.removeStart..<block.contentEnd], dashIndent: block.dashIndent)?.group
    }

    /// 读取配置文件中的策略组摘要列表，用于重启内核前在 UI 中同步最新策略组状态
    static func groupSummaries(in yaml: String) -> [GroupSummary] {
        let lines = readableLines(yaml)
        guard let keyIndex = topLevelKeyIndex("proxy-groups", in: lines) else { return [] }
        let (rest, _) = splitComment(valueAfterKey(lines[keyIndex]))
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
        var (lines, newline) = try editableLines(yaml)
        guard let keyIndex = topLevelKeyIndex("proxy-groups", in: lines) else { throw OverlayError.groupNotFound(name) }
        let (rest, _) = splitComment(valueAfterKey(lines[keyIndex]))

        if rest.hasPrefix("["), rest.hasSuffix("]"), let range = lines[keyIndex].range(of: rest) {
            var items = splitFlowSequence(String(rest.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces))
            guard let idx = items.firstIndex(where: { flowGroupName($0) == name }) else { throw OverlayError.groupNotFound(name) }
            guard let mapping = flowMapping(items[idx]) else { throw OverlayError.unsupportedGroup(name) }
            items[idx] = group.flowYAML(keeping: groupFields(from: mapping).extras)
            lines[keyIndex].replaceSubrange(range, with: "[\(items.joined(separator: ", "))]")
            return lines.joined(separator: newline)
        } else if !rest.isEmpty {
            throw OverlayError.flowStyle("proxy-groups")
        }

        let end = sectionEnd(after: keyIndex, in: lines)
        if sectionStartsWithFlow(lines, range: (keyIndex + 1)..<end) { throw OverlayError.flowStyle("proxy-groups") }
        guard let block = parseGroupBlocks(in: lines, range: (keyIndex + 1)..<end).first(where: { $0.name == name }) else {
            throw OverlayError.groupNotFound(name)
        }
        guard let parsed = parseGroupBody(lines[block.removeStart..<block.contentEnd], dashIndent: block.dashIndent) else {
            throw OverlayError.unsupportedGroup(name)
        }
        let pad = block.dashIndent + "  "
        var replacement = group.yamlLines(indent: block.dashIndent, proxyComments: parsed.proxyComments)
        // 表单字段之间的整行注释保留在名称之后，避免编辑时丢失
        replacement.insert(contentsOf: parsed.comments.map { pad + $0 }, at: 1)
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
        let lines = readableLines(yaml)
        guard let keyIndex = topLevelKeyIndex("rules", in: lines) else { return nil }
        let (rest, _) = splitComment(valueAfterKey(lines[keyIndex]))
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
        let lines = readableLines(yaml)
        guard let keyIndex = topLevelKeyIndex("rules", in: lines) else { return [] }
        let (rest, _) = splitComment(valueAfterKey(lines[keyIndex]))
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
        var (lines, newline) = try editableLines(yaml)
        guard let keyIndex = topLevelKeyIndex("rules", in: lines) else {
            throw OverlayError.ruleNotFound
        }
        let rawAfterKey = valueAfterKey(lines[keyIndex])
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
        if sectionStartsWithFlow(lines, range: (keyIndex + 1)..<end) { throw OverlayError.flowStyle("rules") }
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

        let rawAfterKey = valueAfterKey(lines[keyIndex])
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
        if sectionStartsWithFlow(lines, range: (keyIndex + 1)..<end) { throw OverlayError.flowStyle("rules") }
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

        let rawAfterKey = valueAfterKey(lines[keyIndex])
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
        if sectionStartsWithFlow(lines, range: (keyIndex + 1)..<end) { throw OverlayError.flowStyle("proxy-groups") }
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

    /// 顶层键可以带引号（`"rules":`），冒号前允许空格
    private static func topLevelKeyIndex(_ key: String, in lines: [String]) -> Int? {
        lines.firstIndex { line in
            for candidate in [key, "\"\(key)\"", "'\(key)'"] where line.hasPrefix(candidate) {
                if line.dropFirst(candidate.count).drop(while: { $0 == " " }).hasPrefix(":") { return true }
            }
            return false
        }
    }

    /// 顶层键所在行冒号之后的原始文本
    private static func valueAfterKey(_ line: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return "" }
        return String(line[line.index(after: colon)...])
    }

    private static func hasMixedNewlines(_ yaml: String) -> Bool {
        guard yaml.contains("\r\n") else { return false }
        return yaml.replacingOccurrences(of: "\r\n", with: "").contains("\n")
    }

    /// 编辑时换行符必须统一，否则无法原样写回
    private static func editableLines(_ yaml: String) throws -> (lines: [String], newline: String) {
        guard !hasMixedNewlines(yaml) else { throw OverlayError.mixedNewlines }
        let newline = yaml.contains("\r\n") ? "\r\n" : "\n"
        return (yaml.components(separatedBy: newline), newline)
    }

    /// 只读解析时容忍混用的换行符
    private static func readableLines(_ yaml: String) -> [String] {
        hasMixedNewlines(yaml)
            ? yaml.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            : yaml.components(separatedBy: yaml.contains("\r\n") ? "\r\n" : "\n")
    }

    /// `rules:` 下一行才开始的流式写法（`  [A, B]`），块级插入会写出非法 YAML
    private static func sectionStartsWithFlow(_ lines: [String], range: Range<Int>) -> Bool {
        for line in lines[range] {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty || t.hasPrefix("#") { continue }
            return t.hasPrefix("[") || t.hasPrefix("{")
        }
        return false
    }

    static func sectionEnd(after keyIndex: Int, in lines: [String]) -> Int {
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

    private struct ParsedGroupBody {
        var group: CustomGroup
        var extras: [ExtraKey]
        var keyIndent: Int
        /// 表单字段下的整行注释（不含缩进）
        var comments: [String] = []
        /// proxies 成员的注释，键为成员名；空键表示列表末尾的注释
        var proxyComments: [String: CustomGroup.ProxyComment] = [:]
    }

    /// 解析块级策略组条目；单行 `- {...}`（JSON 或 YAML 流式写法）同样支持。
    /// 表单字段使用多行字符串、锚点、别名、标签或合并键时返回 nil，拒绝编辑以免改坏配置。
    private static func parseGroupBody(_ block: ArraySlice<String>, dashIndent: String) -> ParsedGroupBody? {
        guard let first = block.first else { return nil }
        let afterDashRaw = String(first.dropFirst(dashIndent.count).dropFirst())
        let spaces = afterDashRaw.prefix { $0 == " " }.count
        let firstRaw = String(afterDashRaw.dropFirst(spaces)).trimmingCharacters(in: .newlines)
        let (firstContent, _) = splitComment(firstRaw)
        if firstContent.hasPrefix("{") {
            let flow = block.map { splitComment($0.trimmingCharacters(in: .whitespaces)).content }.joined(separator: " ")
            guard let mapping = flowMapping(String(flow.drop { $0 != "{" })) else { return nil }
            let fields = groupFields(from: mapping)
            let extras = fields.extras.sorted { $0.key < $1.key }.map { ExtraKey(head: "\($0.key): \(jsonText($0.value))", children: []) }
            return ParsedGroupBody(group: fields.group, extras: extras, keyIndent: dashIndent.count + 2)
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
        var comments: [String] = []
        var proxyComments: [String: CustomGroup.ProxyComment] = [:]
        for chunk in chunks {
            guard let colon = chunk.content.firstIndex(of: ":") else { return nil }
            let key = unquoteScalar(String(chunk.content[..<colon]))
            let value = String(chunk.content[chunk.content.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if key == "<<" { return nil }
            if managedGroupKeys.contains(key) {
                // 多行字符串（| >）、锚点、别名与标签都无法按单行值安全改写
                if let first = value.first, "|>*&!".contains(first) { return nil }
                let childLines = chunk.children.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                if key != "proxies" {
                    comments += childLines.filter { $0.hasPrefix("#") }
                    if childLines.contains(where: { !$0.isEmpty && !$0.hasPrefix("#") }) { return nil }
                }
            }
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
                } else if value.isEmpty {
                    var pending: [String] = []
                    var items: [String] = []
                    for line in chunk.children {
                        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if t.hasPrefix("#") { pending.append(t); continue }
                        if t.isEmpty { continue }
                        // 成员只能是单行标量，嵌套映射等写法拒绝编辑
                        guard isDashItemLine(t) else { return nil }
                        let (item, comment) = splitComment(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
                        guard let first = item.first, !"{[|>*&!".contains(first) else { return nil }
                        let name = unquoteScalar(item)
                        items.append(name)
                        if !pending.isEmpty || !comment.isEmpty {
                            proxyComments[name] = .init(leading: pending, trailing: comment)
                        }
                        pending = []
                    }
                    if !pending.isEmpty { proxyComments[""] = .init(leading: pending, trailing: "") }
                    group.proxies = items
                } else {
                    return nil
                }
            default:
                extras.append(ExtraKey(head: chunk.raw, children: chunk.children))
            }
        }
        return ParsedGroupBody(group: group, extras: extras, keyIndent: keyIndent,
                               comments: comments, proxyComments: proxyComments)
    }

    private static func jsonMapping(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    /// 单行流式映射：先按 JSON 解析，再按 subconverter 常见的 YAML 流式写法
    /// （`{name: G, type: select, proxies: [A, B]}`）解析；嵌套映射等复杂写法返回 nil
    private static func flowMapping(_ text: String) -> [String: Any]? {
        if let json = jsonMapping(text) { return json }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return nil }
        let inner = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        var result: [String: Any] = [:]
        for pair in inner.isEmpty ? [] : splitFlowSequence(inner) {
            guard let (key, raw) = splitFlowPair(pair), !key.isEmpty, result[key] == nil else { return nil }
            if let first = raw.first, "{|>*&!".contains(first) { return nil }
            if raw.hasPrefix("[") {
                guard raw.hasSuffix("]") else { return nil }
                let seq = String(raw.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                let items = seq.isEmpty ? [] : splitFlowSequence(seq)
                guard !items.contains(where: { $0.hasPrefix("{") || $0.hasPrefix("[") }) else { return nil }
                result[key] = items.map(unquoteScalar)
            } else if raw.first == "'" || raw.first == "\"" {
                result[key] = unquoteScalar(raw)
            } else if ["true", "false"].contains(raw.lowercased()) {
                result[key] = raw.lowercased() == "true"
            } else if let n = Int(raw) {
                result[key] = NSNumber(value: n)
            } else {
                result[key] = raw
            }
        }
        return result
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

    static func isDashItemLine(_ trimmed: String) -> Bool {
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

    /// 复合规则在 YAML（`((DOMAIN,a.com),(DST-PORT,443))`）和内核（`((Domain,a.com) && (DstPort,443))`）
    /// 中写法不同；拆成叶子记号并统一类型名后再比较
    static func compoundTokens(_ payload: String) -> [String] {
        payload.components(separatedBy: CharacterSet(charactersIn: "(),&| \t"))
            .filter { !$0.isEmpty }
            .map { normalizeType(apiRuleType($0)) }
    }

    private static func selectRuleMatch<ID>(target: RuleTarget, entries: [(ID, ParsedRule?)]) -> ID? {
        let targetType = normalizeType(target.type)
        let compoundTypes: Set<String> = ["and", "or", "not", "subrule"]
        let isCompound = compoundTypes.contains(targetType)
        let targetTokens = isCompound ? compoundTokens(target.payload) : []

        func matches(_ parsed: ParsedRule, compoundByTokens: Bool) -> Bool {
            guard parsed.normalizedType == targetType, parsed.proxy == target.proxy else { return false }
            if compoundByTokens && isCompound { return compoundTokens(parsed.payload) == targetTokens }
            return parsed.payload.lowercased() == target.payload.lowercased()
        }

        if let index = target.index, entries.indices.contains(index), let parsed = entries[index].1,
           matches(parsed, compoundByTokens: true) || matches(parsed, compoundByTokens: false) {
            return entries[index].0
        }

        // 先尝试 payload 大小写完全一致，再退回不区分大小写匹配
        if let exact = entries.first(where: { entry in
            guard let p = entry.1 else { return false }
            return p.normalizedType == targetType && p.proxy == target.proxy && p.payload == target.payload
        }) {
            return exact.0
        }
        if let found = entries.first(where: { entry in
            guard let p = entry.1 else { return false }
            return matches(p, compoundByTokens: false)
        }) {
            return found.0
        }
        guard isCompound else { return nil }
        if let found = entries.first(where: { entry in entry.1.map { matches($0, compoundByTokens: true) } ?? false }) {
            return found.0
        }
        // 记号也对不上（如 SUB-RULE 等特殊写法）时，只有同类型同策略的复合规则唯一才按序号接受
        let sameKind = entries.filter { $0.1?.normalizedType == targetType && $0.1?.proxy == target.proxy }
        guard sameKind.count == 1, let index = target.index, entries.indices.contains(index),
              entries[index].1?.normalizedType == targetType, entries[index].1?.proxy == target.proxy else { return nil }
        return entries[index].0
    }

    private static func normalizeType(_ type: String) -> String {
        type.lowercased().replacingOccurrences(of: "-", with: "")
    }
}
