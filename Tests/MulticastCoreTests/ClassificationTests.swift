import XCTest
import MulticastCore

final class ClassificationTests: XCTestCase {
    private func classify(_ group: String, port: UInt16?, sourcePort: UInt16? = nil) -> StreamIdentity {
        StreamClassifier.classify(destination: IPv4Address(group)!,
                                  destinationPort: port, sourcePort: sourcePort)
    }

    // MARK: - Port-pinned, certain

    func testCertainPortAssignments() {
        let cases: [(String, UInt16, String, ProtocolFamily)] = [
            ("224.0.1.129",     319,  "PTPv2",        .clock),
            ("224.0.1.129",     320,  "PTPv2",        .clock),
            ("224.0.0.251",     5353, "mDNS",         .discovery),
            ("239.255.255.250", 1900, "SSDP",         .discovery),
            ("224.2.127.254",   9875, "SAP/SDP",      .discovery),
            ("239.255.0.12",    5568, "sACN (E1.31)", .lighting),
            ("239.255.1.1",     6454, "Art-Net",      .lighting),
            ("239.255.10.20",   4321, "Dante",        .audio),
            ("239.255.255.250", 3702, "WS-Discovery", .discovery),
            ("239.255.255.253", 427,  "SLP",          .discovery),
            ("224.0.0.252",     5355, "LLMNR",        .discovery),
        ]
        for (group, port, expectedName, expectedFamily) in cases {
            let identity = classify(group, port: port)
            XCTAssertEqual(identity.name, expectedName, "\(group):\(port)")
            XCTAssertEqual(identity.family, expectedFamily, "\(group):\(port)")
            XCTAssertEqual(identity.confidence, .certain, "\(group):\(port) should be certain")
        }
    }

    // MARK: - Port-pinned, likely

    func testLikelyPortAssignments() {
        let cases: [(UInt16, String, ProtocolFamily)] = [
            (5004, "RTP",   .audio),
            (5006, "RTP",   .audio),
            (5005, "RTCP",  .audio),
            (8700, "Dante", .control),
            (8704, "Dante", .control),
            (8708, "Dante", .control),
            (8800, "Dante", .clock),
            (2048, "Q-SYS", .audio),
        ]
        for (port, expectedName, expectedFamily) in cases {
            let identity = classify("239.69.1.1", port: port)
            XCTAssertEqual(identity.name, expectedName, "port \(port)")
            XCTAssertEqual(identity.family, expectedFamily, "port \(port)")
            XCTAssertEqual(identity.confidence, .likely, "port \(port) should be likely, not certain")
        }
        // Just outside the Dante control block.
        XCTAssertNotEqual(classify("239.69.1.1", port: 8709).name, "Dante")
        XCTAssertNotEqual(classify("239.69.1.1", port: 8699).name, "Dante")
    }

    // MARK: - Well-known addresses

    func testWellKnownAddresses() {
        let cases: [(String, String)] = [
            ("224.0.0.1",   "All hosts"),
            ("224.0.0.2",   "All routers"),
            ("224.0.0.13",  "PIM"),
            ("224.0.0.18",  "VRRP"),
            ("224.0.0.22",  "IGMPv3"),
            ("224.0.0.102", "HSRPv2/GLBP"),
            ("224.0.0.107", "PTPv2"),
            ("224.0.0.251", "mDNS"),
            ("224.0.0.252", "LLMNR"),
            ("224.0.1.1",   "NTP"),
            ("239.255.255.250", "SSDP"),
            ("239.255.255.253", "SLP"),
        ]
        for (group, expected) in cases {
            // No port: the address alone has to carry it.
            let identity = classify(group, port: nil)
            XCTAssertEqual(identity.name, expected, group)
            XCTAssertEqual(identity.confidence, .certain, "\(group) is an IANA assignment")
        }
    }

    func testPTPDomainAddresses() {
        for domain in 0...3 {
            let identity = classify("224.0.1.\(129 + domain)", port: nil)
            XCTAssertEqual(identity.name, "PTPv2")
            XCTAssertEqual(identity.detail, "Domain \(domain)")
            XCTAssertEqual(identity.family, .clock)
        }
    }

    // MARK: - Ranges, most specific wins

    func testRangesMostSpecificWins() {
        // 239.69.0.0/16 must beat 239.0.0.0/8.
        let aes67 = classify("239.69.1.2", port: nil)
        XCTAssertEqual(aes67.name, "AES67")
        XCTAssertEqual(aes67.confidence, .likely)

        // 239.192.0.0/14 must beat 239.0.0.0/8, and stops at 239.195.255.255.
        XCTAssertEqual(classify("239.192.0.1", port: nil).name, "Organisation-local scope")
        XCTAssertEqual(classify("239.195.255.255", port: nil).name, "Organisation-local scope")
        XCTAssertEqual(classify("239.196.0.1", port: nil).name, "Administratively scoped")

        XCTAssertEqual(classify("224.0.0.99", port: nil).name, "Link-local control")
        XCTAssertEqual(classify("224.0.1.50", port: nil).name, "Internetwork control")
        XCTAssertEqual(classify("224.2.1.1", port: nil).name, "SAP/SDP")
        XCTAssertEqual(classify("232.1.2.3", port: nil).name, "Source-specific multicast")
        XCTAssertEqual(classify("233.1.2.3", port: nil).name, "GLOP")
        XCTAssertEqual(classify("239.1.2.3", port: nil).name, "Administratively scoped")
    }

    /// The one the brief calls out: 239.255.0.0/16 is shared by Dante, NDI and
    /// sACN, so range alone must never produce a confident label there.
    func testSharedSiteLocalRangeIsNeverConfidentOnRangeAlone() {
        let identity = classify("239.255.0.12", port: nil)
        XCTAssertEqual(identity.confidence, .guess)
        XCTAssertEqual(identity.family, .unknown)
        XCTAssertNotEqual(identity.name, "sACN (E1.31)")
        XCTAssertNotEqual(identity.name, "Dante")
        XCTAssertNotEqual(identity.name, "NDI")

        // The same address with a port becomes certain.
        XCTAssertEqual(classify("239.255.0.12", port: 5568).name, "sACN (E1.31)")
        XCTAssertEqual(classify("239.255.0.12", port: 4321).name, "Dante")
    }

    func testUnidentifiedOutsideEveryRange() {
        let identity = classify("225.1.2.3", port: 44444)
        XCTAssertEqual(identity.name, "Unidentified")
        XCTAssertEqual(identity.family, .unknown)
        XCTAssertEqual(identity.confidence, .guess)
    }

    // MARK: - Source-port fallback

    func testSourcePortIsWeakerEvidenceThanDestinationPort() {
        // Destination port is unassigned; source port 5568 still says sACN,
        // but one confidence step down.
        let identity = classify("239.255.0.12", port: 49152, sourcePort: 5568)
        XCTAssertEqual(identity.name, "sACN (E1.31)")
        XCTAssertEqual(identity.confidence, .likely, "a source-port match is weaker than a destination-port match")
    }

    // MARK: - sACN universe decode

    func testSACNUniverseDecode() {
        XCTAssertEqual(classify("239.255.0.12", port: 5568).detail, "Universe 12")
        XCTAssertEqual(classify("239.255.0.1", port: 5568).detail, "Universe 1")
        XCTAssertEqual(classify("239.255.1.0", port: 5568).detail, "Universe 256")
        XCTAssertEqual(classify("239.255.1.1", port: 5568).detail, "Universe 257")
        XCTAssertEqual(classify("239.255.3.232", port: 5568).detail, "Universe 1000")
    }

    func testSACNUniverseRangeBoundaries() {
        // Universe 0 does not exist: 239.255.0.0 is not a universe.
        XCTAssertNil(StreamClassifier.sACNUniverse(for: IPv4Address("239.255.0.0")!))
        // First valid.
        XCTAssertEqual(StreamClassifier.sACNUniverse(for: IPv4Address("239.255.0.1")!), 1)
        // Last valid: 249 * 256 + 255 = 63999.
        XCTAssertEqual(StreamClassifier.sACNUniverse(for: IPv4Address("239.255.249.255")!), 63999)
        // One past the end.
        XCTAssertNil(StreamClassifier.sACNUniverse(for: IPv4Address("239.255.250.0")!))
        XCTAssertNil(StreamClassifier.sACNUniverse(for: IPv4Address("239.255.255.255")!))
        // Outside 239.255.0.0/16 entirely.
        XCTAssertNil(StreamClassifier.sACNUniverse(for: IPv4Address("239.254.0.12")!))
        XCTAssertNil(StreamClassifier.sACNUniverse(for: IPv4Address("239.69.0.12")!))
    }

    func testSACNGroupRoundTrip() {
        for universe in [1, 12, 255, 256, 257, 1000, 32767, 63999] {
            let group = StreamClassifier.sACNGroup(forUniverse: universe)
            XCTAssertNotNil(group, "universe \(universe)")
            XCTAssertEqual(StreamClassifier.sACNUniverse(for: group!), universe)
        }
        XCTAssertNil(StreamClassifier.sACNGroup(forUniverse: 0))
        XCTAssertNil(StreamClassifier.sACNGroup(forUniverse: 64000))
        XCTAssertNil(StreamClassifier.sACNGroup(forUniverse: -1))
    }

    /// sACN on a port that says sACN but an address outside 239.255/16 is still
    /// sACN -- there is just no universe to read out of the address.
    func testSACNOutsideStandardRangeHasNoUniverse() {
        let identity = classify("239.192.0.5", port: 5568)
        XCTAssertEqual(identity.name, "sACN (E1.31)")
        XCTAssertEqual(identity.confidence, .certain)
        XCTAssertNil(identity.detail)
    }

    // MARK: - IGMP

    func testIGMPProtocolIsIdentifiedByIPProtocolNumber() {
        let identity = StreamClassifier.classify(destination: IPv4Address("224.0.0.22")!,
                                                 destinationPort: nil, sourcePort: nil,
                                                 protocolNumber: IPProtocol.igmp)
        XCTAssertEqual(identity.name, "IGMP")
        XCTAssertEqual(identity.family, .routing)
    }

    // MARK: - End to end from a real frame

    func testClassifiesAParsedFrame() throws {
        let parser = PacketParser()
        let frame = FrameBuilder.udpFrame(source: "10.10.1.50", destination: "239.255.0.12",
                                          sourcePort: 5568, destinationPort: 5568,
                                          ttl: 16, payloadLength: 638)
        let packet = try XCTUnwrap(parser.parse(frame, timestamp: 100))
        let identity = StreamClassifier.classify(packet)
        XCTAssertEqual(identity.displayText, "sACN (E1.31) \u{00B7} Universe 12")
        XCTAssertEqual(identity.confidence, .certain)
    }
}
