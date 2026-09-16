import Foundation

public enum IGMPMessageType: UInt8, CustomStringConvertible, Sendable {
    case query      = 0x11
    case v1Report   = 0x12
    case v2Report   = 0x16
    case v2Leave    = 0x17
    case v3Report   = 0x22

    public var description: String {
        switch self {
        case .query:    return "Query"
        case .v1Report: return "v1 Report"
        case .v2Report: return "v2 Report"
        case .v2Leave:  return "v2 Leave"
        case .v3Report: return "v3 Report"
        }
    }
}

public enum IGMPRecordType: UInt8, CustomStringConvertible, Sendable {
    case modeIsInclude    = 1
    case modeIsExclude    = 2
    case changeToInclude  = 3
    case changeToExclude  = 4
    case allowNewSources  = 5
    case blockOldSources  = 6

    public var description: String {
        switch self {
        case .modeIsInclude:   return "MODE_IS_INCLUDE"
        case .modeIsExclude:   return "MODE_IS_EXCLUDE"
        case .changeToInclude: return "CHANGE_TO_INCLUDE"
        case .changeToExclude: return "CHANGE_TO_EXCLUDE"
        case .allowNewSources: return "ALLOW_NEW_SOURCES"
        case .blockOldSources: return "BLOCK_OLD_SOURCES"
        }
    }
}

/// What a record means to someone watching streams come and go, as opposed to
/// what it means to the IGMP state machine.
public enum MembershipAction: String, Sendable {
    case join
    case leave
    /// BLOCK_OLD_SOURCES. The receiver is dropping specific sources but stays
    /// in the group, so calling it a leave would be wrong -- it gets reported
    /// as what it is.
    case partialWithdrawal
}

public extension IGMPRecordType {
    /// The operator-facing reading of a v3 record.
    ///
    /// EXCLUDE{} means "everything except nothing", i.e. join; INCLUDE{} means
    /// "only these sources, and there are none", i.e. leave. With a non-empty
    /// source list INCLUDE is a join of those specific sources.
    func membershipAction(hasSources: Bool) -> MembershipAction {
        switch self {
        case .modeIsExclude, .changeToExclude, .allowNewSources:
            return .join
        case .modeIsInclude, .changeToInclude:
            return hasSources ? .join : .leave
        case .blockOldSources:
            // With sources this withdraws part of a subscription. With none it
            // withdraws nothing at all; either way it is not a leave.
            return .partialWithdrawal
        }
    }
}

public struct IGMPGroupRecord: Equatable, Sendable {
    public let recordType: IGMPRecordType
    public let group: IPv4Address
    public let sources: [IPv4Address]

    public init(recordType: IGMPRecordType, group: IPv4Address, sources: [IPv4Address]) {
        self.recordType = recordType
        self.group = group
        self.sources = sources
    }

    public var action: MembershipAction { recordType.membershipAction(hasSources: !sources.isEmpty) }
}

public struct IGMPMessage: Equatable, Sendable {
    public let messageType: IGMPMessageType
    /// Query/report subject. 0.0.0.0 on a general query.
    public let group: IPv4Address
    public let maxResponseCode: UInt8
    public let records: [IGMPGroupRecord]
    /// True when the sender claimed more group records than the packet held.
    /// Worth surfacing: it is either a broken stack or a truncated capture.
    public let recordCountWasOverstated: Bool

    public init(messageType: IGMPMessageType, group: IPv4Address, maxResponseCode: UInt8,
                records: [IGMPGroupRecord], recordCountWasOverstated: Bool = false) {
        self.messageType = messageType
        self.group = group
        self.maxResponseCode = maxResponseCode
        self.records = records
        self.recordCountWasOverstated = recordCountWasOverstated
    }

    /// A query naming 0.0.0.0 asks about every group; one naming a group asks
    /// only about that group. Only the former resets the general timer.
    public var isGeneralQuery: Bool { messageType == .query && group == .unspecified }
    public var isGroupSpecificQuery: Bool { messageType == .query && group != .unspecified }
}

public enum IGMPParser {
    /// Parses an IGMP message starting at `offset`. `availableLength` is the
    /// IP payload length, which is authoritative -- the captured buffer may be
    /// longer (Ethernet padding) or shorter (snaplen).
    public static func parse(_ cursor: ByteCursor, offset: Int, availableLength: Int) -> IGMPMessage? {
        let limit = min(cursor.count, offset + max(0, availableLength))
        guard offset >= 0, limit - offset >= 8 else { return nil }
        guard let rawType = cursor.byte(at: offset),
              let messageType = IGMPMessageType(rawValue: rawType) else { return nil }
        let maxResponseCode = cursor.byte(at: offset + 1) ?? 0

        switch messageType {
        case .query, .v1Report, .v2Report, .v2Leave:
            guard let group = cursor.address(at: offset + 4) else { return nil }
            return IGMPMessage(messageType: messageType, group: group,
                               maxResponseCode: maxResponseCode, records: [])

        case .v3Report:
            guard let claimed = cursor.uint16(at: offset + 6) else { return nil }
            var records: [IGMPGroupRecord] = []
            var position = offset + 8
            var overstated = false

            for _ in 0..<claimed {
                // Fixed part of a record: type, aux length, source count, group.
                guard position + 8 <= limit,
                      let rawRecordType = cursor.byte(at: position),
                      let auxWords = cursor.byte(at: position + 1),
                      let sourceCount = cursor.uint16(at: position + 2),
                      let group = cursor.address(at: position + 4)
                else { overstated = true; break }

                // Aux data length is counted in 32-bit words, not bytes.
                let sourceBytes = Int(sourceCount) * 4
                let auxBytes = Int(auxWords) * 4
                let recordLength = 8 + sourceBytes + auxBytes
                guard position + recordLength <= limit else { overstated = true; break }

                var sources: [IPv4Address] = []
                sources.reserveCapacity(Int(sourceCount))
                for index in 0..<Int(sourceCount) {
                    guard let source = cursor.address(at: position + 8 + index * 4) else { break }
                    sources.append(source)
                }

                // An unknown record type is skipped, not fatal -- the length
                // fields still tell us how far to advance.
                if let recordType = IGMPRecordType(rawValue: rawRecordType) {
                    records.append(IGMPGroupRecord(recordType: recordType, group: group, sources: sources))
                }
                position += recordLength
            }

            return IGMPMessage(messageType: .v3Report, group: .unspecified,
                               maxResponseCode: maxResponseCode, records: records,
                               recordCountWasOverstated: overstated)
        }
    }
}
