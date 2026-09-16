import XCTest
import MulticastCore

final class IGMPTests: XCTestCase {
    private var parser = PacketParser()

    override func setUp() { parser = PacketParser() }

    private func parseIGMP(_ payload: [UInt8], source: String = "10.10.1.1",
                           destination: String = "224.0.0.22") -> IGMPMessage? {
        let frame = FrameBuilder.igmpFrame(payload: payload, source: source, destination: destination)
        return parser.parse(frame, timestamp: 100)?.igmp
    }

    // MARK: - Queries

    func testGeneralQuery() throws {
        // A query naming 0.0.0.0 asks about every group.
        let message = try XCTUnwrap(parseIGMP(FrameBuilder.igmpV2(type: 0x11, group: .unspecified),
                                              destination: "224.0.0.1"))
        XCTAssertEqual(message.messageType, .query)
        XCTAssertTrue(message.isGeneralQuery)
        XCTAssertFalse(message.isGroupSpecificQuery)
    }

    func testGroupSpecificQuery() throws {
        let group = FrameBuilder.ip("239.255.0.12")
        let message = try XCTUnwrap(parseIGMP(FrameBuilder.igmpV2(type: 0x11, group: group),
                                              destination: "239.255.0.12"))
        XCTAssertTrue(message.isGroupSpecificQuery)
        XCTAssertFalse(message.isGeneralQuery)
        XCTAssertEqual(message.group, group)
    }

    func testReportAndLeaveTypes() throws {
        let group = FrameBuilder.ip("239.255.0.12")
        let cases: [(UInt8, IGMPMessageType)] = [
            (0x12, .v1Report), (0x16, .v2Report), (0x17, .v2Leave),
        ]
        for (raw, expected) in cases {
            let message = try XCTUnwrap(parseIGMP(FrameBuilder.igmpV2(type: raw, group: group)))
            XCTAssertEqual(message.messageType, expected)
            XCTAssertEqual(message.group, group)
        }
    }

    func testUnknownIGMPTypeIsRejected() {
        XCTAssertNil(parseIGMP(FrameBuilder.igmpV2(type: 0x30, group: FrameBuilder.ip("239.1.1.1"))))
    }

    func testTruncatedIGMPIsRejected() {
        XCTAssertNil(parseIGMP([0x11, 0x64, 0x00]))
        XCTAssertNil(parseIGMP([]))
    }

    // MARK: - v3 record types, all twelve combinations

    func testAllRecordTypeAndSourceCombinations() throws {
        let group = FrameBuilder.ip("239.255.0.12")
        let sources = [FrameBuilder.ip("10.10.1.50"), FrameBuilder.ip("10.10.1.51")]

        // recordType, hasSources, expected operator-facing action
        let expectations: [(UInt8, Bool, MembershipAction)] = [
            (1, false, .leave),              // INCLUDE {} -- only these sources, and there are none
            (1, true,  .join),               // INCLUDE {S} -- a source-specific join
            (2, false, .join),               // EXCLUDE {} -- everything except nothing
            (2, true,  .join),
            (3, false, .leave),              // CHANGE_TO_INCLUDE {}
            (3, true,  .join),
            (4, false, .join),               // CHANGE_TO_EXCLUDE {}
            (4, true,  .join),
            (5, false, .join),               // ALLOW_NEW_SOURCES
            (5, true,  .join),
            (6, false, .partialWithdrawal),  // BLOCK_OLD_SOURCES -- never a clean leave
            (6, true,  .partialWithdrawal),
        ]

        for (rawType, hasSources, expected) in expectations {
            let used = hasSources ? sources : []
            let record = FrameBuilder.groupRecord(type: rawType, group: group, sources: used)
            let message = try XCTUnwrap(parseIGMP(FrameBuilder.igmpV3Report(records: [record])),
                                        "type \(rawType) sources=\(hasSources)")
            XCTAssertEqual(message.records.count, 1, "type \(rawType) sources=\(hasSources)")
            let parsed = message.records[0]
            XCTAssertEqual(parsed.recordType.rawValue, rawType)
            XCTAssertEqual(parsed.group, group)
            XCTAssertEqual(parsed.sources, used)
            XCTAssertEqual(parsed.action, expected,
                           "record type \(rawType) with sources=\(hasSources) should be \(expected)")
        }
    }

    func testUnknownRecordTypeIsSkippedNotFatal() throws {
        let group = FrameBuilder.ip("239.255.0.12")
        let unknown = FrameBuilder.groupRecord(type: 9, group: group, sources: [])
        let known = FrameBuilder.groupRecord(type: 2, group: FrameBuilder.ip("239.255.0.13"), sources: [])
        let message = try XCTUnwrap(parseIGMP(FrameBuilder.igmpV3Report(records: [unknown, known])))
        // The unknown record is stepped over using its length fields, and the
        // record after it still parses.
        XCTAssertEqual(message.records.count, 1)
        XCTAssertEqual(message.records[0].group, FrameBuilder.ip("239.255.0.13"))
    }

    // MARK: - Aux data

    func testAuxDataIsSkippedInWords() throws {
        // Aux length is in 32-bit words. Treating it as bytes would leave the
        // cursor 3/4 of the way into the aux data and desynchronise everything
        // after it.
        let first = FrameBuilder.groupRecord(type: 4, group: FrameBuilder.ip("239.255.0.12"),
                                             sources: [], auxWords: 3)
        let second = FrameBuilder.groupRecord(type: 4, group: FrameBuilder.ip("239.255.0.13"),
                                              sources: [FrameBuilder.ip("10.0.0.9")], auxWords: 1)
        let third = FrameBuilder.groupRecord(type: 3, group: FrameBuilder.ip("239.255.0.14"), sources: [])

        let message = try XCTUnwrap(parseIGMP(FrameBuilder.igmpV3Report(records: [first, second, third])))
        XCTAssertEqual(message.records.count, 3)
        XCTAssertEqual(message.records[0].group, FrameBuilder.ip("239.255.0.12"))
        XCTAssertEqual(message.records[1].group, FrameBuilder.ip("239.255.0.13"))
        XCTAssertEqual(message.records[1].sources, [FrameBuilder.ip("10.0.0.9")])
        XCTAssertEqual(message.records[2].group, FrameBuilder.ip("239.255.0.14"))
        XCTAssertEqual(message.records[2].action, .leave)
        XCTAssertFalse(message.recordCountWasOverstated)
    }

    func testSourcesAndAuxTogether() throws {
        let sources = (1...4).map { FrameBuilder.ip("10.0.0.\($0)") }
        let record = FrameBuilder.groupRecord(type: 2, group: FrameBuilder.ip("239.192.0.1"),
                                              sources: sources, auxWords: 2)
        let trailing = FrameBuilder.groupRecord(type: 6, group: FrameBuilder.ip("239.192.0.2"),
                                                sources: [FrameBuilder.ip("10.0.0.99")])
        let message = try XCTUnwrap(parseIGMP(FrameBuilder.igmpV3Report(records: [record, trailing])))
        XCTAssertEqual(message.records.count, 2)
        XCTAssertEqual(message.records[0].sources, sources)
        XCTAssertEqual(message.records[1].group, FrameBuilder.ip("239.192.0.2"))
        XCTAssertEqual(message.records[1].action, .partialWithdrawal)
    }

    // MARK: - A report that lies

    func testReportClaimingMoreRecordsThanItCarries() throws {
        let record = FrameBuilder.groupRecord(type: 2, group: FrameBuilder.ip("239.255.0.12"), sources: [])
        // Two real records, header claims nine.
        let payload = FrameBuilder.igmpV3Report(records: [record, record], claimedCount: 9)
        let message = try XCTUnwrap(parseIGMP(payload))
        XCTAssertEqual(message.records.count, 2, "must stop at the end of the packet, not at the claimed count")
        XCTAssertTrue(message.recordCountWasOverstated)
    }

    func testRecordClaimingMoreSourcesThanItCarries() throws {
        var record: [UInt8] = [2, 0]
        record += FrameBuilder.bigEndian16(50)      // claims 50 sources
        record += FrameBuilder.addressBytes(FrameBuilder.ip("239.255.0.12"))
        record += FrameBuilder.addressBytes(FrameBuilder.ip("10.0.0.1"))   // supplies one
        let message = try XCTUnwrap(parseIGMP(FrameBuilder.igmpV3Report(records: [record])))
        XCTAssertEqual(message.records.count, 0, "a record that runs past the packet is not usable")
        XCTAssertTrue(message.recordCountWasOverstated)
    }

    func testZeroRecordReportIsValid() throws {
        let message = try XCTUnwrap(parseIGMP(FrameBuilder.igmpV3Report(records: [])))
        XCTAssertEqual(message.messageType, .v3Report)
        XCTAssertTrue(message.records.isEmpty)
        XCTAssertFalse(message.recordCountWasOverstated)
    }

    func testEthernetPaddingDoesNotInventRecords() throws {
        // Short IGMP messages get padded to the 60-byte Ethernet minimum. The
        // IP total length is what bounds the parse, not the captured bytes.
        let record = FrameBuilder.groupRecord(type: 2, group: FrameBuilder.ip("239.255.0.12"), sources: [])
        let payload = FrameBuilder.igmpV3Report(records: [record])
        let packet = FrameBuilder.ipv4(source: FrameBuilder.ip("10.10.1.1"),
                                       destination: FrameBuilder.ip("224.0.0.22"),
                                       protocolNumber: IPProtocol.igmp, ttl: 1, payload: payload)
        var frame = FrameBuilder.ethernet(destination: FrameBuilder.mac("01:00:5e:00:00:16"),
                                          source: FrameBuilder.mac("00:1d:c1:aa:bb:cc"),
                                          payload: packet)
        frame += [UInt8](repeating: 0x02, count: 24)   // padding that looks like a record type

        let message = try XCTUnwrap(parser.parse(frame, timestamp: 100)?.igmp)
        XCTAssertEqual(message.records.count, 1)
        XCTAssertFalse(message.recordCountWasOverstated)
    }
}
