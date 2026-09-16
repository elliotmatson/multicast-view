import XCTest
import MulticastCore

final class ParsingTests: XCTestCase {
    private var parser = PacketParser()

    override func setUp() {
        parser = PacketParser()
    }

    func testPlainMulticastUDPFrame() throws {
        let frame = FrameBuilder.udpFrame(source: "10.10.1.50", destination: "239.255.0.12",
                                          sourcePort: 5568, destinationPort: 5568,
                                          ttl: 16, payloadLength: 630)
        let packet = try XCTUnwrap(parser.parse(frame, timestamp: 100))
        XCTAssertEqual(packet.source, FrameBuilder.ip("10.10.1.50"))
        XCTAssertEqual(packet.destination, FrameBuilder.ip("239.255.0.12"))
        XCTAssertEqual(packet.destinationPort, 5568)
        XCTAssertEqual(packet.ttl, 16)
        XCTAssertEqual(packet.protocolNumber, IPProtocol.udp)
        // 20 IP + 8 UDP + 630 payload
        XCTAssertEqual(packet.ipTotalLength, 658)
        XCTAssertTrue(packet.vlanIdentifiers.isEmpty)
        XCTAssertFalse(packet.isFragment)
    }

    func testUnicastIsIgnored() {
        let frame = FrameBuilder.udpFrame(source: "10.10.1.50", destination: "10.10.1.60",
                                          sourcePort: 5568, destinationPort: 5568)
        XCTAssertNil(parser.parse(frame, timestamp: 100))
    }

    func testNonIPv4EtherTypeIsIgnored() {
        // ARP. Nothing to classify, and reading an IP header here would be wrong.
        let frame = FrameBuilder.ethernet(destination: FrameBuilder.mac("ff:ff:ff:ff:ff:ff"),
                                          source: FrameBuilder.mac("00:1d:c1:aa:bb:cc"),
                                          etherType: 0x0806,
                                          payload: [UInt8](repeating: 0, count: 28))
        XCTAssertNil(parser.parse(frame, timestamp: 100))
    }

    // MARK: - VLAN

    func testSingleVLANTag() throws {
        let frame = FrameBuilder.udpFrame(source: "10.10.1.50", destination: "239.69.0.5",
                                          sourcePort: 5004, destinationPort: 5004,
                                          vlans: [120], payloadLength: 200)
        let packet = try XCTUnwrap(parser.parse(frame, timestamp: 100))
        XCTAssertEqual(packet.vlanIdentifiers, [120])
        XCTAssertEqual(packet.destinationPort, 5004)
        XCTAssertEqual(packet.ipTotalLength, 228)
    }

    func testStackedVLANTags() throws {
        let datagram = FrameBuilder.udp(sourcePort: 319, destinationPort: 319,
                                        payload: [UInt8](repeating: 0, count: 44))
        let packet = FrameBuilder.ipv4(source: FrameBuilder.ip("10.10.1.7"),
                                       destination: FrameBuilder.ip("224.0.1.129"),
                                       protocolNumber: IPProtocol.udp, ttl: 1, payload: datagram)
        // Outer 802.1ad tag, inner 802.1Q tag.
        var frame: [UInt8] = []
        frame += FrameBuilder.ip("224.0.1.129").ethernetMulticastMAC.bytes
        frame += FrameBuilder.mac("00:1d:c1:aa:bb:cc").bytes
        frame += FrameBuilder.bigEndian16(EtherType.providerBridging)
        frame += FrameBuilder.bigEndian16(400)
        frame += FrameBuilder.bigEndian16(EtherType.vlan)
        frame += FrameBuilder.bigEndian16(120)
        frame += FrameBuilder.bigEndian16(EtherType.ipv4)
        frame += packet

        let parsed = try XCTUnwrap(parser.parse(frame, timestamp: 100))
        XCTAssertEqual(parsed.vlanIdentifiers, [400, 120])
        XCTAssertEqual(parsed.destinationPort, 319)
    }

    func testVLANPriorityBitsAreMaskedOff() throws {
        // PCP 5, DEI 0, VLAN 120 -> TCI 0xA078. Only the low 12 bits are the ID.
        var frame: [UInt8] = []
        frame += FrameBuilder.ip("239.255.0.12").ethernetMulticastMAC.bytes
        frame += FrameBuilder.mac("00:1d:c1:aa:bb:cc").bytes
        frame += FrameBuilder.bigEndian16(EtherType.vlan)
        frame += FrameBuilder.bigEndian16(0xA078)
        frame += FrameBuilder.bigEndian16(EtherType.ipv4)
        frame += FrameBuilder.ipv4(source: FrameBuilder.ip("10.0.0.1"),
                                   destination: FrameBuilder.ip("239.255.0.12"),
                                   protocolNumber: IPProtocol.udp,
                                   payload: FrameBuilder.udp(sourcePort: 5568, destinationPort: 5568, payload: []))
        let parsed = try XCTUnwrap(parser.parse(frame, timestamp: 100))
        XCTAssertEqual(parsed.vlanIdentifiers, [120])
    }

    // MARK: - Malformed input

    func testEmptyAndTruncatedFramesAreRejected() {
        XCTAssertNil(parser.parse([], timestamp: 100))
        XCTAssertNil(parser.parse([UInt8](repeating: 0, count: 13), timestamp: 100))
        XCTAssertNil(parser.parse([UInt8](repeating: 0, count: 14), timestamp: 100))

        // Ethernet header claiming IPv4 but with no IP header behind it.
        let headerOnly = FrameBuilder.ethernet(destination: FrameBuilder.mac("01:00:5e:00:00:01"),
                                               source: FrameBuilder.mac("00:1d:c1:aa:bb:cc"),
                                               payload: [])
        XCTAssertNil(parser.parse(headerOnly, timestamp: 100))
    }

    func testTruncatedIPHeaderIsRejected() {
        var full = FrameBuilder.udpFrame(source: "10.0.0.1", destination: "239.255.0.12",
                                         sourcePort: 5568, destinationPort: 5568)
        // Cut into the middle of the IP header.
        let truncated = Array(full.prefix(14 + 12))
        XCTAssertNil(parser.parse(truncated, timestamp: 100))
        full.removeAll()
    }

    func testBadIPVersionAndHeaderLengthAreRejected() {
        var frame = FrameBuilder.udpFrame(source: "10.0.0.1", destination: "239.255.0.12",
                                          sourcePort: 5568, destinationPort: 5568)
        frame[14] = 0x65                       // version 6 in an IPv4 EtherType frame
        XCTAssertNil(parser.parse(frame, timestamp: 100))

        frame[14] = 0x44                       // IHL of 4 words: shorter than the header itself
        XCTAssertNil(parser.parse(frame, timestamp: 100))
    }

    func testTotalLengthShorterThanHeaderIsRejected() {
        let datagram = FrameBuilder.udp(sourcePort: 5568, destinationPort: 5568, payload: [])
        let packet = FrameBuilder.ipv4(source: FrameBuilder.ip("10.0.0.1"),
                                       destination: FrameBuilder.ip("239.255.0.12"),
                                       protocolNumber: IPProtocol.udp,
                                       payload: datagram, overrideTotalLength: 12)
        let frame = FrameBuilder.ethernet(destination: FrameBuilder.mac("01:00:5e:7f:00:0c"),
                                          source: FrameBuilder.mac("00:1d:c1:aa:bb:cc"),
                                          payload: packet)
        XCTAssertNil(parser.parse(frame, timestamp: 100))
    }

    func testIPOptionsShiftTheTransportHeader() throws {
        // IHL 7: five options words' worth of header before UDP starts.
        let datagram = FrameBuilder.udp(sourcePort: 6454, destinationPort: 6454,
                                        payload: [UInt8](repeating: 1, count: 20))
        let packet = FrameBuilder.ipv4(source: FrameBuilder.ip("10.0.0.1"),
                                       destination: FrameBuilder.ip("239.255.0.12"),
                                       protocolNumber: IPProtocol.udp,
                                       optionWords: 2, payload: datagram)
        let frame = FrameBuilder.ethernet(destination: FrameBuilder.mac("01:00:5e:7f:00:0c"),
                                          source: FrameBuilder.mac("00:1d:c1:aa:bb:cc"),
                                          payload: packet)
        let parsed = try XCTUnwrap(parser.parse(frame, timestamp: 100))
        XCTAssertEqual(parsed.destinationPort, 6454, "IP options must shift where the UDP header is read from")
        XCTAssertEqual(parsed.ipTotalLength, 28 + 28)
    }

    func testRateUsesIPTotalLengthNotCapturedLength() throws {
        // Simulates a short snaplen: the IP header says 1400 bytes, only 128
        // were captured. Rates must follow the header.
        let datagram = FrameBuilder.udp(sourcePort: 5004, destinationPort: 5004,
                                        payload: [UInt8](repeating: 0, count: 80))
        let packet = FrameBuilder.ipv4(source: FrameBuilder.ip("10.0.0.1"),
                                       destination: FrameBuilder.ip("239.69.0.1"),
                                       protocolNumber: IPProtocol.udp,
                                       payload: datagram, overrideTotalLength: 1400)
        let frame = FrameBuilder.ethernet(destination: FrameBuilder.mac("01:00:5e:45:00:01"),
                                          source: FrameBuilder.mac("00:1d:c1:aa:bb:cc"),
                                          payload: packet)
        let parsed = try XCTUnwrap(parser.parse(frame, timestamp: 100))
        XCTAssertEqual(parsed.ipTotalLength, 1400)
        XCTAssertLessThan(frame.count, 1400)
    }

    // MARK: - Fragmentation

    func testTrailingFragmentAloneProducesNoPorts() throws {
        // The exact failure this guards against: reading the transport offset
        // unconditionally turns payload bytes into a phantom port.
        let payload: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF] + [UInt8](repeating: 0x11, count: 100)
        let packet = FrameBuilder.ipv4(source: FrameBuilder.ip("10.0.0.1"),
                                       destination: FrameBuilder.ip("239.69.0.1"),
                                       protocolNumber: IPProtocol.udp,
                                       identification: 0x1234,
                                       moreFragments: false, fragmentOffsetBytes: 1480,
                                       payload: payload)
        let frame = FrameBuilder.ethernet(destination: FrameBuilder.mac("01:00:5e:45:00:01"),
                                          source: FrameBuilder.mac("00:1d:c1:aa:bb:cc"),
                                          payload: packet)
        let parsed = try XCTUnwrap(parser.parse(frame, timestamp: 100))
        XCTAssertTrue(parsed.isFragment)
        XCTAssertNil(parsed.sourcePort, "0xDEAD must not be reported as a port")
        XCTAssertNil(parsed.destinationPort, "0xBEEF must not be reported as a port")
        XCTAssertFalse(parsed.portsInferredFromFirstFragment)
    }

    func testOrderedFragmentPairAttributesTrailingFragmentToTheStream() throws {
        let first = FrameBuilder.ipv4(source: FrameBuilder.ip("10.0.0.1"),
                                      destination: FrameBuilder.ip("239.69.0.1"),
                                      protocolNumber: IPProtocol.udp,
                                      identification: 0x4321,
                                      moreFragments: true, fragmentOffsetBytes: 0,
                                      payload: FrameBuilder.udp(sourcePort: 5004, destinationPort: 5004,
                                                                payload: [UInt8](repeating: 0, count: 1472)))
        let second = FrameBuilder.ipv4(source: FrameBuilder.ip("10.0.0.1"),
                                       destination: FrameBuilder.ip("239.69.0.1"),
                                       protocolNumber: IPProtocol.udp,
                                       identification: 0x4321,
                                       moreFragments: false, fragmentOffsetBytes: 1480,
                                       payload: [0xDE, 0xAD, 0xBE, 0xEF] + [UInt8](repeating: 0, count: 100))

        let mac = FrameBuilder.mac("01:00:5e:45:00:01")
        let sender = FrameBuilder.mac("00:1d:c1:aa:bb:cc")

        let firstParsed = try XCTUnwrap(parser.parse(FrameBuilder.ethernet(destination: mac, source: sender, payload: first), timestamp: 100))
        XCTAssertEqual(firstParsed.destinationPort, 5004)
        XCTAssertFalse(firstParsed.portsInferredFromFirstFragment)

        let secondParsed = try XCTUnwrap(parser.parse(FrameBuilder.ethernet(destination: mac, source: sender, payload: second), timestamp: 100))
        XCTAssertEqual(secondParsed.sourcePort, 5004)
        XCTAssertEqual(secondParsed.destinationPort, 5004)
        XCTAssertTrue(secondParsed.portsInferredFromFirstFragment)
        XCTAssertEqual(secondParsed.ipTotalLength, 20 + 104)
    }

    func testFragmentKeyDoesNotLeakAcrossIdentifications() throws {
        let mac = FrameBuilder.mac("01:00:5e:45:00:01")
        let sender = FrameBuilder.mac("00:1d:c1:aa:bb:cc")
        let first = FrameBuilder.ipv4(source: FrameBuilder.ip("10.0.0.1"),
                                      destination: FrameBuilder.ip("239.69.0.1"),
                                      protocolNumber: IPProtocol.udp, identification: 1,
                                      moreFragments: true,
                                      payload: FrameBuilder.udp(sourcePort: 5004, destinationPort: 5004, payload: []))
        _ = parser.parse(FrameBuilder.ethernet(destination: mac, source: sender, payload: first), timestamp: 100)

        // Different IP identification: unrelated datagram, must not inherit ports.
        let other = FrameBuilder.ipv4(source: FrameBuilder.ip("10.0.0.1"),
                                      destination: FrameBuilder.ip("239.69.0.1"),
                                      protocolNumber: IPProtocol.udp, identification: 2,
                                      moreFragments: false, fragmentOffsetBytes: 1480,
                                      payload: [UInt8](repeating: 0, count: 40))
        let parsed = try XCTUnwrap(parser.parse(FrameBuilder.ethernet(destination: mac, source: sender, payload: other), timestamp: 100))
        XCTAssertNil(parsed.destinationPort)
    }

    func testFragmentCacheExpires() throws {
        let tracker = FragmentTracker(capacity: 16, lifetime: 30)
        let key = FragmentTracker.Key(source: FrameBuilder.ip("10.0.0.1"),
                                      destination: FrameBuilder.ip("239.69.0.1"),
                                      identification: 7, protocolNumber: IPProtocol.udp)
        tracker.record(key: key, ports: .init(source: 5004, destination: 5004), at: 100)
        XCTAssertNotNil(tracker.ports(for: key, at: 129))
        XCTAssertNil(tracker.ports(for: key, at: 131))
    }

    func testFragmentCacheIsBounded() {
        let tracker = FragmentTracker(capacity: 8, lifetime: 30)
        for index in 0..<200 {
            let key = FragmentTracker.Key(source: FrameBuilder.ip("10.0.0.1"),
                                          destination: FrameBuilder.ip("239.69.0.1"),
                                          identification: UInt16(index), protocolNumber: IPProtocol.udp)
            tracker.record(key: key, ports: .init(source: 5004, destination: 5004), at: 100)
        }
        XCTAssertLessThanOrEqual(tracker.count, 8)
    }
}
