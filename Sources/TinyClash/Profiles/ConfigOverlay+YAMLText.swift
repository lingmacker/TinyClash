import Foundation

/// YAML 文本工具：流式序列拆分、注释、标量引号与换行符处理
extension ConfigOverlay {
    // MARK: - Flow & Scalar Helpers

    static func splitFlowSequence(_ inner: String) -> [String] {
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

    static func flowGroupName(_ mapping: String) -> String? {
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

    static func splitComment(_ s: String) -> (content: String, comment: String) {
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

    private static func singleQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    /// 以 JSON/YAML 双引号字符串输出（用于流式数组或包含控制字符的标量）
    static func quote(_ rule: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: rule, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}
