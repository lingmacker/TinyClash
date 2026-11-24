import Foundation
import XCTest
@testable import TinyClash

final class ProcessTrafficTests: XCTestCase {
    private let baseTime = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeConnection(
        id: String,
        process: String? = "Chrome",
        processPath: String? = nil,
        upload: Int64 = 0,
        download: Int64 = 0,
        startedAt: Date? = nil
    ) -> Connection {
        let start = ISO8601DateFormatter.mihomo.string(from: startedAt ?? baseTime)
        return Connection(
            id: id,
            metadata: .init(
                network: "tcp",
                type: "HTTP",
                sourceIP: "127.0.0.1",
                destinationIP: "93.184.216.34",
                destinationPort: "443",
                host: "example.com",
                process: process,
                sniffHost: nil,
                processPath: processPath
            ),
            upload: upload,
            download: download,
            start: start,
            chains: ["Proxy"],
            rule: "MATCH",
            rulePayload: ""
        )
    }

    func testFirstSnapshotEstablishesBaselineWithoutSpiking() {
        var tracker = ProcessTrafficTracker()
        let c1 = makeConnection(id: "c1", process: "Chrome", upload: 5_000_000, download: 50_000_000)
        tracker.ingest([c1], at: baseTime)
        XCTAssertTrue(tracker.topProcesses.isEmpty)
    }

    func testAggregatesMultipleConnectionsAndReturnsTopFourByTotalSpeed() {
        var tracker = ProcessTrafficTracker()
        tracker.ingest([
            makeConnection(id: "c1", process: "Chrome", processPath: "/Applications/Chrome.app/Contents/MacOS/Chrome", upload: 100, download: 1000),
            makeConnection(id: "c2", process: "Chrome", upload: 200, download: 2000),
            makeConnection(id: "c3", process: "curl", upload: 0, download: 500),
            makeConnection(id: "c4", process: "WeChat", upload: 100, download: 100),
            makeConnection(id: "c5", process: "Safari", upload: 10, download: 10),
            makeConnection(id: "c6", process: "Mail", upload: 5, download: 5),
            makeConnection(id: "c7", process: "IdleApp", upload: 999, download: 999),
        ], at: baseTime)

        tracker.ingest([
            makeConnection(id: "c1", process: "Chrome", processPath: "/Applications/Chrome.app/Contents/MacOS/Chrome", upload: 300, download: 3000), // +200 up, +2000 down
            makeConnection(id: "c2", process: "Chrome", upload: 500, download: 3000), // +300 up, +1000 down -> Chrome total: +500 up, +3000 down = 3500
            makeConnection(id: "c3", process: "curl", upload: 4000, download: 1500),  // +4000 up, +1000 down = 5000
            makeConnection(id: "c4", process: "WeChat", upload: 100, download: 1100), // +0 up, +1000 down = 1000
            makeConnection(id: "c5", process: "Safari", upload: 110, download: 210),  // +100 up, +200 down = 300 (4th -> included)
            makeConnection(id: "c6", process: "Mail", upload: 55, download: 55),      // +50 up, +50 down = 100 (5th -> excluded)
            makeConnection(id: "c7", process: "IdleApp", upload: 999, download: 999), // 0 delta -> excluded
        ], at: baseTime.addingTimeInterval(1.0))

        XCTAssertEqual(tracker.topProcesses, [
            ProcessTrafficItem(name: "curl", processPath: nil, downloadSpeed: 1000, uploadSpeed: 4000, connectionCount: 1),
            ProcessTrafficItem(name: "Chrome", processPath: "/Applications/Chrome.app/Contents/MacOS/Chrome", downloadSpeed: 3000, uploadSpeed: 500, connectionCount: 2),
            ProcessTrafficItem(name: "WeChat", processPath: nil, downloadSpeed: 1000, uploadSpeed: 0, connectionCount: 1),
            ProcessTrafficItem(name: "Safari", processPath: nil, downloadSpeed: 200, uploadSpeed: 100, connectionCount: 1),
        ])
    }

    func testCountsNewlyOpenedConnectionsButIgnoresStaleUnseenConnections() {
        var tracker = ProcessTrafficTracker()
        tracker.ingest([], at: baseTime)

        let fresh = makeConnection(
            id: "fresh",
            process: "git",
            upload: 500,
            download: 2500,
            startedAt: baseTime.addingTimeInterval(0.3)
        )
        let stale = makeConnection(
            id: "stale",
            process: "OldDaemon",
            upload: 100_000,
            download: 900_000,
            startedAt: baseTime.addingTimeInterval(-60)
        )

        tracker.ingest([fresh, stale], at: baseTime.addingTimeInterval(1.0))
        XCTAssertEqual(tracker.topProcesses, [
            ProcessTrafficItem(name: "git", processPath: nil, downloadSpeed: 2500, uploadSpeed: 500, connectionCount: 1),
        ])
    }

    func testProcessNameFallbacksToPathBasenameAndUnknown() {
        var tracker = ProcessTrafficTracker()
        tracker.ingest([
            makeConnection(id: "p1", process: "", processPath: "/usr/local/bin/aria2c", upload: 0, download: 0),
            makeConnection(id: "p2", process: nil, processPath: nil, upload: 0, download: 0),
        ], at: baseTime)

        tracker.ingest([
            makeConnection(id: "p1", process: "", processPath: "/usr/local/bin/aria2c", upload: 0, download: 2048),
            makeConnection(id: "p2", process: nil, processPath: nil, upload: 512, download: 512),
        ], at: baseTime.addingTimeInterval(1.0))

        XCTAssertEqual(tracker.topProcesses.map(\.name), ["aria2c", "未知进程"])
    }

    func testLargeTimeGapResetsBaselineInsteadOfDistortingSpeed() {
        var tracker = ProcessTrafficTracker()
        tracker.ingest([makeConnection(id: "c1", process: "Chrome", upload: 0, download: 1000)], at: baseTime)
        tracker.ingest([makeConnection(id: "c1", process: "Chrome", upload: 0, download: 5000)], at: baseTime.addingTimeInterval(1.0))
        XCTAssertEqual(tracker.topProcesses.first?.downloadSpeed, 4000)

        // 超过 10 秒断档视为重新建立基线
        tracker.ingest([makeConnection(id: "c1", process: "Chrome", upload: 0, download: 9000)], at: baseTime.addingTimeInterval(30.0))
        XCTAssertTrue(tracker.topProcesses.isEmpty)
    }

    func testResetClearsStateAndTopProcesses() {
        var tracker = ProcessTrafficTracker()
        tracker.ingest([makeConnection(id: "c1", process: "Chrome", upload: 0, download: 100)], at: baseTime)
        tracker.ingest([makeConnection(id: "c1", process: "Chrome", upload: 0, download: 1100)], at: baseTime.addingTimeInterval(1.0))
        XCTAssertEqual(tracker.topProcesses.count, 1)

        tracker.reset()
        XCTAssertTrue(tracker.topProcesses.isEmpty)
    }

    func testAppBundlePathExtractsOuterAppAndFallbackSymbolsMatchProcessKind() {
        XCTAssertEqual(
            ProcessIconCache.appBundlePath(
                from: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
            ),
            "/Applications/Google Chrome.app"
        )
        XCTAssertNil(ProcessIconCache.appBundlePath(from: "/usr/bin/ssh"))
        XCTAssertEqual(ProcessIconCache.fallbackSymbol(forName: "未知进程", path: nil), "network")
        XCTAssertEqual(ProcessIconCache.fallbackSymbol(forName: "ssh", path: "/usr/bin/ssh"), "terminal")
        XCTAssertEqual(ProcessIconCache.fallbackSymbol(forName: "CustomDaemon", path: "/Library/CustomDaemon"), "app")
    }
}
