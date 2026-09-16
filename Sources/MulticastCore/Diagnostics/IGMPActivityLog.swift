import Foundation

public enum IGMPEventKind: String, Sendable {
    case join
    case leave
    case partialWithdrawal
    case generalQuery
    case groupQuery
    case report

    public var displayName: String {
        switch self {
        case .join:              return "Join"
        case .leave:             return "Leave"
        case .partialWithdrawal: return "Block sources"
        case .generalQuery:      return "General query"
        case .groupQuery:        return "Group query"
        case .report:            return "Report"
        }
    }
}

public struct IGMPEvent: Identifiable, Equatable, Sendable {
    public let id: UInt64
    public let timestamp: Double
    public let kind: IGMPEventKind
    public let source: IPv4Address
    public let group: IPv4Address
    public let sources: [IPv4Address]
    public let version: String

    public init(id: UInt64, timestamp: Double, kind: IGMPEventKind, source: IPv4Address,
                group: IPv4Address, sources: [IPv4Address], version: String) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.source = source
        self.group = group
        self.sources = sources
        self.version = version
    }

    public var groupText: String { group == .unspecified ? "all groups" : group.description }
}

/// A bounded log of joins, leaves and queries.
public final class IGMPActivityLog {
    public let capacity: Int
    private var events: [IGMPEvent] = []
    private var nextIdentifier: UInt64 = 0

    public init(capacity: Int = 500) {
        self.capacity = max(1, capacity)
        events.reserveCapacity(self.capacity)
    }

    /// Turns one IGMP message into the events an operator cares about.
    /// A v3 report carries several records and so produces several events.
    @discardableResult
    public func record(_ message: IGMPMessage, from source: IPv4Address, at timestamp: Double) -> [IGMPEvent] {
        var produced: [IGMPEvent] = []

        switch message.messageType {
        case .query:
            produced.append(make(kind: message.isGeneralQuery ? .generalQuery : .groupQuery,
                                 source: source, group: message.group, sources: [],
                                 version: "v2/v3", at: timestamp))

        case .v1Report:
            produced.append(make(kind: .join, source: source, group: message.group,
                                 sources: [], version: "v1", at: timestamp))

        case .v2Report:
            produced.append(make(kind: .join, source: source, group: message.group,
                                 sources: [], version: "v2", at: timestamp))

        case .v2Leave:
            produced.append(make(kind: .leave, source: source, group: message.group,
                                 sources: [], version: "v2", at: timestamp))

        case .v3Report:
            for record in message.records {
                let kind: IGMPEventKind
                switch record.action {
                case .join:              kind = .join
                case .leave:             kind = .leave
                case .partialWithdrawal: kind = .partialWithdrawal
                }
                produced.append(make(kind: kind, source: source, group: record.group,
                                     sources: record.sources, version: "v3", at: timestamp))
            }
        }

        for event in produced { append(event) }
        return produced
    }

    private func make(kind: IGMPEventKind, source: IPv4Address, group: IPv4Address,
                      sources: [IPv4Address], version: String, at timestamp: Double) -> IGMPEvent {
        nextIdentifier += 1
        return IGMPEvent(id: nextIdentifier, timestamp: timestamp, kind: kind,
                         source: source, group: group, sources: sources, version: version)
    }

    private func append(_ event: IGMPEvent) {
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
    }

    /// Newest first, which is how the log reads.
    public func recent(limit: Int = 200) -> [IGMPEvent] {
        Array(events.suffix(limit).reversed())
    }

    public var count: Int { events.count }

    /// The "IGMP events/min" tile. Counted over the last 60 seconds.
    public func eventsPerMinute(now: Double) -> Int {
        var total = 0
        for event in events.reversed() {
            if now - event.timestamp > 60 { break }
            total += 1
        }
        return total
    }

    public func reset() {
        events.removeAll()
        nextIdentifier = 0
    }
}
