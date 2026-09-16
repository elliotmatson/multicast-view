import Foundation

/// A site-specific classification rule.
///
/// No catalogue can cover every deployment: vendors pick ports that are not
/// registered, and plenty of gear only documents its multicast addresses in a
/// PDF. A rule here labels traffic the way your site actually uses it, and is
/// consulted before the built-in catalogue.
public struct CustomClassificationRule: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var detail: String?
    public var family: ProtocolFamily
    public var isEnabled: Bool

    /// Lowest destination port this rule matches. Nil means "any port".
    public var portLow: UInt16?
    /// Highest destination port. Nil with a portLow set means that one port.
    public var portHigh: UInt16?
    /// Group address prefix, e.g. "239.100.0.0". Nil means "any group".
    public var groupPrefix: String?
    public var prefixLength: Int?

    public init(id: UUID = UUID(), name: String, detail: String? = nil,
                family: ProtocolFamily = .unknown, isEnabled: Bool = true,
                portLow: UInt16? = nil, portHigh: UInt16? = nil,
                groupPrefix: String? = nil, prefixLength: Int? = nil) {
        self.id = id
        self.name = name
        self.detail = detail
        self.family = family
        self.isEnabled = isEnabled
        self.portLow = portLow
        self.portHigh = portHigh
        self.groupPrefix = groupPrefix
        self.prefixLength = prefixLength
    }

    /// A rule with neither a port nor an address would match everything.
    public var isUsable: Bool {
        guard isEnabled, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return portLow != nil || (groupPrefix != nil && prefixLength != nil)
    }

    public func matches(group: IPv4Address, destinationPort: UInt16?) -> Bool {
        guard isUsable else { return false }

        if let low = portLow {
            guard let port = destinationPort else { return false }
            let high = portHigh ?? low
            guard port >= min(low, high), port <= max(low, high) else { return false }
        }

        if let prefixText = groupPrefix, let length = prefixLength {
            guard let base = IPv4Address(prefixText), (0...32).contains(length) else { return false }
            guard group.inSubnet(base, prefix: length) else { return false }
        }

        return true
    }

    public var summary: String {
        var parts: [String] = []
        if let low = portLow {
            let high = portHigh ?? low
            parts.append(low == high ? "port \(low)" : "ports \(low)-\(high)")
        }
        if let prefix = groupPrefix, let length = prefixLength {
            parts.append("\(prefix)/\(length)")
        }
        return parts.isEmpty ? "matches nothing" : parts.joined(separator: " in ")
    }

    public func identity() -> StreamIdentity {
        StreamIdentity(name: name, detail: detail, family: family, confidence: .certain,
                       reason: "Matched your own rule \u{201C}\(name)\u{201D} (\(summary)).")
    }
}
