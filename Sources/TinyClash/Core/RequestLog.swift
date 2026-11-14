import Foundation

struct RequestLogEntry: Identifiable {
    var connection: Connection
    var observedAt: Date
    var lastSeenAt: Date
    var endedAt: Date?
    let startedAt: Date

    var id: String { connection.id }
    var isActive: Bool { endedAt == nil }
    // mihomo reports chains from the outbound node back to the matching policy.
    var route: [String] { connection.chains.reversed() }
    var policy: String { route.first ?? "未知策略" }
    var node: String? { route.last }
    var matchedRule: String {
        let type = connection.rule.isEmpty ? "未知规则" : connection.rule
        return connection.rulePayload.isEmpty ? type : "\(type) (\(connection.rulePayload))"
    }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return ([connection.metadata.displayHost, connection.metadata.host, connection.metadata.destinationIP,
                 connection.metadata.sourceIP, connection.metadata.process ?? "", connection.metadata.network,
                 matchedRule] + route).contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

/// A bounded, in-memory history of connections actually observed in core snapshots.
struct RequestLog {
    let limit: Int
    private(set) var entries: [RequestLogEntry] = []
    private var activeIDs: Set<String> = []

    init(limit: Int = 500) {
        self.limit = max(1, limit)
    }

    mutating func ingest(_ connections: [Connection], at now: Date = Date()) {
        let current = Dictionary(connections.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let knownIDs = Set(entries.map(\.id))
        for index in entries.indices {
            if let connection = current[entries[index].id] {
                entries[index].connection = connection
                entries[index].lastSeenAt = now
                entries[index].endedAt = nil
            } else if entries[index].isActive {
                entries[index].endedAt = now
            }
        }
        for (id, connection) in current where !knownIDs.contains(id) && !activeIDs.contains(id) {
            entries.append(RequestLogEntry(connection: connection, observedAt: now, lastSeenAt: now,
                                           startedAt: connection.startDate ?? now))
        }
        activeIDs = Set(current.keys)
        entries.sort {
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.id < $1.id
        }
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }

    mutating func finish(at now: Date = Date()) {
        for index in entries.indices where entries[index].isActive {
            entries[index].endedAt = now
        }
        activeIDs = []
    }

    /// Keep the current IDs so clearing does not re-add the same active requests.
    mutating func clear() {
        entries = []
    }

    mutating func reset() {
        entries = []
        activeIDs = []
    }
}
