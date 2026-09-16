import Foundation

public enum QBridgeMIB {
    /// dot1qTpGroupEgressPorts, the generic multicast forwarding table.
    /// Indexed by VLAN then a 6-byte MAC.
    public static let groupEgressPorts = OID("1.3.6.1.2.1.17.7.1.2.3.1.2")!

    /// Cisco's equivalent, tried when the generic table is empty.
    public static let ciscoGroupEgressPorts = OID("1.3.6.1.4.1.9.9.393.1.3.1.1.3")!

    /// sysName, for labelling a switch that has no configured name.
    public static let sysName = OID("1.3.6.1.2.1.1.5.0")!
}

public enum PortList {
    /// Decodes a Q-BRIDGE PortList bitmap.
    ///
    /// Bit 7 (the most significant bit) of byte 0 is port 1, bit 6 is port 2,
    /// and so on; byte 1 covers ports 9-16. Reading the bytes little-endian,
    /// or starting byte 1 at port 8, is an off-by-eight that unit tests on a
    /// single byte will not catch -- hence the multi-byte cases below.
    public static func ports(from bitmap: [UInt8]) -> [Int] {
        var result: [Int] = []
        for (byteIndex, byte) in bitmap.enumerated() {
            guard byte != 0 else { continue }
            for bitIndex in 0..<8 where (byte & (0x80 >> UInt8(bitIndex))) != 0 {
                result.append(byteIndex * 8 + bitIndex + 1)
            }
        }
        return result
    }

    /// Inverse, for tests and for building fixtures.
    public static func bitmap(for ports: [Int], byteCount: Int? = nil) -> [UInt8] {
        let highest = ports.max() ?? 0
        let count = byteCount ?? max(1, (highest + 7) / 8)
        var bytes = [UInt8](repeating: 0, count: count)
        for port in ports where port >= 1 {
            let byteIndex = (port - 1) / 8
            guard byteIndex < bytes.count else { continue }
            let bitIndex = (port - 1) % 8
            bytes[byteIndex] |= 0x80 >> UInt8(bitIndex)
        }
        return bytes
    }
}

public enum QBridgeIndex {
    /// Splits a dot1qTpGroupEgressPorts index into its VLAN and MAC parts.
    /// The last six arcs are the MAC; whatever precedes them is the VLAN.
    public static func parse(_ suffix: [UInt32]) -> (vlan: Int, mac: MACAddress)? {
        guard suffix.count >= 7 else { return nil }
        let macArcs = suffix.suffix(6)
        var macBytes: [UInt8] = []
        for arc in macArcs {
            guard arc <= 255 else { return nil }
            macBytes.append(UInt8(arc))
        }
        let vlanArcs = suffix.dropLast(6)
        // A well-formed index has exactly one VLAN arc. A UInt32 always fits
        // in an Int on the platforms this runs on.
        guard let vlan = vlanArcs.last else { return nil }
        return (Int(vlan), MACAddress(bytes: macBytes))
    }
}

/// Decides when a walk has finished.
public enum WalkTermination: Equatable {
    case notFinished
    case leftSubtree
    case endOfMibView
    case didNotAdvance
    case agentError(Int)

    public var isFinished: Bool { self != .notFinished }
}

public enum SNMPWalk {
    /// A walk ends when the OID leaves the subtree, when the agent says
    /// endOfMibView, or when a response fails to advance lexicographically.
    /// That last one is what stops an infinite loop against a broken agent.
    public static func evaluate(binding: VariableBinding,
                                subtree: OID,
                                previous: OID?) -> WalkTermination {
        if binding.value.isEndOfView { return .endOfMibView }
        if !binding.oid.isWithin(subtree) { return .leftSubtree }
        if let previous, binding.oid <= previous { return .didNotAdvance }
        return .notFinished
    }
}
