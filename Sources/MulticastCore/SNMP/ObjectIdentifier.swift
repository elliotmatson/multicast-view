import Foundation

/// An SNMP object identifier.
public struct OID: Hashable, Comparable, CustomStringConvertible, Sendable {
    public let arcs: [UInt32]

    public init(_ arcs: [UInt32]) { self.arcs = arcs }

    public init?(_ text: String) {
        let trimmed = text.hasPrefix(".") ? String(text.dropFirst()) : text
        let parts = trimmed.split(separator: ".")
        guard !parts.isEmpty else { return nil }
        var values: [UInt32] = []
        for part in parts {
            guard let value = UInt32(part) else { return nil }
            values.append(value)
        }
        arcs = values
    }

    public var description: String { arcs.map(String.init).joined(separator: ".") }

    /// True when `self` is at or below `prefix` in the tree. A walk ends when
    /// this stops being true.
    public func isWithin(_ prefix: OID) -> Bool {
        guard arcs.count >= prefix.arcs.count else { return false }
        for index in 0..<prefix.arcs.count where arcs[index] != prefix.arcs[index] { return false }
        return true
    }

    /// The arcs below `prefix`, i.e. the table index.
    public func suffix(after prefix: OID) -> [UInt32]? {
        guard isWithin(prefix) else { return nil }
        return Array(arcs.dropFirst(prefix.arcs.count))
    }

    /// Lexicographic order, which is the order an agent walks in. A response
    /// that does not advance in this order means the agent is misbehaving, and
    /// continuing would loop forever.
    public static func < (lhs: OID, rhs: OID) -> Bool {
        for index in 0..<min(lhs.arcs.count, rhs.arcs.count) {
            if lhs.arcs[index] != rhs.arcs[index] { return lhs.arcs[index] < rhs.arcs[index] }
        }
        return lhs.arcs.count < rhs.arcs.count
    }

    public func appending(_ more: [UInt32]) -> OID { OID(arcs + more) }
}
