import Foundation
import XCTest
import MulticastCore

final class ProtocolCatalogTests: XCTestCase {
    override func tearDown() {
        StreamClassifier.customRules = []
    }

    private func classify(_ group: String, port: UInt16?, sourcePort: UInt16? = nil,
                          protocolNumber: UInt8 = IPProtocol.udp) -> StreamIdentity {
        StreamClassifier.classify(destination: IPv4Address(group)!, destinationPort: port,
                                  sourcePort: sourcePort, protocolNumber: protocolNumber)
    }

    // MARK: - Production AV protocols

    func testAudioProtocols() {
        XCTAssertEqual(classify("239.255.10.20", port: 4321).name, "Dante")
        XCTAssertEqual(classify("239.255.10.20", port: 4321).family, .audio)
        XCTAssertEqual(classify("239.69.1.1", port: 5004).name, "RTP")
        XCTAssertEqual(classify("239.69.1.1", port: 5004).detail, "AES67/RAVENNA/ST 2110")
        XCTAssertEqual(classify("239.192.1.1", port: 2048).name, "Q-SYS")
        XCTAssertEqual(classify("239.192.1.1", port: 2048).detail, "Q-LAN audio")
        XCTAssertEqual(classify("239.69.0.1", port: nil).name, "AES67")
    }

    func testDanteControlBlockIsRecognisedByAddress() {
        // 224.0.0.230-234 carry Dante control; they sit inside the link-local
        // block, so the exact address has to beat the range.
        for last in 230...234 {
            let identity = classify("224.0.0.\(last)", port: nil)
            XCTAssertEqual(identity.name, "Dante", "224.0.0.\(last)")
            XCTAssertEqual(identity.detail, "Control")
        }
        // Just outside the block, the range label applies again.
        XCTAssertEqual(classify("224.0.0.235", port: nil).name, "Link-local control")
    }

    func testLightingProtocols() {
        XCTAssertEqual(classify("239.255.0.12", port: 5568).name, "sACN (E1.31)")
        XCTAssertEqual(classify("239.255.1.1", port: 6454).name, "Art-Net")
        XCTAssertEqual(classify("239.255.250.133", port: 5569).name, "RDMnet")
        XCTAssertEqual(classify("239.255.250.133", port: nil).name, "RDMnet")
        XCTAssertEqual(classify("239.1.1.1", port: 6038).name, "KiNET")
        XCTAssertEqual(classify("239.1.1.1", port: 6038).family, .lighting)
        XCTAssertEqual(classify("239.1.1.1", port: 3348).name, "Pathport")
    }

    func testControlProtocols() {
        XCTAssertEqual(classify("239.1.1.1", port: 41794).name, "Crestron")
        XCTAssertEqual(classify("239.1.1.1", port: 41794).detail, "CIP")
        XCTAssertEqual(classify("239.1.1.1", port: 41795).detail, "CTP")
        XCTAssertEqual(classify("239.1.1.1", port: 1319).name, "AMX")
        XCTAssertEqual(classify("239.1.1.1", port: 3804).name, "HiQnet")
        XCTAssertEqual(classify("224.0.23.12", port: 3671).name, "KNXnet/IP")
        XCTAssertEqual(classify("239.1.1.1", port: 47808).name, "BACnet/IP")
        XCTAssertEqual(classify("239.1.1.1", port: 47808).confidence, .certain)
    }

    func testDiscoveryProtocols() {
        XCTAssertEqual(classify("224.0.0.251", port: 5353).name, "mDNS")
        XCTAssertEqual(classify("239.1.1.1", port: 8427).name, "Shure")
        XCTAssertEqual(classify("239.255.255.255", port: 9875).name, "SAP/SDP")
    }

    func testRoutingProtocolsByAddressAndIPProtocol() {
        XCTAssertEqual(classify("224.0.0.5", port: nil).name, "OSPF")
        XCTAssertEqual(classify("224.0.0.6", port: nil).detail, "Designated routers")
        XCTAssertEqual(classify("224.0.0.9", port: nil).name, "RIPv2")
        XCTAssertEqual(classify("224.0.0.10", port: nil).name, "EIGRP")
        XCTAssertEqual(classify("224.0.1.39", port: nil).name, "Auto-RP")
        XCTAssertEqual(classify("224.0.1.40", port: nil).detail, "Discovery")

        // Protocol number wins over anything the address or port would say.
        XCTAssertEqual(classify("224.0.0.5", port: 5568, protocolNumber: IPProtocol.ospf).name, "OSPF")
        XCTAssertEqual(classify("224.0.0.13", port: 5568, protocolNumber: IPProtocol.pim).name, "PIM")
    }

    func testEveryFamilyIsReachable() {
        // Each family in the toolbar filter must actually be produced by
        // something, or the filter has a dead entry.
        var seen = Set<ProtocolFamily>()
        let probes: [(String, UInt16?)] = [
            ("239.69.1.1", 5004),      // audio
            ("239.255.0.12", 5568),    // lighting
            ("224.0.1.129", 319),      // clock
            ("224.0.0.251", 5353),     // discovery
            ("239.1.1.1", 41794),      // control
            ("224.0.0.5", nil),        // routing
            ("239.255.0.99", nil),     // unknown
        ]
        for (group, port) in probes { seen.insert(classify(group, port: port).family) }
        XCTAssertTrue(seen.contains(.audio))
        XCTAssertTrue(seen.contains(.lighting))
        XCTAssertTrue(seen.contains(.clock))
        XCTAssertTrue(seen.contains(.discovery))
        XCTAssertTrue(seen.contains(.control))
        XCTAssertTrue(seen.contains(.routing))
        XCTAssertTrue(seen.contains(.unknown))
    }

    /// Adding entries must not have made a range accidentally shadow a port.
    func testPortStillBeatsRangeEverywhere() {
        XCTAssertEqual(classify("224.0.0.99", port: 5568).name, "sACN (E1.31)")
        XCTAssertEqual(classify("232.1.1.1", port: 4321).name, "Dante")
        XCTAssertEqual(classify("233.1.1.1", port: 6454).name, "Art-Net")
    }

    // MARK: - Site-specific rules

    func testCustomRuleBeatsTheBuiltInCatalogue() {
        // A site that runs something else on 239.255.0.x should be able to say so.
        StreamClassifier.customRules = [
            CustomClassificationRule(name: "SDVoE wall", detail: "Sanctuary", family: .video,
                                     portLow: 5568, groupPrefix: "239.255.0.0", prefixLength: 24),
        ]
        let identity = classify("239.255.0.12", port: 5568)
        XCTAssertEqual(identity.name, "SDVoE wall")
        XCTAssertEqual(identity.family, .video)
        XCTAssertEqual(identity.confidence, .certain)
        XCTAssertTrue(identity.reason.contains("your own rule"))

        // Outside the rule's subnet the catalogue applies again.
        XCTAssertEqual(classify("239.255.9.12", port: 5568).name, "sACN (E1.31)")
    }

    func testCustomRuleOnPortRangeOnly() {
        StreamClassifier.customRules = [
            CustomClassificationRule(name: "House video", family: .video, portLow: 6000, portHigh: 6010),
        ]
        XCTAssertEqual(classify("239.100.0.1", port: 6005).name, "House video")
        XCTAssertEqual(classify("239.100.0.1", port: 6000).name, "House video")
        XCTAssertEqual(classify("239.100.0.1", port: 6010).name, "House video")
        XCTAssertNotEqual(classify("239.100.0.1", port: 6011).name, "House video")
    }

    func testCustomRuleOnAddressRangeOnly() {
        StreamClassifier.customRules = [
            CustomClassificationRule(name: "Campus B video", family: .video,
                                     groupPrefix: "239.100.0.0", prefixLength: 16),
        ]
        XCTAssertEqual(classify("239.100.5.5", port: 49999).name, "Campus B video")
        XCTAssertNotEqual(classify("239.101.5.5", port: 49999).name, "Campus B video")
    }

    func testDisabledAndUnusableRulesAreIgnored() {
        StreamClassifier.customRules = [
            CustomClassificationRule(name: "Off", family: .video, isEnabled: false, portLow: 5568),
            // Neither a port nor an address: this would match everything.
            CustomClassificationRule(name: "Matches everything", family: .video),
            CustomClassificationRule(name: "  ", family: .video, portLow: 5568),
        ]
        XCTAssertEqual(classify("239.255.0.12", port: 5568).name, "sACN (E1.31)")
    }

    func testRuleSummaryReadsSensibly() {
        XCTAssertEqual(CustomClassificationRule(name: "x", portLow: 5568).summary, "port 5568")
        XCTAssertEqual(CustomClassificationRule(name: "x", portLow: 6000, portHigh: 6010).summary, "ports 6000-6010")
        XCTAssertEqual(CustomClassificationRule(name: "x", groupPrefix: "239.100.0.0", prefixLength: 16).summary,
                       "239.100.0.0/16")
    }

    func testCustomRuleSurvivesEncoding() throws {
        let rule = CustomClassificationRule(name: "SDVoE wall", detail: "Sanctuary", family: .video,
                                            portLow: 6000, portHigh: 6010,
                                            groupPrefix: "239.100.0.0", prefixLength: 16)
        let data = try JSONEncoder().encode([rule])
        let decoded = try JSONDecoder().decode([CustomClassificationRule].self, from: data)
        XCTAssertEqual(decoded, [rule])
    }
}
