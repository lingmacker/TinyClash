import CryptoKit
import Foundation

/// Entries of a rule provider, read from the same file the core loads. The REST API
/// only exposes counts, so contents come from the inline payload or the provider file.
struct RuleSetContents: Equatable {
    var entries: [String]
    var file: URL?
    var modified: Date?

    enum LoadError: LocalizedError, Equatable {
        case binaryFormat
        case missingFile(String)
        case unreadable(String)
        case unsupportedYAML

        var errorDescription: String? {
            switch self {
            case .binaryFormat: return "mrs 为二进制格式，暂不支持展开查看"
            case .missingFile(let path): return "规则集文件尚未下载或不存在：\(path)"
            case .unreadable(let path): return "无法读取规则集文件：\(path)"
            case .unsupportedYAML: return "规则集文件中未找到 payload 列表"
            }
        }
    }

    static func load(_ definition: RuleProviderDefinition, home: URL = AppPaths.home) throws -> RuleSetContents {
        if definition.type == "inline" { return RuleSetContents(entries: definition.payload) }
        if definition.format == "mrs" { throw LoadError.binaryFormat }
        guard let file = fileURL(for: definition, home: home) else { throw LoadError.missingFile(definition.path) }
        guard FileManager.default.fileExists(atPath: file.path) else { throw LoadError.missingFile(file.path) }
        guard let data = try? Data(contentsOf: file) else { throw LoadError.unreadable(file.path) }
        let text = String(decoding: data, as: UTF8.self)
        let entries = definition.format == "text" ? textEntries(text) : try yamlEntries(text)
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return RuleSetContents(entries: entries, file: file, modified: modified)
    }

    /// Mirrors mihomo: an explicit path resolves against the home directory; an HTTP
    /// provider without one is cached at `rules/<md5(url)>`.
    static func fileURL(for definition: RuleProviderDefinition, home: URL) -> URL? {
        let path = definition.path.trimmingCharacters(in: .whitespaces)
        if !path.isEmpty {
            return path.hasPrefix("/") ? URL(fileURLWithPath: path) : home.appendingPathComponent(path)
        }
        guard definition.type == "http", !definition.url.isEmpty else { return nil }
        let hash = Insecure.MD5.hash(data: Data(definition.url.utf8)).map { String(format: "%02x", $0) }.joined()
        return home.appendingPathComponent("rules", isDirectory: true).appendingPathComponent(hash)
    }

    static func textEntries(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let entry = line.trimmingCharacters(in: .whitespaces)
            return entry.isEmpty || entry.hasPrefix("#") || entry.hasPrefix("//") ? nil : entry
        }
    }

    /// Reads the block-style `payload:` sequence used by rule set files.
    static func yamlEntries(_ text: String) throws -> [String] {
        var entries: [String] = []
        var inPayload = false
        var found = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if !inPayload {
                if raw.first?.isWhitespace == false, line.hasPrefix("payload:") {
                    let rest = stripComment(String(line.dropFirst("payload:".count)))
                    if rest.hasPrefix("[") { return try flowEntries(rest) }
                    inPayload = true
                    found = true
                }
                continue
            }
            if line.hasPrefix("-") {
                let item = scalar(String(line.dropFirst()))
                if !item.isEmpty { entries.append(item) }
            } else if raw.first?.isWhitespace == false {
                break
            }
        }
        guard found else { throw LoadError.unsupportedYAML }
        return entries
    }

    private static func flowEntries(_ text: String) throws -> [String] {
        guard text.hasPrefix("["), text.hasSuffix("]") else { throw LoadError.unsupportedYAML }
        return text.dropFirst().dropLast().split(separator: ",").map { scalar(String($0)) }.filter { !$0.isEmpty }
    }

    private static func scalar(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("'"), let end = text.dropFirst().lastIndex(of: "'") {
            return String(text[text.index(after: text.startIndex)..<end]).replacingOccurrences(of: "''", with: "'")
        }
        if text.hasPrefix("\""), let end = text.dropFirst().lastIndex(of: "\""),
           let value = try? JSONSerialization.jsonObject(with: Data(text[...end].utf8), options: .fragmentsAllowed) as? String {
            return value
        }
        return stripComment(text)
    }

    private static func stripComment(_ text: String) -> String {
        let value = text.range(of: " #").map { String(text[..<$0.lowerBound]) } ?? text
        return value.trimmingCharacters(in: .whitespaces)
    }
}
