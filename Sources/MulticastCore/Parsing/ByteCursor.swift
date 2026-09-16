import Foundation

/// Bounds-checked big-endian reads over a raw buffer.
///
/// Every accessor returns nil rather than trapping. This is a live network:
/// a runt frame, a truncated capture or a deliberately malformed packet must
/// produce "couldn't parse that one" and never take the capture down.
public struct ByteCursor {
    public let bytes: UnsafeRawBufferPointer

    public init(_ bytes: UnsafeRawBufferPointer) { self.bytes = bytes }

    public var count: Int { bytes.count }

    public func byte(at offset: Int) -> UInt8? {
        guard offset >= 0, offset < bytes.count else { return nil }
        return bytes[offset]
    }

    public func uint16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        return (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    public func uint32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
             | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }

    public func address(at offset: Int) -> IPv4Address? {
        guard let raw = uint32(at: offset) else { return nil }
        return IPv4Address(raw: raw)
    }

    public func mac(at offset: Int) -> MACAddress? {
        guard offset >= 0, offset + 6 <= bytes.count else { return nil }
        return MACAddress(bytes: [bytes[offset], bytes[offset + 1], bytes[offset + 2],
                                  bytes[offset + 3], bytes[offset + 4], bytes[offset + 5]])
    }
}

public extension Array where Element == UInt8 {
    /// Convenience for tests, which build frames as byte arrays.
    func withCursor<R>(_ body: (ByteCursor) throws -> R) rethrows -> R {
        try withUnsafeBytes { try body(ByteCursor($0)) }
    }
}
