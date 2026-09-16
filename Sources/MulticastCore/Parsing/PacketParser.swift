import Foundation

public struct ObservedPacket: Equatable {
    public let timestamp: Double
    public let sourceMAC: MACAddress?
    public let destinationMAC: MACAddress?
    /// Outer first. Usually empty; a mirrored trunk port gives one, QinQ two.
    public let vlanIdentifiers: [UInt16]
    public let source: IPv4Address
    public let destination: IPv4Address
    public let ttl: UInt8
    public let protocolNumber: UInt8
    /// Taken from the IP header's total length, never from the captured
    /// length. With a short snaplen the two differ and every rate computed
    /// from the captured length is understated.
    public let ipTotalLength: Int
    public let sourcePort: UInt16?
    public let destinationPort: UInt16?
    /// True when the ports came from a remembered first fragment rather than
    /// from bytes in this packet.
    public let portsInferredFromFirstFragment: Bool
    public let isFragment: Bool
    public let igmp: IGMPMessage?

    public init(timestamp: Double, sourceMAC: MACAddress?, destinationMAC: MACAddress?,
                vlanIdentifiers: [UInt16], source: IPv4Address, destination: IPv4Address,
                ttl: UInt8, protocolNumber: UInt8, ipTotalLength: Int,
                sourcePort: UInt16?, destinationPort: UInt16?,
                portsInferredFromFirstFragment: Bool, isFragment: Bool, igmp: IGMPMessage?) {
        self.timestamp = timestamp
        self.sourceMAC = sourceMAC
        self.destinationMAC = destinationMAC
        self.vlanIdentifiers = vlanIdentifiers
        self.source = source
        self.destination = destination
        self.ttl = ttl
        self.protocolNumber = protocolNumber
        self.ipTotalLength = ipTotalLength
        self.sourcePort = sourcePort
        self.destinationPort = destinationPort
        self.portsInferredFromFirstFragment = portsInferredFromFirstFragment
        self.isFragment = isFragment
        self.igmp = igmp
    }
}

public enum EtherType {
    public static let ipv4: UInt16 = 0x0800
    public static let vlan: UInt16 = 0x8100
    public static let providerBridging: UInt16 = 0x88A8
    public static let legacyQinQ: UInt16 = 0x9100
}

public enum IPProtocol {
    public static let igmp: UInt8 = 2
    public static let udp: UInt8 = 17
    public static let tcp: UInt8 = 6
    public static let ospf: UInt8 = 89
    public static let pim: UInt8 = 103
}

public final class PacketParser {
    public let fragments: FragmentTracker
    /// A frame can legitimately carry a stacked tag or two. More than this and
    /// we are almost certainly not looking at VLAN tags any more.
    private let maximumVLANTags = 3

    public init(fragments: FragmentTracker = FragmentTracker()) {
        self.fragments = fragments
    }

    /// Parses one Ethernet frame. Returns nil for anything that isn't IPv4
    /// multicast, and for anything malformed.
    public func parse(_ cursor: ByteCursor, timestamp: Double) -> ObservedPacket? {
        guard cursor.count >= 14 else { return nil }

        let destinationMAC = cursor.mac(at: 0)
        let sourceMAC = cursor.mac(at: 6)

        // Walk any VLAN tags before assuming where the IP header starts.
        var etherTypeOffset = 12
        var vlanIdentifiers: [UInt16] = []
        var etherType = cursor.uint16(at: etherTypeOffset)

        var tagCount = 0
        while let type = etherType,
              type == EtherType.vlan || type == EtherType.providerBridging || type == EtherType.legacyQinQ,
              tagCount < maximumVLANTags {
            guard let tagControl = cursor.uint16(at: etherTypeOffset + 2) else { return nil }
            vlanIdentifiers.append(tagControl & 0x0FFF)
            etherTypeOffset += 4
            etherType = cursor.uint16(at: etherTypeOffset)
            tagCount += 1
        }

        guard etherType == EtherType.ipv4 else { return nil }
        let ipOffset = etherTypeOffset + 2

        return parseIPv4(cursor, at: ipOffset, timestamp: timestamp,
                         sourceMAC: sourceMAC, destinationMAC: destinationMAC,
                         vlanIdentifiers: vlanIdentifiers)
    }

    private func parseIPv4(_ cursor: ByteCursor, at ipOffset: Int, timestamp: Double,
                           sourceMAC: MACAddress?, destinationMAC: MACAddress?,
                           vlanIdentifiers: [UInt16]) -> ObservedPacket? {
        guard let versionAndLength = cursor.byte(at: ipOffset) else { return nil }
        guard versionAndLength >> 4 == 4 else { return nil }
        let headerWords = Int(versionAndLength & 0x0F)
        guard headerWords >= 5 else { return nil }
        let headerLength = headerWords * 4

        guard let totalLength = cursor.uint16(at: ipOffset + 2),
              let identification = cursor.uint16(at: ipOffset + 4),
              let flagsAndOffset = cursor.uint16(at: ipOffset + 6),
              let ttl = cursor.byte(at: ipOffset + 8),
              let protocolNumber = cursor.byte(at: ipOffset + 9),
              let source = cursor.address(at: ipOffset + 12),
              let destination = cursor.address(at: ipOffset + 16)
        else { return nil }

        // A total length shorter than the header it claims is nonsense.
        guard Int(totalLength) >= headerLength else { return nil }
        guard destination.isMulticast else { return nil }

        let moreFragments = (flagsAndOffset & 0x2000) != 0
        let fragmentOffset = Int(flagsAndOffset & 0x1FFF) * 8   // counted in 8-byte units
        let isFragment = moreFragments || fragmentOffset > 0

        let transportOffset = ipOffset + headerLength
        let ipPayloadLength = Int(totalLength) - headerLength

        var sourcePort: UInt16?
        var destinationPort: UInt16?
        var inferredPorts = false
        var igmp: IGMPMessage?

        let fragmentKey = FragmentTracker.Key(source: source, destination: destination,
                                              identification: identification,
                                              protocolNumber: protocolNumber)

        if fragmentOffset == 0 {
            // Only the first fragment carries a transport header.
            switch protocolNumber {
            case IPProtocol.udp, IPProtocol.tcp:
                sourcePort = cursor.uint16(at: transportOffset)
                destinationPort = cursor.uint16(at: transportOffset + 2)
                if isFragment, let from = sourcePort, let to = destinationPort {
                    fragments.record(key: fragmentKey,
                                     ports: FragmentTracker.Ports(source: from, destination: to),
                                     at: timestamp)
                }
            case IPProtocol.igmp:
                igmp = IGMPParser.parse(cursor, offset: transportOffset, availableLength: ipPayloadLength)
            default:
                break
            }
        } else if protocolNumber == IPProtocol.udp || protocolNumber == IPProtocol.tcp {
            // Trailing fragment. There is no transport header here; reading one
            // would invent a stream on a garbage port.
            if let ports = fragments.ports(for: fragmentKey, at: timestamp) {
                sourcePort = ports.source
                destinationPort = ports.destination
                inferredPorts = true
            }
            if !moreFragments {
                fragments.forget(key: fragmentKey)   // datagram complete
            }
        }

        return ObservedPacket(timestamp: timestamp,
                              sourceMAC: sourceMAC,
                              destinationMAC: destinationMAC,
                              vlanIdentifiers: vlanIdentifiers,
                              source: source,
                              destination: destination,
                              ttl: ttl,
                              protocolNumber: protocolNumber,
                              ipTotalLength: Int(totalLength),
                              sourcePort: sourcePort,
                              destinationPort: destinationPort,
                              portsInferredFromFirstFragment: inferredPorts,
                              isFragment: isFragment,
                              igmp: igmp)
    }

    /// Convenience for tests and for callers holding a byte array.
    public func parse(_ frame: [UInt8], timestamp: Double) -> ObservedPacket? {
        frame.withCursor { parse($0, timestamp: timestamp) }
    }
}
