import Foundation
import MulticastCore

/// Builds real byte-level frames for the parser tests. Nothing here is mocked:
/// the tests feed the parser the same bytes a NIC would.
enum FrameBuilder {
    static func mac(_ text: String) -> MACAddress { MACAddress(parsing: text)! }
    static func ip(_ text: String) -> IPv4Address { IPv4Address(text)! }

    static func bigEndian16(_ value: UInt16) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }

    static func addressBytes(_ address: IPv4Address) -> [UInt8] {
        let b = address.bytes
        return [b.0, b.1, b.2, b.3]
    }

    /// Ethernet II, optionally with one or more 802.1Q tags.
    static func ethernet(destination: MACAddress,
                         source: MACAddress,
                         etherType: UInt16 = EtherType.ipv4,
                         vlans: [UInt16] = [],
                         tagProtocol: UInt16 = EtherType.vlan,
                         payload: [UInt8]) -> [UInt8] {
        var frame: [UInt8] = []
        frame += destination.bytes
        frame += source.bytes
        for vlan in vlans {
            frame += bigEndian16(tagProtocol)
            frame += bigEndian16(vlan & 0x0FFF)     // PCP/DEI left at zero
        }
        frame += bigEndian16(etherType)
        frame += payload
        return frame
    }

    /// IPv4 header + payload. The checksum is left zero; the parser does not
    /// verify it, and the kernel filter has already selected these frames.
    static func ipv4(source: IPv4Address,
                     destination: IPv4Address,
                     protocolNumber: UInt8,
                     ttl: UInt8 = 64,
                     identification: UInt16 = 0,
                     moreFragments: Bool = false,
                     fragmentOffsetBytes: Int = 0,
                     optionWords: Int = 0,
                     payload: [UInt8],
                     overrideTotalLength: UInt16? = nil) -> [UInt8] {
        let headerWords = 5 + optionWords
        let headerLength = headerWords * 4
        let totalLength = overrideTotalLength ?? UInt16(headerLength + payload.count)

        var flagsAndOffset = UInt16(fragmentOffsetBytes / 8) & 0x1FFF
        if moreFragments { flagsAndOffset |= 0x2000 }

        var header: [UInt8] = []
        header.append(UInt8(0x40 | headerWords))        // version 4, IHL
        header.append(0)                                 // DSCP/ECN
        header += bigEndian16(totalLength)
        header += bigEndian16(identification)
        header += bigEndian16(flagsAndOffset)
        header.append(ttl)
        header.append(protocolNumber)
        header += [0, 0]                                 // header checksum
        header += addressBytes(source)
        header += addressBytes(destination)
        header += [UInt8](repeating: 0, count: optionWords * 4)
        return header + payload
    }

    static func udp(sourcePort: UInt16, destinationPort: UInt16, payload: [UInt8]) -> [UInt8] {
        var datagram: [UInt8] = []
        datagram += bigEndian16(sourcePort)
        datagram += bigEndian16(destinationPort)
        datagram += bigEndian16(UInt16(8 + payload.count))
        datagram += [0, 0]                               // checksum, optional in IPv4
        datagram += payload
        return datagram
    }

    /// A complete multicast UDP frame.
    static func udpFrame(source: String, destination: String,
                         sourcePort: UInt16, destinationPort: UInt16,
                         ttl: UInt8 = 64, vlans: [UInt16] = [],
                         payloadLength: Int = 100) -> [UInt8] {
        let groupAddress = ip(destination)
        let datagram = udp(sourcePort: sourcePort, destinationPort: destinationPort,
                           payload: [UInt8](repeating: 0xAB, count: payloadLength))
        let packet = ipv4(source: ip(source), destination: groupAddress,
                          protocolNumber: IPProtocol.udp, ttl: ttl, payload: datagram)
        return ethernet(destination: groupAddress.ethernetMulticastMAC,
                        source: mac("00:1d:c1:aa:bb:cc"),
                        vlans: vlans, payload: packet)
    }

    // MARK: - IGMP

    static func igmpV2(type: UInt8, group: IPv4Address, maxResponseCode: UInt8 = 100) -> [UInt8] {
        var message: [UInt8] = [type, maxResponseCode, 0, 0]
        message += addressBytes(group)
        return message
    }

    /// One IGMPv3 group record, including aux data if asked for.
    static func groupRecord(type: UInt8, group: IPv4Address,
                            sources: [IPv4Address], auxWords: Int = 0) -> [UInt8] {
        var record: [UInt8] = [type, UInt8(auxWords)]
        record += bigEndian16(UInt16(sources.count))
        record += addressBytes(group)
        for source in sources { record += addressBytes(source) }
        record += [UInt8](repeating: 0xEE, count: auxWords * 4)
        return record
    }

    static func igmpV3Report(records: [[UInt8]], claimedCount: UInt16? = nil) -> [UInt8] {
        var message: [UInt8] = [0x22, 0, 0, 0, 0, 0]
        message += bigEndian16(claimedCount ?? UInt16(records.count))
        for record in records { message += record }
        return message
    }

    static func igmpFrame(payload: [UInt8], source: String, destination: String, ttl: UInt8 = 1) -> [UInt8] {
        let groupAddress = ip(destination)
        let packet = ipv4(source: ip(source), destination: groupAddress,
                          protocolNumber: IPProtocol.igmp, ttl: ttl, payload: payload)
        return ethernet(destination: groupAddress.ethernetMulticastMAC,
                        source: mac("00:1d:c1:aa:bb:cc"), payload: packet)
    }
}
