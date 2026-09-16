import XCTest
import MulticastCore

final class QuerierTests: XCTestCase {
    func testSingleQuerierIsReportedAsFine() throws {
        let tracker = QuerierTracker()
        tracker.record(source: IPv4Address("10.10.1.1")!, isGeneralQuery: true, at: 100)
        let diagnostics = tracker.diagnostics(now: 110, captureStarted: 0)
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics[0].severity, .info)
        XCTAssertEqual(tracker.active(now: 110).count, 1)
    }

    /// The headline diagnostic: two queriers flush membership tables
    /// unpredictably, which is exactly the irreproducible dropout case.
    func testTwoQueriersIsCritical() throws {
        let tracker = QuerierTracker()
        tracker.record(source: IPv4Address("10.10.1.1")!, isGeneralQuery: true, at: 100)
        tracker.record(source: IPv4Address("10.10.1.2")!, isGeneralQuery: true, at: 105)
        let diagnostics = tracker.diagnostics(now: 110, captureStarted: 0)
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics[0].severity, .critical)
        XCTAssertEqual(diagnostics[0].id, "querier.multiple")
        XCTAssertTrue(diagnostics[0].title.contains("2 IGMP queriers"))
        XCTAssertTrue(diagnostics[0].detail.contains("10.10.1.1"))
        XCTAssertTrue(diagnostics[0].detail.contains("10.10.1.2"))
    }

    func testStaleQuerierStopsCounting() {
        let tracker = QuerierTracker(activeWindow: 260)
        tracker.record(source: IPv4Address("10.10.1.1")!, isGeneralQuery: true, at: 100)
        tracker.record(source: IPv4Address("10.10.1.2")!, isGeneralQuery: true, at: 500)
        // 10.10.1.1 was last heard 400s ago; only one querier is active now.
        let diagnostics = tracker.diagnostics(now: 500, captureStarted: 0)
        XCTAssertEqual(diagnostics[0].severity, .info)
        XCTAssertEqual(tracker.active(now: 500).count, 1)
    }

    func testNoQuerierWarnsOnlyAfterTheGracePeriod() {
        let tracker = QuerierTracker(silenceGrace: 130)
        XCTAssertTrue(tracker.diagnostics(now: 100, captureStarted: 0).isEmpty,
                      "too early to complain")
        let late = tracker.diagnostics(now: 200, captureStarted: 0)
        XCTAssertEqual(late.count, 1)
        XCTAssertEqual(late[0].severity, .warning)
        XCTAssertEqual(late[0].id, "querier.none")
    }

    /// A switch acting as querier sends from 0.0.0.0. Two of them must not
    /// collapse into one entry, or the duplicate-querier fault -- the whole
    /// point of this panel -- stays invisible.
    func testTwoAddresslessSwitchQueriersAreStillTwoQueriers() {
        let tracker = QuerierTracker()
        let first = MACAddress(parsing: "00:1d:c1:aa:00:01")!
        let second = MACAddress(parsing: "00:1d:c1:aa:00:02")!
        tracker.record(source: .unspecified, sourceMAC: first, isGeneralQuery: true, at: 100)
        tracker.record(source: .unspecified, sourceMAC: second, isGeneralQuery: true, at: 101)

        XCTAssertEqual(tracker.active(now: 110).count, 2)
        let diagnostics = tracker.diagnostics(now: 110, captureStarted: 0)
        XCTAssertEqual(diagnostics[0].severity, .critical)
        XCTAssertTrue(diagnostics[0].detail.contains("00:1d:c1:aa:00:01"))
        XCTAssertTrue(diagnostics[0].detail.contains("00:1d:c1:aa:00:02"))
    }

    func testSameSwitchQueryingRepeatedlyIsStillOneQuerier() {
        let tracker = QuerierTracker()
        let mac = MACAddress(parsing: "00:1d:c1:aa:00:01")!
        for time in [100.0, 225.0, 350.0] {
            tracker.record(source: .unspecified, sourceMAC: mac, isGeneralQuery: true, at: time)
        }
        XCTAssertEqual(tracker.active(now: 360).count, 1)
        XCTAssertEqual(tracker.diagnostics(now: 360, captureStarted: 0)[0].severity, .info)
    }

    func testAddresslessQuerierIsNamedUsefully() throws {
        let tracker = QuerierTracker()
        let mac = MACAddress(parsing: "00:1d:c1:aa:00:01")!
        tracker.record(source: .unspecified, sourceMAC: mac, isGeneralQuery: true, at: 100)
        let record = try XCTUnwrap(tracker.active(now: 110).first)
        XCTAssertTrue(record.isAddresslessSwitch)
        XCTAssertEqual(record.displayName, "0.0.0.0 via 00:1d:c1:aa:00:01")

        let diagnostic = tracker.diagnostics(now: 110, captureStarted: 0)[0]
        XCTAssertTrue(diagnostic.detail.contains("switch acting as querier"))
    }

    func testRouterQuerierIsNamedByItsAddress() throws {
        let tracker = QuerierTracker()
        tracker.record(source: IPv4Address("10.10.1.1")!, sourceMAC: nil, isGeneralQuery: true, at: 100)
        let record = try XCTUnwrap(tracker.active(now: 110).first)
        XCTAssertFalse(record.isAddresslessSwitch)
        XCTAssertEqual(record.displayName, "10.10.1.1")
    }

    /// The case that made this wrong in the field: a capture on a trunk sees
    /// every VLAN's querier at once. Ten healthy VLANs are ten queriers in the
    /// capture and must not be reported as ten competing queriers.
    func testOneQuerierPerVLANOnATrunkIsHealthy() {
        let tracker = QuerierTracker()
        let queriers: [(String, UInt16)] = [
            ("192.0.2.1", 10), ("192.0.2.129", 20), ("198.51.100.1", 30),
            ("198.51.100.129", 40), ("203.0.113.1", 50),
        ]
        for (address, vlan) in queriers {
            tracker.record(source: IPv4Address(address)!, vlan: vlan, isGeneralQuery: true, at: 100)
        }
        let diagnostics = tracker.diagnostics(now: 110, captureStarted: 0)
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics[0].severity, .info, "one per VLAN is healthy, however many VLANs")
        XCTAssertTrue(diagnostics[0].title.contains("5 VLANs"))
    }

    /// Two queriers on the *same* VLAN is still the fault we are hunting, even
    /// when other VLANs are healthy.
    func testTwoQueriersOnOneVLANIsStillCritical() {
        let tracker = QuerierTracker()
        tracker.record(source: IPv4Address("192.0.2.1")!, vlan: 10, isGeneralQuery: true, at: 100)
        tracker.record(source: IPv4Address("198.51.100.1")!, vlan: 20, isGeneralQuery: true, at: 100)
        tracker.record(source: IPv4Address("198.51.100.9")!, vlan: 20, isGeneralQuery: true, at: 101)

        let diagnostics = tracker.diagnostics(now: 110, captureStarted: 0)
        XCTAssertEqual(diagnostics[0].severity, .critical)
        XCTAssertTrue(diagnostics[0].title.contains("VLAN 20"))
        XCTAssertTrue(diagnostics[0].detail.contains("198.51.100.1"))
        XCTAssertTrue(diagnostics[0].detail.contains("198.51.100.9"))
        XCTAssertFalse(diagnostics[0].detail.contains("192.0.2.1"),
                       "the healthy VLAN should not be named as part of the fault")
    }

    func testSameAddressOnTwoVLANsIsTwoQueriersNotOne() {
        // A router doing inter-VLAN routing uses the same address on several
        // VLANs. Each is that VLAN's one querier.
        let tracker = QuerierTracker()
        tracker.record(source: IPv4Address("10.0.0.1")!, vlan: 10, isGeneralQuery: true, at: 100)
        tracker.record(source: IPv4Address("10.0.0.1")!, vlan: 20, isGeneralQuery: true, at: 100)
        XCTAssertEqual(tracker.active(now: 110).count, 2)
        XCTAssertEqual(tracker.diagnostics(now: 110, captureStarted: 0)[0].severity, .info)
    }

    func testQueryCountIsPluralisedProperly() {
        let tracker = QuerierTracker()
        tracker.record(source: IPv4Address("10.0.0.1")!, vlan: 10, isGeneralQuery: true, at: 100)
        tracker.record(source: IPv4Address("10.0.0.2")!, vlan: 10, isGeneralQuery: true, at: 100)
        let detail = tracker.diagnostics(now: 110, captureStarted: 0)[0].detail
        XCTAssertTrue(detail.contains("1 query"))
        XCTAssertFalse(detail.contains("1 queries"))
    }

    func testQueryCountsAccumulate() throws {
        let tracker = QuerierTracker()
        let address = IPv4Address("10.10.1.1")!
        tracker.record(source: address, isGeneralQuery: true, at: 100)
        tracker.record(source: address, isGeneralQuery: false, at: 101)
        tracker.record(source: address, isGeneralQuery: true, at: 102)
        let record = try XCTUnwrap(tracker.active(now: 110).first)
        XCTAssertEqual(record.queryCount, 3)
        XCTAssertEqual(record.generalQueryCount, 2)
        XCTAssertEqual(record.firstSeen, 100)
        XCTAssertEqual(record.lastSeen, 102)
    }
}

final class IGMPLogTests: XCTestCase {
    private let sender = IPv4Address("10.10.1.50")!

    func testV2ReportAndLeaveBecomeJoinAndLeave() {
        let log = IGMPActivityLog()
        let group = IPv4Address("239.255.0.12")!
        let report = log.record(IGMPMessage(messageType: .v2Report, group: group, maxResponseCode: 0, records: []),
                                from: sender, at: 100)
        XCTAssertEqual(report.map(\.kind), [.join])
        let leave = log.record(IGMPMessage(messageType: .v2Leave, group: group, maxResponseCode: 0, records: []),
                               from: sender, at: 101)
        XCTAssertEqual(leave.map(\.kind), [.leave])
    }

    func testQueriesAreDistinguished() {
        let log = IGMPActivityLog()
        let general = log.record(IGMPMessage(messageType: .query, group: .unspecified, maxResponseCode: 100, records: []),
                                 from: sender, at: 100)
        XCTAssertEqual(general.map(\.kind), [.generalQuery])
        let specific = log.record(IGMPMessage(messageType: .query, group: IPv4Address("239.255.0.12")!,
                                              maxResponseCode: 100, records: []), from: sender, at: 101)
        XCTAssertEqual(specific.map(\.kind), [.groupQuery])
    }

    func testV3ReportProducesOneEventPerRecord() {
        let log = IGMPActivityLog()
        let message = IGMPMessage(messageType: .v3Report, group: .unspecified, maxResponseCode: 0, records: [
            IGMPGroupRecord(recordType: .changeToExclude, group: IPv4Address("239.255.0.12")!, sources: []),
            IGMPGroupRecord(recordType: .changeToInclude, group: IPv4Address("239.255.0.13")!, sources: []),
            IGMPGroupRecord(recordType: .blockOldSources, group: IPv4Address("239.255.0.14")!,
                            sources: [IPv4Address("10.0.0.9")!]),
        ])
        let events = log.record(message, from: sender, at: 100)
        XCTAssertEqual(events.map(\.kind), [.join, .leave, .partialWithdrawal])
        XCTAssertEqual(events[2].sources, [IPv4Address("10.0.0.9")!])
    }

    func testLogIsBoundedAndNewestFirst() {
        let log = IGMPActivityLog(capacity: 10)
        for index in 0..<50 {
            log.record(IGMPMessage(messageType: .v2Report, group: IPv4Address("239.0.0.\(index % 255)")!,
                                   maxResponseCode: 0, records: []), from: sender, at: Double(index))
        }
        XCTAssertEqual(log.count, 10)
        let recent = log.recent(limit: 100)
        XCTAssertEqual(recent.count, 10)
        XCTAssertEqual(recent[0].timestamp, 49, "newest first")
        XCTAssertEqual(recent[9].timestamp, 40)
    }

    func testEventsPerMinuteCountsOnlyTheLastSixtySeconds() {
        let log = IGMPActivityLog()
        for index in 0..<100 {
            log.record(IGMPMessage(messageType: .v2Report, group: IPv4Address("239.0.0.1")!,
                                   maxResponseCode: 0, records: []), from: sender, at: Double(index))
        }
        // Events at t=0..99; at now=100 only t=40..99 are within 60s.
        XCTAssertEqual(log.eventsPerMinute(now: 100), 60)
    }
}

final class TTLDiagnosticTests: XCTestCase {
    private func stream(group: String, ttl: UInt8, identity: StreamIdentity) -> StreamSnapshot {
        StreamSnapshot(key: StreamKey(source: IPv4Address("10.0.0.1")!, group: IPv4Address(group)!,
                                      destinationPort: 5568, protocolNumber: IPProtocol.udp),
                       identity: identity, bitsPerSecond: 1000, packetsPerSecond: 10,
                       ttl: ttl, ttlVaries: false, sparkline: [], firstSeen: 0, lastSeen: 0,
                       totalPackets: 1, totalBytes: 1, sawFragments: false)
    }

    private let sacn = StreamIdentity(name: "sACN (E1.31)", detail: "Universe 12", family: .lighting,
                                      confidence: .certain, reason: "")

    func testTTL1OnRoutableGroupIsWarned() throws {
        let diagnostic = try XCTUnwrap(TTLDiagnostics.diagnose(stream(group: "239.255.0.12", ttl: 1, identity: sacn)))
        XCTAssertEqual(diagnostic.severity, .warning)
        XCTAssertTrue(diagnostic.title.contains("TTL 1"))
    }

    func testHealthyTTLIsNotWarned() {
        XCTAssertNil(TTLDiagnostics.diagnose(stream(group: "239.255.0.12", ttl: 16, identity: sacn)))
        XCTAssertNil(TTLDiagnostics.diagnose(stream(group: "239.255.0.12", ttl: 255, identity: sacn)))
    }

    /// TTL 1 is correct on 224.0.0.0/24 -- that block is defined as link-local.
    func testLinkLocalControlIsNotWarned() {
        let mdns = StreamIdentity(name: "mDNS", detail: nil, family: .discovery, confidence: .certain, reason: "")
        XCTAssertNil(TTLDiagnostics.diagnose(stream(group: "224.0.0.251", ttl: 1, identity: mdns)))
        XCTAssertNil(TTLDiagnostics.diagnose(stream(group: "224.0.0.1", ttl: 1, identity: mdns)))
    }

    func testRoutingPlaneTrafficIsNotWarned() {
        let vrrp = StreamIdentity(name: "VRRP", detail: nil, family: .routing, confidence: .certain, reason: "")
        XCTAssertNil(TTLDiagnostics.diagnose(stream(group: "239.1.1.1", ttl: 1, identity: vrrp)))
    }

    /// PTP on 224.0.1.129 is normally sent with TTL 1 and kept inside one L2
    /// domain. Warning about it would mean a warning on every AV network.
    func testPTPWithTTL1IsInformationalNotAWarning() throws {
        let ptp = StreamIdentity(name: "PTPv2", detail: "Domain 0", family: .clock,
                                 confidence: .certain, reason: "")
        let diagnostic = try XCTUnwrap(TTLDiagnostics.diagnose(stream(group: "224.0.1.129", ttl: 1, identity: ptp)))
        XCTAssertEqual(diagnostic.severity, .info)
    }

    /// Audio and lighting are the cases that genuinely want routing, so those
    /// stay warnings.
    func testAudioAndLightingWithTTL1StayWarnings() throws {
        let aes67 = StreamIdentity(name: "RTP", detail: "AES67", family: .audio,
                                   confidence: .likely, reason: "")
        XCTAssertEqual(try XCTUnwrap(TTLDiagnostics.diagnose(stream(group: "239.69.1.1", ttl: 1, identity: aes67))).severity,
                       .warning)
        XCTAssertEqual(try XCTUnwrap(TTLDiagnostics.diagnose(stream(group: "239.255.0.12", ttl: 1, identity: sacn))).severity,
                       .warning)
    }

    func testTTLDiagnosticNamesThePortSoTwoStreamsAreDistinguishable() throws {
        // PTP event and general are separate streams on one group; their
        // findings must not read as duplicates of each other.
        let ptp = StreamIdentity(name: "Other", detail: nil, family: .clock, confidence: .certain, reason: "")
        let event = StreamSnapshot(key: StreamKey(source: IPv4Address("10.0.0.1")!,
                                                  group: IPv4Address("239.1.1.1")!,
                                                  destinationPort: 319, protocolNumber: IPProtocol.udp),
                                   identity: ptp, bitsPerSecond: 100, packetsPerSecond: 8, ttl: 1,
                                   ttlVaries: false, sparkline: [], firstSeen: 0, lastSeen: 0,
                                   totalPackets: 1, totalBytes: 1, sawFragments: false)
        let diagnostic = try XCTUnwrap(TTLDiagnostics.diagnose(event))
        XCTAssertTrue(diagnostic.title.contains("319"))
    }

    /// SSDP is in a routable range but is meant to stay local. Reported as
    /// information rather than a warning, so the panel does not cry wolf.
    func testDiscoveryProtocolsAreInformationalNotWarnings() throws {
        let ssdp = StreamIdentity(name: "SSDP", detail: nil, family: .discovery, confidence: .certain, reason: "")
        let diagnostic = try XCTUnwrap(TTLDiagnostics.diagnose(stream(group: "239.255.255.250", ttl: 1, identity: ssdp)))
        XCTAssertEqual(diagnostic.severity, .info)
    }
}

final class TTLSummaryTests: XCTestCase {
    private func stream(_ group: String, port: UInt16, ttl: UInt8, identity: StreamIdentity) -> StreamSnapshot {
        StreamSnapshot(key: StreamKey(source: IPv4Address("10.0.0.1")!, group: IPv4Address(group)!,
                                      destinationPort: port, protocolNumber: IPProtocol.udp),
                       identity: identity, bitsPerSecond: 100, packetsPerSecond: 1, ttl: ttl,
                       ttlVaries: false, sparkline: [], firstSeen: 0, lastSeen: 0,
                       totalPackets: 1, totalBytes: 1, sawFragments: false)
    }

    /// Twenty green "this is normal" banners push the findings that matter off
    /// the screen, so the expected ones collapse into a single line.
    func testExpectedTTL1NotesCollapseIntoOneLine() throws {
        let ssdp = StreamIdentity(name: "SSDP", detail: nil, family: .discovery, confidence: .certain, reason: "")
        let ptp = StreamIdentity(name: "PTPv2", detail: nil, family: .clock, confidence: .certain, reason: "")
        var streams: [StreamSnapshot] = []
        for index in 1...12 {
            streams.append(stream("239.255.255.250", port: UInt16(1900 + index), ttl: 1, identity: ssdp))
        }
        streams.append(stream("224.0.1.129", port: 319, ttl: 1, identity: ptp))

        let diagnostics = TTLDiagnostics.diagnose(streams)
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics[0].severity, .info)
        XCTAssertEqual(diagnostics[0].id, "ttl1.expected")
        XCTAssertTrue(diagnostics[0].title.contains("13 streams"))
        XCTAssertTrue(diagnostics[0].detail.contains("SSDP"))
        XCTAssertTrue(diagnostics[0].detail.contains("PTPv2"))
    }

    /// Warnings stay one per stream: each is a separate thing to go and fix.
    func testWarningsAreNotCollapsed() {
        let sacn = StreamIdentity(name: "sACN (E1.31)", detail: nil, family: .lighting,
                                  confidence: .certain, reason: "")
        let streams = [
            stream("239.255.0.12", port: 5568, ttl: 1, identity: sacn),
            stream("239.255.0.13", port: 5568, ttl: 1, identity: sacn),
        ]
        let diagnostics = TTLDiagnostics.diagnose(streams)
        XCTAssertEqual(diagnostics.filter { $0.severity == .warning }.count, 2)
    }

    func testHealthyStreamsProduceNoFindingsAtAll() {
        let sacn = StreamIdentity(name: "sACN (E1.31)", detail: nil, family: .lighting,
                                  confidence: .certain, reason: "")
        XCTAssertTrue(TTLDiagnostics.diagnose([stream("239.255.0.12", port: 5568, ttl: 16, identity: sacn)]).isEmpty)
    }
}

final class InterfaceAdviceTests: XCTestCase {
    private func interface(_ name: String, up: Bool = true, multicast: Bool = true,
                           loopback: Bool = false, wireless: Bool = false,
                           addresses: [String] = ["10.0.0.5"]) -> NetworkInterfaceInfo {
        NetworkInterfaceInfo(name: name, displayName: nil, isUp: up, supportsMulticast: multicast,
                             isLoopback: loopback, isWireless: wireless,
                             addresses: addresses.compactMap(IPv4Address.init), macAddress: nil)
    }

    func testInterfaceKinds() {
        XCTAssertEqual(InterfaceAdvice.kind(for: "awdl0"), .appleWirelessDirect)
        XCTAssertEqual(InterfaceAdvice.kind(for: "llw0"), .appleWirelessDirect)
        XCTAssertEqual(InterfaceAdvice.kind(for: "utun4"), .vpn)
        XCTAssertEqual(InterfaceAdvice.kind(for: "ipsec0"), .vpn)
        XCTAssertEqual(InterfaceAdvice.kind(for: "lo0"), .loopback)
        XCTAssertEqual(InterfaceAdvice.kind(for: "bridge0"), .virtual)
        XCTAssertEqual(InterfaceAdvice.kind(for: "en7"), .wired)
        XCTAssertEqual(InterfaceAdvice.kind(for: "en0", isWireless: true), .wireless)
    }

    func testNoisyInterfacesAreFlagged() {
        XCTAssertTrue(InterfaceAdvice.isNoiseInterface("awdl0"))
        XCTAssertTrue(InterfaceAdvice.isNoiseInterface("utun0"))
        XCTAssertTrue(InterfaceAdvice.isNoiseInterface("lo0"))
        XCTAssertFalse(InterfaceAdvice.isNoiseInterface("en5"))
    }

    func testAWDLWarningMentionsTheRealProblem() throws {
        let warning = try XCTUnwrap(InterfaceAdvice.warning(for: interface("awdl0")))
        XCTAssertTrue(warning.contains("buries real AV traffic"))
    }

    /// The AV network on a Mac is nearly always a Thunderbolt or USB adapter.
    func testDefaultPrefersAWiredInterfaceThatIsNotEN0() throws {
        let chosen = try XCTUnwrap(InterfaceAdvice.preferredInterface(from: [
            interface("lo0", loopback: true),
            interface("awdl0"),
            interface("en0", wireless: true),
            interface("en7"),
            interface("utun3"),
        ]))
        XCTAssertEqual(chosen.name, "en7")
    }

    func testFallsBackToEN0WhenItIsTheOnlyWiredInterface() throws {
        let chosen = try XCTUnwrap(InterfaceAdvice.preferredInterface(from: [
            interface("lo0", loopback: true),
            interface("awdl0"),
            interface("en0"),
        ]))
        XCTAssertEqual(chosen.name, "en0")
    }

    func testDownInterfacesAreNotChosen() {
        XCTAssertNil(InterfaceAdvice.preferredInterface(from: [
            interface("en7", up: false),
            interface("en8", multicast: false),
            interface("lo0", loopback: true),
        ]))
    }
}
