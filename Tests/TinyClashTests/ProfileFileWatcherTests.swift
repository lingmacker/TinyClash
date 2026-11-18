import Foundation
import Testing
@testable import TinyClash

@Suite
struct ProfileFileWatcherTests {
    private actor Counter {
        var count = 0
        func increment() { count += 1 }
    }

    private func waitUntil(timeoutSeconds: Double = 2.0, _ condition: @escaping () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return await condition()
    }

    @Test func detectsInPlaceWriteAndAtomicReplacement() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appendingPathComponent("config.yaml")
        try Data("port: 7890\n".utf8).write(to: target)

        let counter = Counter()
        let watcher = ProfileFileWatcher(debounceMilliseconds: 60) {
            Task { await counter.increment() }
        }
        defer { watcher.stop() }
        watcher.watch(file: target)
        try await Task.sleep(nanoseconds: 50_000_000)

        // In-place modification
        let handle = try FileHandle(forWritingTo: target)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("# edit 1\n".utf8))
        try handle.close()

        let sawFirst = await waitUntil { await counter.count >= 1 }
        #expect(sawFirst)
        let afterFirst = await counter.count

        // Atomic replacement (new inode, like VS Code / TextEdit / Swift atomic write)
        try Data("port: 7891\n".utf8).write(to: target, options: .atomic)
        let sawSecond = await waitUntil { await counter.count > afterFirst }
        #expect(sawSecond)
        let afterSecond = await counter.count

        // Subsequent in-place write must still fire after inode replacement
        let handle2 = try FileHandle(forWritingTo: target)
        try handle2.seekToEnd()
        try handle2.write(contentsOf: Data("# edit 3\n".utf8))
        try handle2.close()

        let sawThird = await waitUntil { await counter.count > afterSecond }
        #expect(sawThird)
    }
}
