import Foundation

public enum BERTag {
    public static let integer: UInt8      = 0x02
    public static let octetString: UInt8  = 0x04
    public static let null: UInt8         = 0x05
    public static let objectIdentifier: UInt8 = 0x06
    public static let sequence: UInt8     = 0x30

    // SNMP application types
    public static let ipAddress: UInt8    = 0x40
    public static let counter32: UInt8    = 0x41
    public static let gauge32: UInt8      = 0x42
    public static let timeTicks: UInt8    = 0x43
    public static let opaque: UInt8       = 0x44
    public static let counter64: UInt8    = 0x46

    // v2c exceptions, which appear in place of a value
    public static let noSuchObject: UInt8   = 0x80
    public static let noSuchInstance: UInt8 = 0x81
    public static let endOfMibView: UInt8   = 0x82

    // PDU types
    public static let getRequest: UInt8     = 0xA0
    public static let getNextRequest: UInt8 = 0xA1
    public static let response: UInt8       = 0xA2
    public static let setRequest: UInt8     = 0xA3
    public static let getBulkRequest: UInt8 = 0xA5
}

public enum BERError: Error, Equatable {
    case truncated
    case unexpectedTag(expected: UInt8, found: UInt8)
    case lengthTooLarge
    case malformed(String)
}

public enum BER {

    // MARK: - Encoding

    /// Definite-length encoding: short form below 128, long form above.
    public static func encodeLength(_ length: Int) -> [UInt8] {
        if length < 0x80 { return [UInt8(length)] }
        var bytes: [UInt8] = []
        var remaining = length
        while remaining > 0 {
            bytes.insert(UInt8(truncatingIfNeeded: remaining), at: 0)
            remaining >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    public static func encodeTLV(tag: UInt8, value: [UInt8]) -> [UInt8] {
        [tag] + encodeLength(value.count) + value
    }

    /// Minimal-length two's-complement integer.
    ///
    /// Bytes are produced least-significant first and the loop stops once what
    /// remains is all sign bits *and* the top byte already carries the right
    /// sign in its high bit. That single condition gives both the leading 0x00
    /// in front of a large positive and the leading 0xFF in front of a negative.
    public static func encodeIntegerBody(_ value: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        var remaining = value
        while true {
            let byte = UInt8(truncatingIfNeeded: remaining)
            bytes.append(byte)
            remaining >>= 8
            let signBitSet = (byte & 0x80) != 0
            if remaining == 0 && !signBitSet { break }
            if remaining == -1 && signBitSet { break }
        }
        return bytes.reversed()
    }

    public static func encodeInteger(_ value: Int) -> [UInt8] {
        encodeTLV(tag: BERTag.integer, value: encodeIntegerBody(value))
    }

    public static func encodeOctetString(_ bytes: [UInt8]) -> [UInt8] {
        encodeTLV(tag: BERTag.octetString, value: bytes)
    }

    public static func encodeOctetString(_ text: String) -> [UInt8] {
        encodeOctetString(Array(text.utf8))
    }

    public static func encodeNull() -> [UInt8] { [BERTag.null, 0x00] }

    /// Base-128, high bit set on every byte but the last. The first two arcs
    /// are packed into one subidentifier as 40 * first + second.
    public static func encodeSubidentifier(_ value: UInt32) -> [UInt8] {
        if value < 0x80 { return [UInt8(value)] }
        var bytes: [UInt8] = []
        var remaining = value
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0x7F), at: 0)
            remaining >>= 7
        }
        for index in 0..<(bytes.count - 1) { bytes[index] |= 0x80 }
        return bytes
    }

    public static func encodeOIDBody(_ oid: OID) -> [UInt8] {
        let arcs = oid.arcs
        guard arcs.count >= 2 else {
            return arcs.flatMap(encodeSubidentifier)
        }
        var bytes = encodeSubidentifier(arcs[0] * 40 + arcs[1])
        for arc in arcs.dropFirst(2) { bytes += encodeSubidentifier(arc) }
        return bytes
    }

    public static func encodeOID(_ oid: OID) -> [UInt8] {
        encodeTLV(tag: BERTag.objectIdentifier, value: encodeOIDBody(oid))
    }

    public static func encodeSequence(_ contents: [UInt8]) -> [UInt8] {
        encodeTLV(tag: BERTag.sequence, value: contents)
    }

    // MARK: - Decoding

    public struct Element: Equatable {
        public let tag: UInt8
        /// Offset of the first content byte within the original buffer.
        public let valueStart: Int
        public let valueLength: Int
        /// Offset just past this element.
        public let end: Int

        public func value(in bytes: [UInt8]) -> [UInt8] {
            Array(bytes[valueStart..<(valueStart + valueLength)])
        }
    }

    public static func readElement(_ bytes: [UInt8], at offset: Int) throws -> Element {
        guard offset < bytes.count else { throw BERError.truncated }
        let tag = bytes[offset]
        var cursor = offset + 1
        guard cursor < bytes.count else { throw BERError.truncated }

        let first = bytes[cursor]
        cursor += 1
        var length = 0
        if first < 0x80 {
            length = Int(first)
        } else {
            let byteCount = Int(first & 0x7F)
            // An indefinite length (0x80) has no place in SNMP, and a length
            // wider than Int is not something we can act on.
            guard byteCount > 0, byteCount <= 8 else { throw BERError.lengthTooLarge }
            guard cursor + byteCount <= bytes.count else { throw BERError.truncated }
            for _ in 0..<byteCount {
                length = (length << 8) | Int(bytes[cursor])
                cursor += 1
            }
        }

        guard length >= 0, cursor + length <= bytes.count else { throw BERError.truncated }
        return Element(tag: tag, valueStart: cursor, valueLength: length, end: cursor + length)
    }

    public static func expect(_ tag: UInt8, in bytes: [UInt8], at offset: Int) throws -> Element {
        let element = try readElement(bytes, at: offset)
        guard element.tag == tag else { throw BERError.unexpectedTag(expected: tag, found: element.tag) }
        return element
    }

    public static func decodeIntegerBody(_ bytes: [UInt8]) throws -> Int {
        guard !bytes.isEmpty else { throw BERError.malformed("empty integer") }
        guard bytes.count <= 8 else { throw BERError.malformed("integer too wide") }
        var value = (bytes[0] & 0x80) != 0 ? -1 : 0
        for byte in bytes { value = (value << 8) | Int(byte) }
        return value
    }

    /// Unsigned reading, for Counter32/Gauge32/Counter64 where the top bit is
    /// magnitude rather than sign.
    public static func decodeUnsignedBody(_ bytes: [UInt8]) -> UInt64 {
        var value: UInt64 = 0
        for byte in bytes.suffix(8) { value = (value << 8) | UInt64(byte) }
        return value
    }

    public static func decodeOIDBody(_ bytes: [UInt8]) throws -> OID {
        guard !bytes.isEmpty else { throw BERError.malformed("empty OID") }
        var arcs: [UInt32] = []
        var accumulator: UInt64 = 0
        var started = false

        for (index, byte) in bytes.enumerated() {
            accumulator = (accumulator << 7) | UInt64(byte & 0x7F)
            guard accumulator <= UInt64(UInt32.max) else { throw BERError.malformed("OID arc overflow") }
            if byte & 0x80 == 0 {
                let arc = UInt32(accumulator)
                if !started {
                    // Unpack the first two arcs.
                    arcs.append(min(arc / 40, 2))
                    arcs.append(arc - min(arc / 40, 2) * 40)
                    started = true
                } else {
                    arcs.append(arc)
                }
                accumulator = 0
            } else if index == bytes.count - 1 {
                throw BERError.malformed("OID ends mid-subidentifier")
            }
        }
        return OID(arcs)
    }
}
