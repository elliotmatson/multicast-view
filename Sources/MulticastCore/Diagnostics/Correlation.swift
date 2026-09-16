import Foundation

/// One row from a switch's multicast forwarding table, before the MAC has been
/// resolved back to a group address.
public struct GroupForwarding: Equatable, Sendable {
    public let switchName: String
    public let vlan: Int
    public let mac: MACAddress
    public let ports: [Int]

    public init(switchName: String, vlan: Int, mac: MACAddress, ports: [Int]) {
        self.switchName = switchName
        self.vlan = vlan
        self.mac = mac
        self.ports = ports
    }
}

/// A forwarding row after cross-referencing against groups actually seen.
public struct ResolvedForwarding: Identifiable, Equatable, Sendable {
    public let switchName: String
    public let vlan: Int
    public let mac: MACAddress
    public let ports: [Int]
    /// The group this row is believed to be for, if one could be determined.
    public let group: IPv4Address?
    /// True when the group came from the MAC alone rather than from traffic.
    /// The IP-to-MAC mapping drops 9 bits, so this is a guess among 32.
    public let inferred: Bool
    /// True when more than one group seen in the capture maps to this MAC.
    public let ambiguous: Bool

    public init(switchName: String, vlan: Int, mac: MACAddress, ports: [Int],
                group: IPv4Address?, inferred: Bool, ambiguous: Bool) {
        self.switchName = switchName
        self.vlan = vlan
        self.mac = mac
        self.ports = ports
        self.group = group
        self.inferred = inferred
        self.ambiguous = ambiguous
    }

    public var id: String { "\(switchName)/\(vlan)/\(mac)" }

    public var portsText: String {
        ports.isEmpty ? "-" : ports.map(String.init).joined(separator: ", ")
    }
}

/// A group this Mac has itself joined, and the interface it joined it on.
public struct LocalMembership: Identifiable, Equatable, Hashable, Sendable {
    public let group: IPv4Address
    public let interfaceName: String

    public init(group: IPv4Address, interfaceName: String) {
        self.group = group
        self.interfaceName = interfaceName
    }

    public var id: String { "\(interfaceName)/\(group)" }
}

public enum ForwardingResolver {
    /// Resolves switch rows (which are keyed by MAC) back to real group
    /// addresses by cross-referencing the groups actually seen in the capture.
    ///
    /// The IPv4-to-Ethernet mapping keeps only the low 23 bits, so 239.1.1.1
    /// and 239.129.1.1 land on the same MAC and the switch cannot tell them
    /// apart. Traffic is the only thing that can.
    public static func resolve(_ rows: [GroupForwarding],
                               observedGroups: Set<IPv4Address>) -> [ResolvedForwarding] {
        // Index the observed groups by the MAC they map to.
        var groupsByMAC: [MACAddress: [IPv4Address]] = [:]
        for group in observedGroups {
            groupsByMAC[group.ethernetMulticastMAC, default: []].append(group)
        }

        return rows.map { row in
            let candidates = (groupsByMAC[row.mac] ?? []).sorted()
            if candidates.count == 1 {
                return ResolvedForwarding(switchName: row.switchName, vlan: row.vlan, mac: row.mac,
                                          ports: row.ports, group: candidates[0],
                                          inferred: false, ambiguous: false)
            }
            if candidates.count > 1 {
                // Several live groups share this MAC. Name the lowest but say so.
                return ResolvedForwarding(switchName: row.switchName, vlan: row.vlan, mac: row.mac,
                                          ports: row.ports, group: candidates[0],
                                          inferred: true, ambiguous: true)
            }
            // Nothing in the capture maps here. Still worth showing: a
            // subscription with no traffic behind it is a real symptom.
            return ResolvedForwarding(switchName: row.switchName, vlan: row.vlan, mac: row.mac,
                                      ports: row.ports, group: nil,
                                      inferred: true, ambiguous: false)
        }
    }
}

public enum CorrelationDiagnostics {
    /// The disagreements between capture, SNMP and local membership. These are
    /// the findings; agreement is unremarkable.
    public static func diagnose(streams: [StreamSnapshot],
                                forwarding: [ResolvedForwarding],
                                snmpAvailable: Bool,
                                memberships: [LocalMembership],
                                captureInterface: String?) -> [Diagnostic] {
        var result: [Diagnostic] = []

        if snmpAvailable {
            var forwardedGroups = Set<IPv4Address>()
            for row in forwarding where !row.ports.isEmpty {
                if let group = row.group { forwardedGroups.insert(group) }
            }

            // Traffic flowing, but the switch has no egress ports for it: the
            // switch is flooding the group rather than forwarding it.
            var floodingGroups = Set<IPv4Address>()
            for stream in streams where stream.bitsPerSecond > 0 {
                let group = stream.key.group
                // Link-local control is flooded by design; that is not a fault.
                guard !group.isLinkLocalControl else { continue }
                guard !forwardedGroups.contains(group) else { continue }
                floodingGroups.insert(group)
            }
            if !floodingGroups.isEmpty {
                let listed = floodingGroups.sorted().prefix(6).map(\.description).joined(separator: ", ")
                let more = floodingGroups.count > 6 ? " and \(floodingGroups.count - 6) more" : ""
                result.append(Diagnostic(
                    id: "correlation.flooding",
                    severity: .warning,
                    title: "\(floodingGroups.count) group\(floodingGroups.count == 1 ? " is" : "s are") flowing but not in any switch forwarding table",
                    detail: "\(listed)\(more). Traffic is on the wire but no switch reports forwarding it "
                          + "out of any port, which means it is being flooded to every port rather than "
                          + "forwarded deliberately. IGMP snooping is off, or it is not working on this VLAN."))
            }

            // Ports subscribed, but nothing is sending.
            var activeGroups = Set<IPv4Address>()
            for stream in streams where stream.bitsPerSecond > 0 { activeGroups.insert(stream.key.group) }

            var starved: [ResolvedForwarding] = []
            for row in forwarding where !row.ports.isEmpty {
                guard let group = row.group else { continue }
                if !activeGroups.contains(group) { starved.append(row) }
            }
            if !starved.isEmpty {
                let listed = starved.prefix(6).map { "\($0.group!) on \($0.switchName) port \($0.portsText)" }
                    .joined(separator: "; ")
                let more = starved.count > 6 ? " and \(starved.count - 6) more" : ""
                result.append(Diagnostic(
                    id: "correlation.subscribed-but-silent",
                    severity: .warning,
                    title: "\(starved.count) subscription\(starved.count == 1 ? "" : "s") with no traffic behind \(starved.count == 1 ? "it" : "them")",
                    detail: "\(listed)\(more). Something is asking for these streams and nothing is sending "
                          + "them. Either the source is down, or it is on a segment this capture cannot see."))
            }
        }

        // The macOS routing trap: a join that landed on the wrong interface.
        if let captureInterface {
            var wrongInterface: [LocalMembership] = []
            for membership in memberships {
                guard membership.interfaceName != captureInterface else { continue }
                guard !membership.group.isLinkLocalControl else { continue }
                guard !InterfaceAdvice.isNoiseInterface(membership.interfaceName) else { continue }
                guard membership.interfaceName != "lo0" else { continue }
                wrongInterface.append(membership)
            }
            if !wrongInterface.isEmpty {
                var byInterface: [String: [IPv4Address]] = [:]
                for membership in wrongInterface {
                    byInterface[membership.interfaceName, default: []].append(membership.group)
                }
                let listed = byInterface.keys.sorted().map { name in
                    "\(name): \(byInterface[name]!.sorted().prefix(4).map(\.description).joined(separator: ", "))"
                }.joined(separator: "; ")
                result.append(Diagnostic(
                    id: "correlation.join-on-other-interface",
                    severity: .warning,
                    title: "This Mac joined groups on an interface other than \(captureInterface)",
                    detail: "\(listed). macOS joins multicast on the interface with the lowest-metric "
                          + "default route, which is very often not the AV network. If an application on "
                          + "this Mac is not receiving a stream, this is why: it joined over the wrong "
                          + "interface and is silently receiving nothing."))
            }
        }

        return result
    }
}
