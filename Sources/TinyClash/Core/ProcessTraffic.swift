import Foundation

struct ProcessTrafficItem: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var processPath: String?
    var downloadSpeed: Int64
    var uploadSpeed: Int64
    var connectionCount: Int

    var totalSpeed: Int64 { downloadSpeed + uploadSpeed }
}

/// 根据 `/connections` 每秒快照计算各进程实时网速，并保留占用最高的前 N 个进程。
struct ProcessTrafficTracker {
    private struct ConnectionSample {
        var upload: Int64
        var download: Int64
    }

    private struct Accumulator {
        var downloadBytes: Int64 = 0
        var uploadBytes: Int64 = 0
        var connectionCount: Int = 0
        var processPath: String?
    }

    private var previousSamples: [String: ConnectionSample] = [:]
    private var previousTimestamp: Date?
    private(set) var topProcesses: [ProcessTrafficItem] = []

    static func processName(for metadata: Connection.Metadata) -> String {
        if let process = metadata.process?.trimmingCharacters(in: .whitespacesAndNewlines), !process.isEmpty {
            return process
        }
        if let path = metadata.processPath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            let last = (path as NSString).lastPathComponent
            if !last.isEmpty { return last }
        }
        return "未知进程"
    }

    mutating func ingest(_ connections: [Connection], at now: Date = Date(), limit: Int = 4) {
        let maxCount = max(0, limit)
        var currentSamples: [String: ConnectionSample] = [:]
        currentSamples.reserveCapacity(connections.count)
        for conn in connections {
            currentSamples[conn.id] = ConnectionSample(upload: conn.upload, download: conn.download)
        }

        guard let prevTime = previousTimestamp else {
            previousSamples = currentSamples
            previousTimestamp = now
            topProcesses = []
            return
        }

        let dt = now.timeIntervalSince(prevTime)
        guard dt > 0, dt <= 10.0 else {
            previousSamples = currentSamples
            previousTimestamp = now
            topProcesses = []
            return
        }

        let effectiveDt = max(dt, 0.25)
        var byProcess: [String: Accumulator] = [:]

        for conn in connections {
            let deltaUp: Int64
            let deltaDown: Int64
            if let prev = previousSamples[conn.id] {
                deltaUp = max(0, conn.upload - prev.upload)
                deltaDown = max(0, conn.download - prev.download)
            } else if let startDate = conn.startDate, prevTime.timeIntervalSince(startDate) > 2.0 {
                // 断流重连等场景下出现的旧连接，避免把历史累计流量误算为当前 1 秒网速
                deltaUp = 0
                deltaDown = 0
            } else {
                deltaUp = max(0, conn.upload)
                deltaDown = max(0, conn.download)
            }

            let name = Self.processName(for: conn.metadata)
            var acc = byProcess[name] ?? Accumulator()
            acc.downloadBytes += deltaDown
            acc.uploadBytes += deltaUp
            acc.connectionCount += 1
            if acc.processPath == nil,
               let path = conn.metadata.processPath?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                acc.processPath = path
            }
            byProcess[name] = acc
        }

        var items: [ProcessTrafficItem] = []
        items.reserveCapacity(byProcess.count)
        for (name, acc) in byProcess {
            let downSpeed = Int64((Double(acc.downloadBytes) / effectiveDt).rounded())
            let upSpeed = Int64((Double(acc.uploadBytes) / effectiveDt).rounded())
            guard downSpeed + upSpeed > 0 else { continue }
            items.append(ProcessTrafficItem(
                name: name,
                processPath: acc.processPath,
                downloadSpeed: downSpeed,
                uploadSpeed: upSpeed,
                connectionCount: acc.connectionCount
            ))
        }

        items.sort { lhs, rhs in
            if lhs.totalSpeed != rhs.totalSpeed { return lhs.totalSpeed > rhs.totalSpeed }
            if lhs.downloadSpeed != rhs.downloadSpeed { return lhs.downloadSpeed > rhs.downloadSpeed }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        previousSamples = currentSamples
        previousTimestamp = now
        topProcesses = Array(items.prefix(maxCount))
    }

    mutating func reset() {
        previousSamples = [:]
        previousTimestamp = nil
        topProcesses = []
    }
}
