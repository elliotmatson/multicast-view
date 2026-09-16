import Foundation

/// Turns a group address and port into something an operator recognises:
/// "sACN universe 12", not "239.255.0.12".
///
/// Resolution order, strongest evidence first:
///   1. a protocol-specific destination port      -> certain
///   2. an IANA-assigned group address            -> certain
///   3. a protocol's default destination port     -> likely
///   4. the same ports seen as *source* ports     -> one step less confident
///   5. address range, most specific first        -> likely or guess
public enum StreamClassifier {

    /// Site-specific rules, consulted before the built-in catalogue.
    /// Set from Settings; empty by default.
    public static var customRules: [CustomClassificationRule] = []


    // MARK: - Port assignments

    /// Ports that only ever mean one thing.
    static let certainPorts: [UInt16: StreamIdentity] = [
        319:   identity("PTPv2", detail: "Event", family: .clock, reason: "UDP 319 is the PTP event port."),
        320:   identity("PTPv2", detail: "General", family: .clock, reason: "UDP 320 is the PTP general port."),
        5353:  identity("mDNS", family: .discovery, reason: "UDP 5353 is assigned to multicast DNS. Bonjour, and the discovery layer for NDI, Q-SYS, Crestron NVX and NMOS."),
        1900:  identity("SSDP", family: .discovery, reason: "UDP 1900 is assigned to SSDP (UPnP discovery)."),
        9875:  identity("SAP/SDP", family: .discovery, reason: "UDP 9875 is assigned to the Session Announcement Protocol. This is how AES67, RAVENNA and SMPTE ST 2110 advertise stream descriptions."),
        5568:  identity("sACN (E1.31)", family: .lighting, reason: "UDP 5568 is assigned to ANSI E1.31 streaming ACN."),
        6454:  identity("Art-Net", family: .lighting, reason: "UDP 6454 is the Art-Net port."),
        4321:  identity("Dante", detail: "Audio", family: .audio, reason: "UDP 4321 carries Dante audio."),
        3702:  identity("WS-Discovery", detail: "ONVIF", family: .discovery, reason: "UDP 3702 is assigned to WS-Discovery, used by ONVIF cameras."),
        427:   identity("SLP", family: .discovery, reason: "UDP 427 is assigned to the Service Location Protocol."),
        5355:  identity("LLMNR", family: .discovery, reason: "UDP 5355 is assigned to LLMNR."),
        3671:  identity("KNXnet/IP", family: .control, reason: "UDP 3671 is assigned to KNXnet/IP, used for building control and house lighting."),
        47808: identity("BACnet/IP", family: .control, reason: "UDP 47808 is assigned to BACnet/IP, used for HVAC and building automation."),
        5569:  identity("RDMnet", detail: "LLRP (E1.33)", family: .lighting, reason: "UDP 5569 is assigned to ANSI E1.33 RDMnet; LLRP uses it for low-level device discovery."),
        520:   identity("RIP", family: .routing, reason: "UDP 520 is assigned to RIP."),
        1985:  identity("HSRP", family: .routing, reason: "UDP 1985 is the HSRP hello port."),
        3222:  identity("GLBP", family: .routing, reason: "UDP 3222 is assigned to GLBP."),
    ]

    /// Ports that are a protocol's default but are not exclusively its own.
    static let likelyPorts: [UInt16: StreamIdentity] = [
        5004:  identity("RTP", detail: "AES67/RAVENNA/ST 2110", family: .audio, confidence: .likely,
                        reason: "UDP 5004 is the default RTP media port. AES67, RAVENNA, Livewire+ and SMPTE ST 2110 all use it; the SDP announced on 9875 says which."),
        5005:  identity("RTCP", family: .audio, confidence: .likely,
                        reason: "UDP 5005 is the RTCP companion to RTP on 5004."),
        5006:  identity("RTP", detail: "AES67/RAVENNA", family: .audio, confidence: .likely,
                        reason: "UDP 5006 is a second default RTP media port used by AES67 and RAVENNA."),
        8800:  identity("Dante", detail: "Clock (legacy)", family: .clock, confidence: .likely,
                        reason: "UDP 8800 is the legacy Dante clock port."),
        2048:  identity("Q-SYS", detail: "Q-LAN audio", family: .audio, confidence: .likely,
                        reason: "UDP 2048 carries Q-SYS Q-LAN audio."),
        41794: identity("Crestron", detail: "CIP", family: .control, confidence: .likely,
                        reason: "UDP 41794 is Crestron's control port (CIP), also used for device auto-discovery."),
        41795: identity("Crestron", detail: "CTP", family: .control, confidence: .likely,
                        reason: "UDP/TCP 41795 is the Crestron Terminal Protocol port."),
        1319:  identity("AMX", detail: "ICSP", family: .control, confidence: .likely,
                        reason: "UDP 1319 carries AMX NetLinx ICSP control traffic."),
        3804:  identity("HiQnet", family: .control, confidence: .likely,
                        reason: "UDP 3804 carries Harman HiQnet control, used by BSS, dbx and Crown."),
        6038:  identity("KiNET", family: .lighting, confidence: .likely,
                        reason: "UDP 6038 is Philips Color Kinetics KiNET."),
        3348:  identity("Pathport", family: .lighting, confidence: .likely,
                        reason: "UDP 3348 is the Pathway Connectivity Pathport protocol."),
        8427:  identity("Shure", detail: "Discovery", family: .discovery, confidence: .likely,
                        reason: "UDP 8427 is used by Shure devices for discovery and control."),
    ]

    /// Dante control and monitoring spans a small block.
    static let danteControlPorts: ClosedRange<UInt16> = 8700...8708

    // MARK: - Well-known addresses

    static let wellKnownAddresses: [UInt32: StreamIdentity] = {
        var table: [UInt32: StreamIdentity] = [:]
        func add(_ text: String, _ identity: StreamIdentity) {
            if let address = IPv4Address(text) { table[address.raw] = identity }
        }
        add("224.0.0.1",   identity("All hosts", family: .routing, reason: "224.0.0.1 is the all-hosts group."))
        add("224.0.0.2",   identity("All routers", family: .routing, reason: "224.0.0.2 is the all-routers group. HSRPv1 also uses it."))
        add("224.0.0.5",   identity("OSPF", detail: "All routers", family: .routing, reason: "224.0.0.5 is OSPF AllSPFRouters."))
        add("224.0.0.6",   identity("OSPF", detail: "Designated routers", family: .routing, reason: "224.0.0.6 is OSPF AllDRouters."))
        add("224.0.0.9",   identity("RIPv2", family: .routing, reason: "224.0.0.9 is the RIPv2 group."))
        add("224.0.0.10",  identity("EIGRP", family: .routing, reason: "224.0.0.10 is the EIGRP group."))
        add("224.0.0.12",  identity("DHCP relay", family: .routing, reason: "224.0.0.12 is the DHCP server/relay agent group."))
        add("224.0.0.13",  identity("PIM", family: .routing, reason: "224.0.0.13 is the PIM all-routers group."))
        add("224.0.0.18",  identity("VRRP", family: .routing, reason: "224.0.0.18 is assigned to VRRP."))
        add("224.0.0.22",  identity("IGMPv3", detail: "Reports", family: .routing, reason: "224.0.0.22 is where IGMPv3 membership reports are sent."))
        add("224.0.0.102", identity("HSRPv2/GLBP", family: .routing, reason: "224.0.0.102 is used by HSRPv2 and GLBP."))
        add("224.0.0.107", identity("PTPv2", detail: "Peer delay", family: .clock, reason: "224.0.0.107 carries PTP peer-delay messages."))
        add("224.0.0.251", identity("mDNS", family: .discovery, reason: "224.0.0.251 is the mDNS group."))
        add("224.0.0.252", identity("LLMNR", family: .discovery, reason: "224.0.0.252 is the LLMNR group."))
        add("224.0.1.1",   identity("NTP", family: .clock, reason: "224.0.1.1 is the NTP multicast group."))
        add("224.0.1.39",  identity("Auto-RP", detail: "Announce", family: .routing, reason: "224.0.1.39 is Cisco Auto-RP announcement."))
        add("224.0.1.40",  identity("Auto-RP", detail: "Discovery", family: .routing, reason: "224.0.1.40 is Cisco Auto-RP discovery."))
        add("224.0.23.12", identity("KNXnet/IP", detail: "Routing", family: .control, reason: "224.0.23.12 is the KNXnet/IP routing group."))
        add("239.255.255.250", identity("SSDP", family: .discovery, reason: "239.255.255.250 is the SSDP group."))
        add("239.255.255.253", identity("SLP", family: .discovery, reason: "239.255.255.253 is the SLP group."))
        add("239.255.250.133", identity("RDMnet", detail: "LLRP", family: .lighting, reason: "239.255.250.133 is the ANSI E1.33 LLRP broadcast group."))
        // PTPv2 domains 0-3 each have their own group.
        for domain in 0...3 {
            add("224.0.1.\(129 + domain)",
                identity("PTPv2", detail: "Domain \(domain)", family: .clock,
                         reason: "224.0.1.\(129 + domain) is the PTPv2 group for domain \(domain)."))
        }
        // Dante keeps its control and monitoring traffic in a small block of
        // the link-local range.
        for last in 230...234 {
            add("224.0.0.\(last)",
                identity("Dante", detail: "Control", family: .control, confidence: .likely,
                         reason: "224.0.0.230-234 carry Dante control, monitoring and clock traffic."))
        }
        return table
    }()

    // MARK: - Ranges

    struct AddressRange {
        let base: IPv4Address
        let prefix: Int
        let identity: StreamIdentity
    }

    /// Sorted most-specific-first at use time, so 239.69.0.0/16 beats 239.0.0.0/8.
    static let ranges: [AddressRange] = {
        func range(_ text: String, _ prefix: Int, _ identity: StreamIdentity) -> AddressRange {
            AddressRange(base: IPv4Address(text)!, prefix: prefix, identity: identity)
        }
        let list = [
            range("224.0.0.0", 24, identity("Link-local control", family: .routing, confidence: .likely,
                                            reason: "224.0.0.0/24 is the link-local control block. TTL 1 is correct here.")),
            range("224.0.1.0", 24, identity("Internetwork control", family: .routing, confidence: .likely,
                                            reason: "224.0.1.0/24 is the internetwork control block.")),
            range("224.0.23.0", 24, identity("IANA application block", family: .unknown, confidence: .guess,
                                             reason: "224.0.23.0/24 holds assorted IANA application assignments, including KNXnet/IP.")),
            range("224.2.0.0", 16, identity("SAP/SDP", family: .discovery, confidence: .likely,
                                            reason: "224.2.0.0/16 is the SDP/SAP block.")),
            range("232.0.0.0", 8, identity("Source-specific multicast", family: .routing, confidence: .likely,
                                           reason: "232.0.0.0/8 is reserved for SSM.")),
            range("233.0.0.0", 8, identity("GLOP", family: .unknown, confidence: .likely,
                                           reason: "233.0.0.0/8 is GLOP address space, derived from an AS number.")),
            range("239.69.0.0", 16, identity("AES67", family: .audio, confidence: .likely,
                                             reason: "239.69.0.0/16 is the AES67 default range. Confirm with the port.")),
            range("239.192.0.0", 14, identity("Organisation-local scope", family: .unknown, confidence: .guess,
                                              reason: "239.192.0.0/14 is organisation-local scope. Axia Livewire+ also uses this range, but the scope alone does not prove it.")),
            // Deliberately not labelled sACN: Dante, NDI and sACN all live here
            // and only the port tells them apart.
            range("239.255.0.0", 16, identity("Site-local scope", family: .unknown, confidence: .guess,
                                              reason: "239.255.0.0/16 is site-local scope, shared by Dante, NDI and sACN. Only the port identifies it.")),
            range("239.0.0.0", 8, identity("Administratively scoped", family: .unknown, confidence: .guess,
                                           reason: "239.0.0.0/8 is administratively scoped. Most AV vendors allocate from here, so the scope alone says nothing about protocol.")),
        ]
        return list.sorted { $0.prefix > $1.prefix }
    }()

    // MARK: - Entry point

    public static func classify(destination: IPv4Address,
                                destinationPort: UInt16?,
                                sourcePort: UInt16? = nil,
                                protocolNumber: UInt8 = IPProtocol.udp) -> StreamIdentity {
        if protocolNumber == IPProtocol.igmp {
            return identity("IGMP", family: .routing, reason: "IP protocol 2 is IGMP.")
        }
        if protocolNumber == IPProtocol.ospf {
            return identity("OSPF", family: .routing, reason: "IP protocol 89 is OSPF.")
        }
        if protocolNumber == IPProtocol.pim {
            return identity("PIM", family: .routing, reason: "IP protocol 103 is PIM.")
        }

        // Your own rules win: they describe this network, the catalogue only
        // describes the general case.
        for rule in customRules where rule.matches(group: destination, destinationPort: destinationPort) {
            return rule.identity()
        }

        // 1. A protocol-specific destination port.
        if let port = destinationPort, let base = portIdentity(port, requiring: .certain) {
            return refine(base, for: destination, port: port)
        }

        // 2. An IANA-assigned address.
        if let known = wellKnownAddresses[destination.raw] {
            return known
        }

        // 3. A protocol's default destination port.
        if let port = destinationPort, let base = portIdentity(port, requiring: .likely) {
            return refine(base, for: destination, port: port)
        }

        // 4. The same ports as a source port. Weaker: a sender's ephemeral
        //    source port can collide with an assignment by chance.
        if let port = sourcePort, let base = portIdentity(port, requiring: .likely) {
            let weakened = StreamIdentity(name: base.name, detail: base.detail, family: base.family,
                                          confidence: base.confidence == .certain ? .likely : .guess,
                                          reason: base.reason + " Seen as the source port rather than the destination.")
            return refine(weakened, for: destination, port: port)
        }

        // 5. Address range, most specific first.
        for range in ranges where destination.inSubnet(range.base, prefix: range.prefix) {
            return range.identity
        }

        return .unidentified
    }

    public static func classify(_ packet: ObservedPacket) -> StreamIdentity {
        classify(destination: packet.destination,
                 destinationPort: packet.destinationPort,
                 sourcePort: packet.sourcePort,
                 protocolNumber: packet.protocolNumber)
    }

    // MARK: - Helpers

    private static func portIdentity(_ port: UInt16, requiring minimum: IdentificationConfidence) -> StreamIdentity? {
        if let found = certainPorts[port] { return found }
        guard minimum <= .likely else { return nil }
        if let found = likelyPorts[port] { return found }
        if danteControlPorts.contains(port) {
            return identity("Dante", detail: "Control", family: .control, confidence: .likely,
                            reason: "UDP \(port) is in the Dante control and monitoring range 8700-8708.")
        }
        return nil
    }

    /// Adds the detail that only the address can supply -- chiefly the sACN
    /// universe, which is encoded in the group address itself.
    private static func refine(_ base: StreamIdentity, for destination: IPv4Address, port: UInt16) -> StreamIdentity {
        guard base.name == "sACN (E1.31)" else { return base }
        guard let universe = sACNUniverse(for: destination) else { return base }
        return StreamIdentity(name: base.name, detail: "Universe \(universe)", family: base.family,
                              confidence: base.confidence,
                              reason: base.reason + " 239.255.\(destination.bytes.2).\(destination.bytes.3) encodes universe \(universe).")
    }

    /// sACN puts the universe number in the last two octets of the group:
    /// 239.255.<high>.<low> -> high * 256 + low. Valid universes are 1-63999,
    /// so 239.255.0.0 and anything from 239.255.250.0 up is out of range.
    public static func sACNUniverse(for group: IPv4Address) -> Int? {
        guard group.inSubnet(IPv4Address(239, 255, 0, 0), prefix: 16) else { return nil }
        let octets = group.bytes
        let universe = Int(octets.2) * 256 + Int(octets.3)
        guard (1...63999).contains(universe) else { return nil }
        return universe
    }

    /// The group address carrying a given sACN universe. Inverse of the above.
    public static func sACNGroup(forUniverse universe: Int) -> IPv4Address? {
        guard (1...63999).contains(universe) else { return nil }
        return IPv4Address(239, 255, UInt8(universe / 256), UInt8(universe % 256))
    }

    private static func identity(_ name: String, detail: String? = nil, family: ProtocolFamily,
                                 confidence: IdentificationConfidence = .certain,
                                 reason: String) -> StreamIdentity {
        StreamIdentity(name: name, detail: detail, family: family, confidence: confidence, reason: reason)
    }
}
