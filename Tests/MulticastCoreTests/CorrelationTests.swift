import XCTest
import MulticastCore

final class MACCollisionTests: XCTestCase {
    /// The IPv4-to-Ethernet mapping keeps only the low 23 bits, so the top 5
    /// bits of the second octet are lost. 239.1.1.1 and 239.129.1.1 land on the
    /// same MAC, and a switch storing multicast by MAC cannot tell them apart.
    func testTwentyThreeBitCollision() {
        let a = IPv4Address("239.1.1.1")!
        let b = IPv4Address("239.129.1.1")!
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.ethernetMulticastMAC, b.ethernetMulticastMAC)
        XCTAssertEqual(a.ethernetMulticastMAC.description, "01:00:5e:01:01:01")
    }

    func testKnownMappings() {
        XCTAssertEqual(IPv4Address("224.0.0.1")!.ethernetMulticastMAC.description, "01:00:5e:00:00:01")
        XCTAssertEqual(IPv4Address("239.255.0.12")!.ethernetMulticastMAC.description, "01:00:5e:7f:00:0c")
        XCTAssertEqual(IPv4Address("224.0.0.251")!.ethernetMulticastMAC.description, "01:00:5e:00:00:fb")
        // The 24th bit of the group is dropped: 239.255.x and 239.127.x collide.
        XCTAssertEqual(IPv4Address("239.127.0.12")!.ethernetMulticastMAC,
                       IPv4Address("239.255.0.12")!.ethernetMulticastMAC)
    }

    func testEveryColliderMapsBack() {
        let mac = IPv4Address("239.255.0.12")!.ethernetMulticastMAC
        let candidates = mac.possibleGroups
        XCTAssertEqual(candidates.count, 32, "9 lost bits, but only 5 are free within 224/4")
        XCTAssertTrue(candidates.contains(IPv4Address("239.255.0.12")!))
        XCTAssertTrue(candidates.contains(IPv4Address("239.127.0.12")!))
        XCTAssertTrue(candidates.contains(IPv4Address("224.127.0.12")!))
        for candidate in candidates {
            XCTAssertEqual(candidate.ethernetMulticastMAC, mac)
            XCTAssertTrue(candidate.isMulticast)
        }
    }
}

final class ForwardingResolverTests: XCTestCase {
    private func row(_ group: String, ports: [Int], switchName: String = "core-sw", vlan: Int = 120) -> GroupForwarding {
        GroupForwarding(switchName: switchName, vlan: vlan,
                        mac: IPv4Address(group)!.ethernetMulticastMAC, ports: ports)
    }

    func testTrafficResolvesTheMACBackToARealGroup() throws {
        let rows = [row("239.255.0.12", ports: [3, 11])]
        let resolved = ForwardingResolver.resolve(rows, observedGroups: [IPv4Address("239.255.0.12")!])
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved[0].group, IPv4Address("239.255.0.12")!)
        XCTAssertFalse(resolved[0].inferred)
        XCTAssertFalse(resolved[0].ambiguous)
        XCTAssertEqual(resolved[0].portsText, "3, 11")
    }

    /// A subscription with no traffic behind it is a real symptom, so the row
    /// is still shown -- just marked as inferred.
    func testUnresolvedRowIsKeptButMarkedInferred() throws {
        let rows = [row("239.255.0.99", ports: [7])]
        let resolved = ForwardingResolver.resolve(rows, observedGroups: [])
        XCTAssertEqual(resolved.count, 1)
        XCTAssertNil(resolved[0].group)
        XCTAssertTrue(resolved[0].inferred)
        XCTAssertEqual(resolved[0].ports, [7])
    }

    func testTwoLiveGroupsOnOneMACAreMarkedAmbiguous() throws {
        let rows = [row("239.1.1.1", ports: [4])]
        let resolved = ForwardingResolver.resolve(rows, observedGroups: [
            IPv4Address("239.1.1.1")!, IPv4Address("239.129.1.1")!,
        ])
        XCTAssertEqual(resolved.count, 1)
        XCTAssertTrue(resolved[0].ambiguous)
        XCTAssertTrue(resolved[0].inferred)
        XCTAssertEqual(resolved[0].group, IPv4Address("239.1.1.1")!, "the lower of the two, named but flagged")
    }
}

final class CorrelationDiagnosticTests: XCTestCase {
    private func stream(_ group: String, rate: Double = 1_000_000) -> StreamSnapshot {
        StreamSnapshot(key: StreamKey(source: IPv4Address("10.10.1.50")!, group: IPv4Address(group)!,
                                      destinationPort: 5568, protocolNumber: IPProtocol.udp),
                       identity: StreamIdentity(name: "sACN (E1.31)", detail: nil, family: .lighting,
                                                confidence: .certain, reason: ""),
                       bitsPerSecond: rate, packetsPerSecond: 44, ttl: 16, ttlVaries: false,
                       sparkline: [], firstSeen: 0, lastSeen: 100, totalPackets: 100,
                       totalBytes: 1000, sawFragments: false)
    }

    private func forwarding(_ group: String?, ports: [Int]) -> ResolvedForwarding {
        let address = group.flatMap { IPv4Address($0) }
        return ResolvedForwarding(switchName: "core-sw", vlan: 120,
                                  mac: address?.ethernetMulticastMAC ?? MACAddress(parsing: "01:00:5e:00:00:00")!,
                                  ports: ports, group: address,
                                  inferred: address == nil, ambiguous: false)
    }

    /// Traffic in the capture, no switch ports in SNMP: the switch is flooding.
    func testTrafficWithNoForwardingEntryIsFlooding() throws {
        let diagnostics = CorrelationDiagnostics.diagnose(
            streams: [stream("239.255.0.12")], forwarding: [], snmpAvailable: true,
            memberships: [], captureInterface: "en7")
        let flooding = try XCTUnwrap(diagnostics.first { $0.id == "correlation.flooding" })
        XCTAssertEqual(flooding.severity, .warning)
        XCTAssertTrue(flooding.detail.contains("239.255.0.12"))
        XCTAssertTrue(flooding.detail.contains("snooping"))
    }

    /// Switch ports in SNMP, no traffic in the capture: a subscription with
    /// nothing behind it.
    func testForwardingEntryWithNoTrafficIsASilentSubscription() throws {
        let diagnostics = CorrelationDiagnostics.diagnose(
            streams: [], forwarding: [forwarding("239.255.0.20", ports: [5])],
            snmpAvailable: true, memberships: [], captureInterface: "en7")
        let starved = try XCTUnwrap(diagnostics.first { $0.id == "correlation.subscribed-but-silent" })
        XCTAssertEqual(starved.severity, .warning)
        XCTAssertTrue(starved.detail.contains("239.255.0.20"))
    }

    func testAgreementProducesNoDiagnostic() {
        let diagnostics = CorrelationDiagnostics.diagnose(
            streams: [stream("239.255.0.12")],
            forwarding: [forwarding("239.255.0.12", ports: [3])],
            snmpAvailable: true, memberships: [], captureInterface: "en7")
        XCTAssertTrue(diagnostics.isEmpty, "capture and SNMP agreeing is unremarkable")
    }

    func testNoDiagnosticsWhenSNMPIsUnavailable() {
        // Without SNMP, an empty forwarding table means nothing at all and must
        // not be read as "the switch is flooding".
        let diagnostics = CorrelationDiagnostics.diagnose(
            streams: [stream("239.255.0.12")], forwarding: [], snmpAvailable: false,
            memberships: [], captureInterface: "en7")
        XCTAssertTrue(diagnostics.isEmpty)
    }

    func testLinkLocalControlIsNotReportedAsFlooded() {
        let linkLocal = StreamSnapshot(
            key: StreamKey(source: IPv4Address("10.10.1.50")!, group: IPv4Address("224.0.0.251")!,
                           destinationPort: 5353, protocolNumber: IPProtocol.udp),
            identity: StreamIdentity(name: "mDNS", detail: nil, family: .discovery,
                                     confidence: .certain, reason: ""),
            bitsPerSecond: 5000, packetsPerSecond: 2, ttl: 1, ttlVaries: false,
            sparkline: [], firstSeen: 0, lastSeen: 100, totalPackets: 10, totalBytes: 100,
            sawFragments: false)
        let diagnostics = CorrelationDiagnostics.diagnose(
            streams: [linkLocal], forwarding: [], snmpAvailable: true,
            memberships: [], captureInterface: "en7")
        XCTAssertTrue(diagnostics.isEmpty, "224.0.0.0/24 is flooded by design")
    }

    /// The macOS routing trap: a Mac with Wi-Fi up and a Thunderbolt adapter on
    /// the Dante VLAN joins over Wi-Fi and silently receives nothing.
    func testJoinOnTheWrongInterfaceIsReported() throws {
        let diagnostics = CorrelationDiagnostics.diagnose(
            streams: [], forwarding: [], snmpAvailable: false,
            memberships: [LocalMembership(group: IPv4Address("239.255.0.12")!, interfaceName: "en0")],
            captureInterface: "en7")
        let trap = try XCTUnwrap(diagnostics.first { $0.id == "correlation.join-on-other-interface" })
        XCTAssertEqual(trap.severity, .warning)
        XCTAssertTrue(trap.detail.contains("en0"))
        XCTAssertTrue(trap.detail.contains("lowest-metric default route"))
    }

    func testJoinOnTheCaptureInterfaceIsFine() {
        let diagnostics = CorrelationDiagnostics.diagnose(
            streams: [], forwarding: [], snmpAvailable: false,
            memberships: [LocalMembership(group: IPv4Address("239.255.0.12")!, interfaceName: "en7")],
            captureInterface: "en7")
        XCTAssertTrue(diagnostics.isEmpty)
    }

    func testNoisyAndLinkLocalMembershipsAreNotReported() {
        // awdl0 and loopback join things constantly; 224.0.0.x is joined by the
        // stack itself on every interface. None of that is the routing trap.
        let diagnostics = CorrelationDiagnostics.diagnose(
            streams: [], forwarding: [], snmpAvailable: false,
            memberships: [
                LocalMembership(group: IPv4Address("224.0.0.251")!, interfaceName: "awdl0"),
                LocalMembership(group: IPv4Address("224.0.0.1")!, interfaceName: "en0"),
                LocalMembership(group: IPv4Address("239.255.255.250")!, interfaceName: "lo0"),
            ],
            captureInterface: "en7")
        XCTAssertTrue(diagnostics.isEmpty)
    }
}
