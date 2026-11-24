import AppKit
import Foundation

@MainActor
final class ProcessIconCache {
    static let shared = ProcessIconCache()

    private enum CachedIcon {
        case image(NSImage)
        case missing
    }

    private var cache: [String: CachedIcon] = [:]

    func icon(forName name: String, path: String?) -> NSImage? {
        let key = (path?.isEmpty == false ? path! : name).lowercased()
        if let cached = cache[key] {
            switch cached {
            case .image(let img): return img
            case .missing: return nil
            }
        }
        if cache.count >= 200 { cache.removeAll(keepingCapacity: true) }

        if let resolved = resolveIcon(name: name, path: path) {
            cache[key] = .image(resolved)
            return resolved
        }
        cache[key] = .missing
        return nil
    }

    private func resolveIcon(name: String, path: String?) -> NSImage? {
        if let path, let bundlePath = Self.appBundlePath(from: path),
           FileManager.default.fileExists(atPath: bundlePath) {
            return NSWorkspace.shared.icon(forFile: bundlePath)
        }
        guard name != "未知进程" else { return nil }
        let target = name.lowercased()
        for app in NSWorkspace.shared.runningApplications {
            if app.localizedName?.lowercased() == target ||
               app.executableURL?.lastPathComponent.lowercased() == target {
                if let icon = app.icon { return icon }
            }
        }
        return nil
    }

    /// 从进程路径中提取最外层 `.app` 包路径（例如 Helper 进程归属到宿主应用图标）。
    nonisolated static func appBundlePath(from processPath: String) -> String? {
        let trimmed = processPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let components = (trimmed as NSString).pathComponents
        guard let idx = components.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else {
            return nil
        }
        return NSString.path(withComponents: Array(components[...idx]))
    }

    nonisolated static func fallbackSymbol(forName name: String, path: String?) -> String {
        if name == "未知进程" { return "network" }
        if let path {
            let lowerPath = path.lowercased()
            if lowerPath.hasPrefix("/usr/") || lowerPath.hasPrefix("/bin/") ||
               lowerPath.hasPrefix("/sbin/") || lowerPath.hasPrefix("/opt/") {
                return "terminal"
            }
        }
        let lower = name.lowercased()
        let cliNames: Set<String> = [
            "ssh", "scp", "sftp", "curl", "wget", "git", "node", "npm", "pnpm", "yarn",
            "python", "python3", "ruby", "go", "cargo", "rustc", "swift", "brew", "rsync",
            "nc", "aria2c", "ffmpeg", "yt-dlp", "docker", "kubectl", "gh", "claude", "codex",
        ]
        if cliNames.contains(lower) || lower.hasPrefix("python") {
            return "terminal"
        }
        return "app"
    }
}
