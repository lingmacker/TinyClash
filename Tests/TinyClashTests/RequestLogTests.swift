import Foundation
import XCTest
@testable import TinyClash

final class RequestLogTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func connection(_ id: String = "a", age: TimeInterval = 0,
                            chains: [String] = ["香港节点", "自动选择", "流媒体"],
                            host: String = "video.example", upload: Int64 = 10) -> Connection {
        Connection(id: id,
                   metadata: .init(network: "tcp", type: "HTTP", sourceIP: "127.0.0.1",
                                   destinationIP: "203.0.113.8", destinationPort: "443", host: host,
                                   process: "Example Browser", sniffHost: nil),
                   upload: upload, download: 20,
                   start: ISO8601DateFormatter.mihomo.string(from: now.addingTimeInterval(-age)),
                   chains: chains, rule: "RuleSet", rulePayload: "media")
    }

    func testStrategyTabUsesUpdatedLabelWithoutChangingItsIdentifier() {
        XCTAssertEqual(PanelTab.proxies.title, "策略")
        XCTAssertEqual(PanelTab.proxies.rawValue, "proxies")
    }

    func testRouteUsesActualCoreChainInPolicyToNodeOrder() {
        var log = RequestLog()
        log.ingest([connection()], at: now)
        let entry = log.entries[0]
        XCTAssertEqual(entry.route, ["流媒体", "自动选择", "香港节点"])
        XCTAssertEqual(entry.policy, "流媒体")
        XCTAssertEqual(entry.node, "香港节点")
        XCTAssertEqual(entry.matchedRule, "RuleSet (media)")
    }

    func testMissingChainIsExplicitlyUnknownRatherThanInvented() {
        var log = RequestLog()
        log.ingest([connection(chains: [])], at: now)
        XCTAssertEqual(log.entries[0].policy, "未知策略")
        XCTAssertNil(log.entries[0].node)
        XCTAssertTrue(log.entries[0].route.isEmpty)
    }

    func testDirectAndRejectRemainTheirActualPolicies() {
        for name in ["DIRECT", "REJECT", "REJECT-DROP"] {
            var log = RequestLog()
            log.ingest([connection(chains: [name])], at: now)
            XCTAssertEqual(log.entries[0].policy, name)
            XCTAssertEqual(log.entries[0].node, name)
        }
    }

    func testRepeatedSnapshotsUpdateSameRecordWithoutDuplicates() {
        var log = RequestLog()
        log.ingest([connection(upload: 10)], at: now)
        log.ingest([connection(upload: 80)], at: now.addingTimeInterval(1))
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertEqual(log.entries[0].connection.upload, 80)
        XCTAssertEqual(log.entries[0].observedAt, now)
        XCTAssertEqual(log.entries[0].lastSeenAt, now.addingTimeInterval(1))
        XCTAssertTrue(log.entries[0].isActive)
    }

    func testCompletedConnectionsRetainOriginalPolicyAndLastObservedTraffic() {
        var log = RequestLog()
        log.ingest([connection(upload: 80)], at: now)
        log.ingest([], at: now.addingTimeInterval(1))
        log.ingest([], at: now.addingTimeInterval(2))
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertFalse(log.entries[0].isActive)
        XCTAssertEqual(log.entries[0].endedAt, now.addingTimeInterval(1))
        XCTAssertEqual(log.entries[0].lastSeenAt, now)
        XCTAssertEqual(log.entries[0].connection.upload, 80)
        XCTAssertEqual(log.entries[0].route, ["流媒体", "自动选择", "香港节点"])
    }

    func testBoundedHistoryKeepsNewestRequestsNotInputOrder() {
        var log = RequestLog(limit: 2)
        log.ingest([connection("old", age: 100), connection("new"), connection("middle", age: 50)], at: now)
        XCTAssertEqual(log.entries.map(\.id), ["new", "middle"])
    }

    func testEvictedActiveRequestsDoNotDisplaceNewerHistoryOnNextSnapshot() {
        var log = RequestLog(limit: 1)
        let old = connection("old", age: 100)
        log.ingest([old, connection("new")], at: now)
        log.ingest([old], at: now.addingTimeInterval(1))
        XCTAssertEqual(log.entries.map(\.id), ["new"])
        XCTAssertFalse(log.entries[0].isActive)
    }

    func testClearDoesNotRepopulateExistingActiveRequests() {
        var log = RequestLog()
        let active = connection("active")
        log.ingest([active], at: now)
        log.clear()
        log.ingest([active], at: now.addingTimeInterval(1))
        XCTAssertTrue(log.entries.isEmpty)
        log.ingest([active, connection("new")], at: now.addingTimeInterval(2))
        XCTAssertEqual(log.entries.map(\.id), ["new"])
    }

    func testResetStartsFreshSessionEvenWithSameConnectionID() {
        var log = RequestLog()
        log.ingest([connection()], at: now)
        log.reset()
        XCTAssertTrue(log.entries.isEmpty)
        log.ingest([connection()], at: now.addingTimeInterval(1))
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertEqual(log.entries[0].observedAt, now.addingTimeInterval(1))
    }

    func testFinishMarksActiveRecordsEndedAndKeepsHistory() {
        var log = RequestLog()
        log.ingest([connection()], at: now)
        log.finish(at: now.addingTimeInterval(1))
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertFalse(log.entries[0].isActive)
        XCTAssertEqual(log.entries[0].endedAt, now.addingTimeInterval(1))
    }

    func testSearchIncludesHostProcessPolicyIntermediateNodeAndRule() {
        var log = RequestLog()
        log.ingest([connection()], at: now)
        for query in ["VIDEO", "example browser", "流媒体", "自动选择", "香港", "media", "tcp", "203.0.113.8", "127.0.0.1", "  "] {
            XCTAssertTrue(log.entries[0].matches(query), query)
        }
        XCTAssertFalse(log.entries[0].matches("unrelated"))
    }

    func testDuplicateSnapshotIDsUseLastValueWithoutCrashing() {
        var log = RequestLog()
        log.ingest([connection(upload: 1), connection(upload: 2)], at: now)
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertEqual(log.entries[0].connection.upload, 2)
    }

    func testTimestampWithOrWithoutFractionalSecondsSortsCorrectly() {
        var noFraction = connection("older")
        noFraction.start = ISO8601DateFormatter.mihomoSeconds.string(from: now.addingTimeInterval(-10))
        var log = RequestLog()
        log.ingest([noFraction, connection("newer")], at: now)
        XCTAssertEqual(log.entries.map(\.id), ["newer", "older"])
        XCTAssertEqual(log.entries[1].startedAt, now.addingTimeInterval(-10))
    }

    func testInvalidTimestampFallsBackToObservationWithStableOrdering() {
        var a = connection("a"), b = connection("b")
        a.start = "invalid"
        b.start = ""
        var log = RequestLog()
        log.ingest([b, a], at: now)
        XCTAssertEqual(log.entries.map(\.id), ["a", "b"])
        XCTAssertEqual(log.entries[0].startedAt, now)
    }

    func testConnectionsSnapshotDecodesRealisticRoutingMetadata() throws {
        let data = Data("""
        {"downloadTotal":200,"uploadTotal":100,"connections":[{
          "id":"fixture", "metadata":{"network":"tcp","type":"HTTP", "sourceIP":"127.0.0.1",
            "destinationIP":"203.0.113.9", "destinationPort":"443", "host":"example.com"},
          "upload":100, "download":200, "start":"2026-11-14T12:00:00Z",
          "chains":["Example Node","Policy"], "rule":"DomainSuffix", "rulePayload":"example.com"
        }]}
        """.utf8)
        let snapshot = try JSONDecoder().decode(ConnectionsSnapshot.self, from: data)
        var log = RequestLog()
        log.ingest(snapshot.connections ?? [], at: now)
        XCTAssertEqual(log.entries[0].policy, "Policy")
        XCTAssertEqual(log.entries[0].connection.metadata.displayHost, "example.com:443")
        XCTAssertNotNil(log.entries[0].connection.startDate)
    }
}
