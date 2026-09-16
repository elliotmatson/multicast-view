import Foundation

/// An IPv4 address held as a host-order 32-bit value.
public struct IPv4Address: Hashable, Comparable, CustomStringConvertible, Codable, Sendable {
    public let raw: UInt32

    public init(raw: UInt32) { self.raw = raw }

    public init(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) {
        raw = (UInt32(a) << 24) | (UInt32(b) << 16) | (UInt32(c) << 8) | UInt32(d)
    }

    /// Parses dotted-quad. Returns nil on anything that isn't exactly four 0-255 octets.
    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber),
                  let octet = UInt16(part), octet <= 255 else { return nil }
            value = (value << 8) | UInt32(octet)
        }
        raw = value
    }

    /// Big-endian bytes, i.e. wire order.
    public var bytes: (UInt8, UInt8, UInt8, UInt8) {
        (UInt8(truncatingIfNeeded: raw >> 24), UInt8(truncatingIfNeeded: raw >> 16),
         UInt8(truncatingIfNeeded: raw >> 8), UInt8(truncatingIfNeeded: raw))
    }

    public var description: String {
        let b = bytes
        return "\(b.0).\(b.1).\(b.2).\(b.3)"
    }

    public static func < (lhs: IPv4Address, rhs: IPv4Address) -> Bool { lhs.raw < rhs.raw }

    /// 224.0.0.0/4
    public var isMulticast: Bool { (raw & 0xF000_0000) == 0xE000_0000 }

    /// 224.0.0.0/24 -- the link-local control block. Never forwarded, TTL 1 is correct here.
    public var isLinkLocalControl: Bool { (raw & 0xFFFF_FF00) == 0xE000_0000 }

    public static let unspecified = IPv4Address(raw: 0)

    public func inSubnet(_ base: IPv4Address, prefix: Int) -> Bool {
        guard prefix > 0 else { return true }
        guard prefix < 32 else { return raw == base.raw }
        let mask = ~UInt32(0) << (32 - UInt32(prefix))
        return (raw & mask) == (base.raw & mask)
    }

    /// The 23-bit-truncated Ethernet multicast MAC an IPv4 group maps to.
    /// Losing the top 5 bits of the second octet is why 239.1.1.1 and 239.129.1.1
    /// collide -- see `MACAddress.possibleGroups`.
    public var ethernetMulticastMAC: MACAddress {
        let low23 = raw & 0x007F_FFFF
        return MACAddress(bytes: [
            0x01, 0x00, 0x5E,
            UInt8(truncatingIfNeeded: low23 >> 16),
            UInt8(truncatingIfNeeded: low23 >> 8),
            UInt8(truncatingIfNeeded: low23),
        ])
    }
}

/// A 48-bit Ethernet address.
public struct MACAddress: Hashable, CustomStringConvertible, Codable, Sendable {
    public let bytes: [UInt8]   // always 6

    public init(bytes: [UInt8]) {
        precondition(bytes.count == 6, "MAC must be 6 bytes")
        self.bytes = bytes
    }

    public init?(parsing text: String) {
        let parts = text.split(whereSeparator: { $0 == ":" || $0 == "-" })
        guard parts.count == 6 else { return nil }
        var out: [UInt8] = []
        for part in parts {
            guard let byte = UInt8(part, radix: 16) else { return nil }
            out.append(byte)
        }
        self.init(bytes: out)
    }

    public var description: String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    public var isIPv4Multicast: Bool {
        bytes[0] == 0x01 && bytes[1] == 0x00 && bytes[2] == 0x5E && (bytes[3] & 0x80) == 0
    }

    /// Every IPv4 group that maps onto this MAC. 32 of them, because the
    /// mapping drops 5 bits of octet 2 -- the switch stores by MAC, so a
    /// Q-BRIDGE row can only ever be narrowed by cross-referencing traffic.
    public var possibleGroups: [IPv4Address] {
        guard isIPv4Multicast else { return [] }
        let low23 = (UInt32(bytes[3]) << 16) | (UInt32(bytes[4]) << 8) | UInt32(bytes[5])
        return (0..<32).map { high in
            IPv4Address(raw: 0xE000_0000 | (UInt32(high) << 23) | low23)
        }
    }
}
