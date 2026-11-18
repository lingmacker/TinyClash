import CryptoKit
import Foundation

struct ProxyProviderDefinition: Equatable {
    var name: String
    var type: String
    var url: String
    var path: String
    var payload: [ProxyItem] = []

    /// Mirrors mihomo: explicit `path` resolves against `home`; HTTP providers without
    /// a `path` cache under `proxies/<md5(url)>`.
    func fileURL(home: URL = AppPaths.home) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed.hasPrefix("/") ? URL(fileURLWithPath: trimmed) : home.appendingPathComponent(trimmed)
        }
        guard type.lowercased() == "http", !url.isEmpty else { return nil }
        let hash = Insecure.MD5.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
        return home.appendingPathComponent("proxies", isDirectory: true).appendingPathComponent(hash)
    }
}

struct NodeSection: Identifiable {
    enum Source: Equatable {
        case provider(name: String, vehicleType: String, updatedAt: String?)
        case profile(name: String, kind: Profile.Kind)
    }

    var id: String
    var profileID: UUID
    var profileName: String
    var source: Source
    var nodes: [ProxyItem]
    var isActiveProfile: Bool
    var isLive: Bool
    var offlineHint: String?

    var title: String {
        switch source {
        case .provider(let name, _, _): return name
        case .profile(let name, _): return name
        }
    }

    var providerName: String? {
        if case .provider(let name, _, _) = source { return name }
        return nil
    }
}

enum ProfileNodes {
    static let builtinProxyTypes: Set<String> = [
        "Direct", "Reject", "RejectDrop", "Pass", "PassRule", "Compatible", "Dns", "Rematch",
    ]

    static func orderedProfiles(_ profiles: [Profile], selectedProfileID: UUID?) -> [Profile] {
        guard let selectedProfileID,
              let idx = profiles.firstIndex(where: { $0.id == selectedProfileID }) else {
            return profiles
        }
        var result = [profiles[idx]]
        for (offset, profile) in profiles.enumerated() where offset != idx {
            result.append(profile)
        }
        return result
    }

    static func liveSections(for profile: Profile, providers: [ProviderItem], proxies: [String: ProxyItem]) -> [NodeSection] {
        var sections: [NodeSection] = providers.map { provider in
            NodeSection(
                id: "\(profile.id.uuidString):provider:\(provider.name)",
                profileID: profile.id,
                profileName: profile.name,
                source: .provider(name: provider.name, vehicleType: provider.vehicleType, updatedAt: provider.updatedAt),
                nodes: provider.proxies ?? [],
                isActiveProfile: true,
                isLive: true,
                offlineHint: nil
            )
        }

        let providerNodeNames = Set(providers.flatMap { ($0.proxies ?? []).map(\.name) })
        let isInlineNode: (ProxyItem) -> Bool = { item in
            !item.isGroup && !builtinProxyTypes.contains(item.type) && !providerNodeNames.contains(item.name)
        }

        var inlineNodes: [ProxyItem] = []
        var seen = Set<String>()
        for name in proxies["GLOBAL"]?.all ?? [] {
            if let item = proxies[name], isInlineNode(item), seen.insert(item.name).inserted {
                inlineNodes.append(item)
            }
        }
        let rest = proxies.values.filter { isInlineNode($0) && !seen.contains($0.name) }
            .sorted { $0.name < $1.name }
        inlineNodes.append(contentsOf: rest)

        if !inlineNodes.isEmpty {
            sections.append(NodeSection(
                id: "\(profile.id.uuidString):profile",
                profileID: profile.id,
                profileName: profile.name,
                source: .profile(name: profile.name, kind: profile.kind),
                nodes: inlineNodes,
                isActiveProfile: true,
                isLive: true,
                offlineHint: nil
            ))
        }
        return sections
    }

    static func resolveProviderSubscriptions(
        yamlProviders: [ProxyProviderDefinition],
        runtimeProviders: [ProviderItem],
        cached: [ProviderSubscription]
    ) -> (subscriptions: [ProviderSubscription], missingHTTP: [ProxyProviderDefinition]) {
        var byName: [String: SubscriptionInfo] = [:]
        var byURL: [String: SubscriptionInfo] = [:]
        let urlByName = Dictionary(yamlProviders.map { ($0.name, $0.url) }, uniquingKeysWith: { first, _ in first })

        for item in cached {
            byName[item.name] = item.subscription
        }
        for provider in runtimeProviders {
            guard let info = SubscriptionInfo(dto: provider.subscriptionInfo) else { continue }
            byName[provider.name] = info
            if let url = urlByName[provider.name], !url.isEmpty {
                byURL[url] = info
            }
        }
        for def in yamlProviders where !def.url.isEmpty && byURL[def.url] == nil {
            if let info = byName[def.name] {
                byURL[def.url] = info
            }
        }

        if yamlProviders.isEmpty {
            let runtimeOnly = runtimeProviders.compactMap { provider -> ProviderSubscription? in
                guard let info = SubscriptionInfo(dto: provider.subscriptionInfo) else { return nil }
                return ProviderSubscription(name: provider.name, subscription: info)
            }
            return (runtimeOnly, [])
        }

        var subscriptions: [ProviderSubscription] = []
        var missingHTTP: [ProxyProviderDefinition] = []
        for def in yamlProviders {
            if let info = byName[def.name] {
                subscriptions.append(ProviderSubscription(name: def.name, subscription: info))
            } else if !def.url.isEmpty, let info = byURL[def.url] {
                subscriptions.append(ProviderSubscription(name: def.name, subscription: info))
            } else if def.type == "http", !def.url.isEmpty {
                missingHTTP.append(def)
            }
        }
        return (subscriptions, missingHTTP)
    }

    static func pendingOfflineProviders(for profile: Profile,
                                        loadedProviderNames: Set<String>,
                                        fileURL: URL? = nil,
                                        home: URL = AppPaths.home) -> [NodeSection] {
        offlineSections(for: profile, isActiveProfile: true, fileURL: fileURL, home: home).compactMap { section in
            guard case .provider(let name, _, _) = section.source,
                  !loadedProviderNames.contains(name) else { return nil }
            var copy = section
            if copy.nodes.isEmpty {
                copy.offlineHint = "内核尚未加载此 Provider，请在配置菜单点击「重新加载」或重启内核"
            }
            return copy
        }
    }

    static func offlineSections(for profile: Profile,
                                isActiveProfile: Bool,
                                fileURL: URL? = nil,
                                home: URL = AppPaths.home) -> [NodeSection] {
        guard let data = try? Data(contentsOf: fileURL ?? profile.fileURL) else { return [] }
        let yaml = String(decoding: data, as: UTF8.self)
        var sections: [NodeSection] = []

        for provider in ConfigOverlay.proxyProviders(in: yaml) {
            let vehicleType: String
            switch provider.type.lowercased() {
            case "http": vehicleType = "HTTP"
            case "file": vehicleType = "File"
            case "inline": vehicleType = "Inline"
            default: vehicleType = provider.type.isEmpty ? "HTTP" : provider.type
            }

            var nodes: [ProxyItem] = []
            var hint: String?
            if provider.type.lowercased() == "inline" {
                nodes = provider.payload
            } else if let url = provider.fileURL(home: home),
                      let fileData = try? Data(contentsOf: url) {
                nodes = ConfigOverlay.proxyItems(in: String(decoding: fileData, as: UTF8.self))
            } else {
                hint = isActiveProfile
                    ? "内核未运行，尚未下载本地缓存；启动内核后可查看"
                    : "未找到本地缓存；启用并启动内核后可查看"
            }

            sections.append(NodeSection(
                id: "\(profile.id.uuidString):provider:\(provider.name)",
                profileID: profile.id,
                profileName: profile.name,
                source: .provider(name: provider.name, vehicleType: vehicleType, updatedAt: nil),
                nodes: nodes,
                isActiveProfile: isActiveProfile,
                isLive: false,
                offlineHint: hint
            ))
        }

        let inlineNodes = ConfigOverlay.proxyItems(in: yaml)
        if !inlineNodes.isEmpty {
            sections.append(NodeSection(
                id: "\(profile.id.uuidString):profile",
                profileID: profile.id,
                profileName: profile.name,
                source: .profile(name: profile.name, kind: profile.kind),
                nodes: inlineNodes,
                isActiveProfile: isActiveProfile,
                isLive: false,
                offlineHint: nil
            ))
        }
        return sections
    }
}

extension ConfigOverlay {
    static func proxyItems(in yaml: String) -> [ProxyItem] {
        let lines = readableLines(yaml)
        guard let keyIndex = topLevelKeyIndex("proxies", in: lines) else { return [] }
        let (rest, _) = splitComment(valueAfterKey(lines[keyIndex]))
        if rest.hasPrefix("["), rest.hasSuffix("]") {
            let inner = String(rest.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            return inner.isEmpty ? [] : splitFlowSequence(inner).compactMap(flowProxyItem)
        }
        guard rest.isEmpty else { return [] }
        let end = sectionEnd(after: keyIndex, in: lines)
        return parseProxySequence(in: lines, range: (keyIndex + 1)..<end)
    }

    static func proxyProviders(in yaml: String) -> [ProxyProviderDefinition] {
        let lines = readableLines(yaml)
        guard let keyIndex = topLevelKeyIndex("proxy-providers", in: lines) else { return [] }
        let (rest, _) = splitComment(valueAfterKey(lines[keyIndex]))
        guard rest.isEmpty else { return [] }
        let end = sectionEnd(after: keyIndex, in: lines)

        var providerIndent: Int?
        var starts: [Int] = []
        for i in (keyIndex + 1)..<end {
            let trimmed = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = lines[i].prefix { $0 == " " }.count
            if let expected = providerIndent {
                if indent == expected && !isDashItemLine(trimmed) {
                    starts.append(i)
                }
            } else if indent > 0 && !isDashItemLine(trimmed) {
                providerIndent = indent
                starts.append(i)
            } else {
                break
            }
        }
        guard let providerIndent else { return [] }

        return starts.enumerated().compactMap { idx, start in
            let nextStart = idx + 1 < starts.count ? starts[idx + 1] : end
            let head = splitComment(lines[start].trimmingCharacters(in: .whitespaces)).content
            guard let colon = head.firstIndex(of: ":") else { return nil }
            let name = unquoteScalar(String(head[..<colon]))
            let headVal = String(head[head.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, headVal.isEmpty else { return nil }

            var fieldIndent: Int?
            var fieldStarts: [Int] = []
            for i in (start + 1)..<nextStart {
                let trimmed = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                let indent = lines[i].prefix { $0 == " " }.count
                guard indent > providerIndent else { break }
                if fieldIndent == nil { fieldIndent = indent }
                if indent == fieldIndent && !isDashItemLine(trimmed) {
                    fieldStarts.append(i)
                }
            }

            var def = ProxyProviderDefinition(name: name, type: "http", url: "", path: "")
            for (fIdx, fStart) in fieldStarts.enumerated() {
                let fEnd = fIdx + 1 < fieldStarts.count ? fieldStarts[fIdx + 1] : nextStart
                let content = splitComment(lines[fStart].trimmingCharacters(in: .whitespaces)).content
                guard let fColon = content.firstIndex(of: ":") else { continue }
                let key = unquoteScalar(String(content[..<fColon]))
                let val = String(content[content.index(after: fColon)...]).trimmingCharacters(in: .whitespaces)
                switch key {
                case "type": def.type = unquoteScalar(val).lowercased()
                case "url": def.url = unquoteScalar(val)
                case "path": def.path = unquoteScalar(val)
                case "payload":
                    if val.hasPrefix("["), val.hasSuffix("]") {
                        let inner = String(val.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                        def.payload = inner.isEmpty ? [] : splitFlowSequence(inner).compactMap(flowProxyItem)
                    } else if val.isEmpty {
                        def.payload = parseProxySequence(in: lines, range: (fStart + 1)..<fEnd)
                    }
                default: break
                }
            }
            return def
        }
    }

    private static func parseProxySequence(in lines: [String], range: Range<Int>) -> [ProxyItem] {
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

        return starts.enumerated().compactMap { idx, start in
            let nextStart = idx + 1 < starts.count ? starts[idx + 1] : range.upperBound
            var contentEnd = nextStart
            while contentEnd > start + 1 {
                let t = lines[contentEnd - 1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard t.isEmpty || t.hasPrefix("#") else { break }
                contentEnd -= 1
            }
            return parseProxyItem(lines[start..<contentEnd], dashIndent: dashIndent)
        }
    }

    private static func parseProxyItem(_ block: ArraySlice<String>, dashIndent: String) -> ProxyItem? {
        guard let first = block.first else { return nil }
        let afterDashRaw = String(first.dropFirst(dashIndent.count).dropFirst())
        let spaces = afterDashRaw.prefix { $0 == " " }.count
        let firstRaw = String(afterDashRaw.dropFirst(spaces)).trimmingCharacters(in: .newlines)
        let (firstContent, _) = splitComment(firstRaw)
        if firstContent.hasPrefix("{") {
            let flow = block.map { splitComment($0.trimmingCharacters(in: .whitespaces)).content }.joined(separator: " ")
            return flowProxyItem(String(flow.drop { $0 != "{" }))
        }

        var keyIndent: Int?
        var linesToParse: [String] = []
        if !firstContent.isEmpty {
            keyIndent = dashIndent.count + 1 + spaces
            linesToParse.append(firstContent)
        }
        for line in block.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix { $0 == " " }.count
            if keyIndent == nil { keyIndent = indent }
            if let keyIndent, indent == keyIndent, !isDashItemLine(trimmed) {
                linesToParse.append(splitComment(trimmed).content)
            }
        }

        var name = ""
        var type = ""
        var udp: Bool?
        for content in linesToParse {
            guard let colon = content.firstIndex(of: ":") else { continue }
            let key = unquoteScalar(String(content[..<colon]))
            let val = String(content[content.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "name": name = unquoteScalar(val)
            case "type": type = unquoteScalar(val)
            case "udp": udp = unquoteScalar(val).lowercased() == "true"
            default: break
            }
        }
        guard !name.isEmpty else { return nil }
        return ProxyItem(name: name, type: type.isEmpty ? "Proxy" : type, udp: udp)
    }

    private static func flowProxyItem(_ mapping: String) -> ProxyItem? {
        let trimmed = mapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return nil }
        let inner = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        var name = ""
        var type = ""
        var udp: Bool?
        for pair in inner.isEmpty ? [] : splitFlowSequence(inner) {
            guard let (key, raw) = splitFlowPair(pair) else { continue }
            switch key {
            case "name": name = unquoteScalar(raw)
            case "type": type = unquoteScalar(raw)
            case "udp": udp = unquoteScalar(raw).lowercased() == "true"
            default: break
            }
        }
        guard !name.isEmpty else { return nil }
        return ProxyItem(name: name, type: type.isEmpty ? "Proxy" : type, udp: udp)
    }
}
