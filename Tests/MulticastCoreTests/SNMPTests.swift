import XCTest
import MulticastCore

final class BERIntegerTests: XCTestCase {
    /// Minimal-length two's complement, across the 0x80 boundary in both
    /// directions. The leading 0x00 in front of a large positive and the
    /// leading 0xFF in front of a negative both fall out of the same rule.
    func testIntegerEncodingAcrossTheSignBoundary() {
        let cases: [(Int, [UInt8])] = [
            (0,      [0x00]),
            (1,      [0x01]),
            (127,    [0x7F]),        // largest that fits without a pad byte
            (128,    [0x00, 0x80]),  // needs the 0x00 or it reads as -128
            (129,    [0x00, 0x81]),
            (255,    [0x00, 0xFF]),
            (256,    [0x01, 0x00]),
            (32767,  [0x7F, 0xFF]),
            (32768,  [0x00, 0x80, 0x00]),
            (65535,  [0x00, 0xFF, 0xFF]),
            (-1,     [0xFF]),
            (-2,     [0xFE]),
            (-127,   [0x81]),
            (-128,   [0x80]),        // fits in one byte
            (-129,   [0xFF, 0x7F]),  // needs the 0xFF pad
            (-256,   [0xFF, 0x00]),
            (-32768, [0x80, 0x00]),
            (-32769, [0xFF, 0x7F, 0xFF]),
        ]
        for (value, expected) in cases {
            XCTAssertEqual(BER.encodeIntegerBody(value), expected, "encoding \(value)")
        }
    }

    func testIntegerRoundTrip() throws {
        for value in [0, 1, 127, 128, 255, 256, 32767, 32768, 1 << 30,
                      -1, -128, -129, -32768, -32769, -(1 << 30)] {
            let encoded = BER.encodeIntegerBody(value)
            XCTAssertEqual(try BER.decodeIntegerBody(encoded), value, "round trip \(value)")
        }
    }

    func testFullIntegerTLV() {
        XCTAssertEqual(BER.encodeInteger(128), [0x02, 0x02, 0x00, 0x80])
        XCTAssertEqual(BER.encodeInteger(-1), [0x02, 0x01, 0xFF])
    }

    func testLengthEncodingAcrossTheShortFormBoundary() {
        XCTAssertEqual(BER.encodeLength(0), [0x00])
        XCTAssertEqual(BER.encodeLength(127), [0x7F])       // last short form
        XCTAssertEqual(BER.encodeLength(128), [0x81, 0x80]) // first long form
        XCTAssertEqual(BER.encodeLength(255), [0x81, 0xFF])
        XCTAssertEqual(BER.encodeLength(256), [0x82, 0x01, 0x00])
        XCTAssertEqual(BER.encodeLength(65536), [0x83, 0x01, 0x00, 0x00])
    }

    func testTruncatedInputIsRejectedNotCrashed() {
        XCTAssertThrowsError(try BER.readElement([], at: 0))
        XCTAssertThrowsError(try BER.readElement([0x02], at: 0))
        XCTAssertThrowsError(try BER.readElement([0x02, 0x05, 0x01], at: 0))
        XCTAssertThrowsError(try BER.readElement([0x02, 0x84, 0x01], at: 0))
    }
}

final class BEROIDTests: XCTestCase {
    /// Base-128 subidentifiers, and the boundary where a second byte appears.
    func testSubidentifierEncodingAcrossTheBase128Boundary() {
        let cases: [(UInt32, [UInt8])] = [
            (0,     [0x00]),
            (1,     [0x01]),
            (127,   [0x7F]),              // last single byte
            (128,   [0x81, 0x00]),        // first two-byte value
            (129,   [0x81, 0x01]),
            (255,   [0x81, 0x7F]),
            (256,   [0x82, 0x00]),
            (16383, [0xFF, 0x7F]),        // last two-byte value
            (16384, [0x81, 0x80, 0x00]),  // first three-byte value
            (2097151, [0xFF, 0xFF, 0x7F]),
            (2097152, [0x81, 0x80, 0x80, 0x00]),
        ]
        for (value, expected) in cases {
            XCTAssertEqual(BER.encodeSubidentifier(value), expected, "encoding \(value)")
        }
    }

    func testQBridgeTableOIDEncoding() {
        // 1.3.6.1.2.1.17.7.1.2.3.1.2 -- the first two arcs pack into 0x2B.
        let encoded = BER.encodeOIDBody(QBridgeMIB.groupEgressPorts)
        XCTAssertEqual(encoded, [0x2B, 0x06, 0x01, 0x02, 0x01, 0x11, 0x07, 0x01, 0x02, 0x03, 0x01, 0x02])
    }

    func testOIDWithLargeArcRoundTrips() throws {
        // The Cisco enterprise branch has arcs above 127.
        for oid in [QBridgeMIB.groupEgressPorts, QBridgeMIB.ciscoGroupEgressPorts,
                    OID("1.3.6.1.4.1.9.9.393.1.3.1.1.3.1.1.0.94.0.1.12")!,
                    OID("1.3.6.1.2.1.17.7.1.2.3.1.2.120.1.0.94.127.0.12")!] {
            let body = BER.encodeOIDBody(oid)
            XCTAssertEqual(try BER.decodeOIDBody(body), oid, "round trip \(oid)")
        }
    }

    func testOIDOrdering() {
        // Lexicographic, and a prefix sorts before anything extending it.
        XCTAssertTrue(OID("1.3.6.1.2")! < OID("1.3.6.1.3")!)
        XCTAssertTrue(OID("1.3.6.1.2")! < OID("1.3.6.1.2.1")!)
        XCTAssertTrue(OID("1.3.6.1.2.1.9")! < OID("1.3.6.1.2.1.10")!,
                      "9 < 10 numerically, not as strings")
        XCTAssertFalse(OID("1.3.6.1.3")! < OID("1.3.6.1.2")!)
    }

    func testSubtreeContainment() {
        let table = QBridgeMIB.groupEgressPorts
        XCTAssertTrue(OID("1.3.6.1.2.1.17.7.1.2.3.1.2.120.1.0.94.0.0.12")!.isWithin(table))
        XCTAssertTrue(table.isWithin(table))
        XCTAssertFalse(OID("1.3.6.1.2.1.17.7.1.2.3.1.3.120")!.isWithin(table))
        XCTAssertFalse(OID("1.3.6.1.2.1.17")!.isWithin(table))
    }

    func testMalformedOIDIsRejected() {
        XCTAssertThrowsError(try BER.decodeOIDBody([]))
        XCTAssertThrowsError(try BER.decodeOIDBody([0x2B, 0x81]))   // ends mid-subidentifier
    }
}

final class PortListTests: XCTestCase {
    /// The off-by-eight guard. Bit 7 of byte 0 is port 1; byte 1 starts at
    /// port 9, not port 8.
    func testPortListBitmapBitOrder() {
        XCTAssertEqual(PortList.ports(from: [0x80]), [1], "MSB of byte 0 is port 1")
        XCTAssertEqual(PortList.ports(from: [0x40]), [2])
        XCTAssertEqual(PortList.ports(from: [0x01]), [8], "LSB of byte 0 is port 8")
        XCTAssertEqual(PortList.ports(from: [0x00, 0x80]), [9], "MSB of byte 1 is port 9, not port 8")
        XCTAssertEqual(PortList.ports(from: [0x00, 0x01]), [16])
        XCTAssertEqual(PortList.ports(from: [0x00, 0x00, 0x80]), [17])
        XCTAssertEqual(PortList.ports(from: [0xFF]), [1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(PortList.ports(from: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01]), [56])
    }

    func testRealisticMultiBytePortList() {
        // A 48-port switch with ports 1, 9, 24 and 48 in the group.
        let bitmap: [UInt8] = [0x80, 0x80, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]
        XCTAssertEqual(PortList.ports(from: bitmap), [1, 9, 32])
        XCTAssertEqual(PortList.ports(from: PortList.bitmap(for: [1, 9, 24, 48])), [1, 9, 24, 48])
    }

    func testEmptyBitmapMeansNoPorts() {
        XCTAssertEqual(PortList.ports(from: []), [])
        XCTAssertEqual(PortList.ports(from: [0x00, 0x00, 0x00]), [])
    }

    func testBitmapRoundTripAcrossByteBoundaries() {
        for ports in [[1], [8], [9], [16], [17], [1, 8, 9, 16, 17], [48], [1, 48]] {
            XCTAssertEqual(PortList.ports(from: PortList.bitmap(for: ports)), ports, "\(ports)")
        }
    }
}

final class QBridgeIndexTests: XCTestCase {
    func testIndexSplitsIntoVLANAndMAC() throws {
        // VLAN 120, MAC 01:00:5e:7f:00:0c
        let suffix: [UInt32] = [120, 1, 0, 94, 127, 0, 12]
        let parsed = try XCTUnwrap(QBridgeIndex.parse(suffix))
        XCTAssertEqual(parsed.vlan, 120)
        XCTAssertEqual(parsed.mac.description, "01:00:5e:7f:00:0c")
    }

    func testShortIndexIsRejected() {
        XCTAssertNil(QBridgeIndex.parse([120, 1, 0, 94, 127, 0]))
        XCTAssertNil(QBridgeIndex.parse([]))
    }

    func testIndexWithOutOfRangeOctetIsRejected() {
        XCTAssertNil(QBridgeIndex.parse([120, 1, 0, 94, 300, 0, 12]))
    }
}

final class SNMPMessageTests: XCTestCase {
    func testGetBulkRoundTripsThroughTheDecoder() throws {
        // Build a GetBulk, then hand-build the matching response and decode it.
        let request = SNMPMessage.encodeGetBulk(community: "public", requestID: 12345,
                                                maxRepetitions: 25,
                                                oids: [QBridgeMIB.groupEgressPorts])
        // Outermost element is a SEQUENCE and the PDU tag is GetBulk (0xA5).
        XCTAssertEqual(request[0], BERTag.sequence)
        XCTAssertTrue(request.contains(BERTag.getBulkRequest))

        let element = try BER.readElement(request, at: 0)
        XCTAssertEqual(element.end, request.count, "the envelope length must cover the whole message")
    }

    /// Hand-built response bytes, decoded end to end.
    func testDecodeResponseWithPortListBinding() throws {
        let oid = QBridgeMIB.groupEgressPorts.appending([120, 1, 0, 94, 127, 0, 12])
        let bitmap = PortList.bitmap(for: [3, 11], byteCount: 8)

        let binding = BER.encodeSequence(BER.encodeOID(oid) + BER.encodeOctetString(bitmap))
        var pdu: [UInt8] = []
        pdu += BER.encodeInteger(9876)
        pdu += BER.encodeInteger(0)
        pdu += BER.encodeInteger(0)
        pdu += BER.encodeSequence(binding)
        var message: [UInt8] = []
        message += BER.encodeInteger(1)
        message += BER.encodeOctetString("public")
        message += BER.encodeTLV(tag: BERTag.response, value: pdu)
        let bytes = BER.encodeSequence(message)

        let response = try SNMPMessage.decodeResponse(bytes)
        XCTAssertEqual(response.requestID, 9876)
        XCTAssertNil(response.error)
        XCTAssertEqual(response.bindings.count, 1)
        XCTAssertEqual(response.bindings[0].oid, oid)
        XCTAssertEqual(PortList.ports(from: try XCTUnwrap(response.bindings[0].value.octets)), [3, 11])

        let suffix = try XCTUnwrap(response.bindings[0].oid.suffix(after: QBridgeMIB.groupEgressPorts))
        let index = try XCTUnwrap(QBridgeIndex.parse(suffix))
        XCTAssertEqual(index.vlan, 120)
        XCTAssertEqual(index.mac.description, "01:00:5e:7f:00:0c")
    }

    func testDecodeResponseWithManyBindings() throws {
        var bindings: [UInt8] = []
        for port in 1...20 {
            let oid = QBridgeMIB.groupEgressPorts.appending([120, 1, 0, 94, 0, 0, UInt32(port)])
            bindings += BER.encodeSequence(BER.encodeOID(oid) + BER.encodeOctetString(PortList.bitmap(for: [port])))
        }
        var pdu: [UInt8] = []
        pdu += BER.encodeInteger(1)
        pdu += BER.encodeInteger(0)
        pdu += BER.encodeInteger(0)
        pdu += BER.encodeSequence(bindings)
        var message: [UInt8] = []
        message += BER.encodeInteger(1)
        message += BER.encodeOctetString("public")
        message += BER.encodeTLV(tag: BERTag.response, value: pdu)

        let response = try SNMPMessage.decodeResponse(BER.encodeSequence(message))
        XCTAssertEqual(response.bindings.count, 20)
    }

    func testDecodeEndOfMibViewMarker() throws {
        let oid = OID("1.3.6.1.2.1.17.7.1.2.3.1.3")!
        let binding = BER.encodeSequence(BER.encodeOID(oid) + [BERTag.endOfMibView, 0x00])
        var pdu: [UInt8] = []
        pdu += BER.encodeInteger(1) + BER.encodeInteger(0) + BER.encodeInteger(0)
        pdu += BER.encodeSequence(binding)
        var message: [UInt8] = []
        message += BER.encodeInteger(1) + BER.encodeOctetString("public")
        message += BER.encodeTLV(tag: BERTag.response, value: pdu)

        let response = try SNMPMessage.decodeResponse(BER.encodeSequence(message))
        XCTAssertEqual(response.bindings[0].value, .endOfMibView)
        XCTAssertTrue(response.bindings[0].value.isEndOfView)
    }

    func testAgentErrorIsSurfaced() throws {
        var pdu: [UInt8] = []
        pdu += BER.encodeInteger(1) + BER.encodeInteger(5) + BER.encodeInteger(1)
        pdu += BER.encodeSequence([])
        var message: [UInt8] = []
        message += BER.encodeInteger(1) + BER.encodeOctetString("public")
        message += BER.encodeTLV(tag: BERTag.response, value: pdu)

        let response = try SNMPMessage.decodeResponse(BER.encodeSequence(message))
        XCTAssertEqual(response.error, .genErr)
    }

    func testGarbageIsRejectedNotCrashed() {
        XCTAssertThrowsError(try SNMPMessage.decodeResponse([]))
        XCTAssertThrowsError(try SNMPMessage.decodeResponse([0x30, 0x05, 0x02, 0x01, 0x01]))
        XCTAssertThrowsError(try SNMPMessage.decodeResponse([UInt8](repeating: 0xFF, count: 64)))
    }
}

final class SNMPWalkTests: XCTestCase {
    private let table = QBridgeMIB.groupEgressPorts

    private func binding(_ oid: String, endOfView: Bool = false) -> VariableBinding {
        VariableBinding(oid: OID(oid)!, value: endOfView ? .endOfMibView : .octetString([0x80]))
    }

    func testWalkContinuesWithinTheSubtree() {
        let first = binding("1.3.6.1.2.1.17.7.1.2.3.1.2.120.1.0.94.0.0.1")
        XCTAssertEqual(SNMPWalk.evaluate(binding: first, subtree: table, previous: nil), .notFinished)
        let second = binding("1.3.6.1.2.1.17.7.1.2.3.1.2.120.1.0.94.0.0.2")
        XCTAssertEqual(SNMPWalk.evaluate(binding: second, subtree: table, previous: first.oid), .notFinished)
    }

    func testWalkStopsOnLeavingTheSubtree() {
        let outside = binding("1.3.6.1.2.1.17.7.1.2.3.1.3.120.1.0.94.0.0.1")
        XCTAssertEqual(SNMPWalk.evaluate(binding: outside, subtree: table, previous: nil), .leftSubtree)
    }

    func testWalkStopsOnEndOfMibView() {
        let marker = binding("1.3.6.1.2.1.17.7.1.2.3.1.2.120.1.0.94.0.0.9", endOfView: true)
        XCTAssertEqual(SNMPWalk.evaluate(binding: marker, subtree: table, previous: nil), .endOfMibView)
    }

    /// The infinite-loop guard: an agent that keeps returning the same OID, or
    /// an earlier one, must not keep the walk going forever.
    func testWalkStopsWhenTheAgentFailsToAdvance() {
        let same = binding("1.3.6.1.2.1.17.7.1.2.3.1.2.120.1.0.94.0.0.5")
        XCTAssertEqual(SNMPWalk.evaluate(binding: same, subtree: table, previous: same.oid), .didNotAdvance)

        let earlier = binding("1.3.6.1.2.1.17.7.1.2.3.1.2.120.1.0.94.0.0.4")
        XCTAssertEqual(SNMPWalk.evaluate(binding: earlier, subtree: table, previous: same.oid), .didNotAdvance)
    }
}
