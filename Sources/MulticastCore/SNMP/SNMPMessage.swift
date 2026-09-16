import Foundation

public enum SNMPValue: Equatable {
    case integer(Int)
    case octetString([UInt8])
    case objectIdentifier(OID)
    case ipAddress(IPv4Address)
    case counter32(UInt64)
    case gauge32(UInt64)
    case timeTicks(UInt64)
    case counter64(UInt64)
    case null
    case noSuchObject
    case noSuchInstance
    case endOfMibView
    case unsupported(tag: UInt8, bytes: [UInt8])

    /// True for the markers that mean "walk no further down this branch".
    public var isEndOfView: Bool {
        switch self {
        case .endOfMibView, .noSuchObject, .noSuchInstance: return true
        default: return false
        }
    }

    public var octets: [UInt8]? {
        if case .octetString(let bytes) = self { return bytes }
        return nil
    }
}

public struct VariableBinding: Equatable {
    public let oid: OID
    public let value: SNMPValue

    public init(oid: OID, value: SNMPValue) {
        self.oid = oid
        self.value = value
    }
}

public enum SNMPErrorStatus: Int, Equatable {
    case noError = 0, tooBig, noSuchName, badValue, readOnly, genErr
    case noAccess, wrongType, wrongLength, wrongEncoding, wrongValue
    case noCreation, inconsistentValue, resourceUnavailable, commitFailed
    case undoFailed, authorizationError, notWritable, inconsistentName
}

public struct SNMPResponse: Equatable {
    public let requestID: Int
    public let errorStatus: Int
    public let errorIndex: Int
    public let bindings: [VariableBinding]

    public init(requestID: Int, errorStatus: Int, errorIndex: Int, bindings: [VariableBinding]) {
        self.requestID = requestID
        self.errorStatus = errorStatus
        self.errorIndex = errorIndex
        self.bindings = bindings
    }

    public var error: SNMPErrorStatus? {
        errorStatus == 0 ? nil : SNMPErrorStatus(rawValue: errorStatus) ?? .genErr
    }
}

/// SNMPv2c message building and parsing. No net-snmp, no subprocess.
public enum SNMPMessage {
    public static let version2c = 1      // the version field is 1 for v2c

    /// A GetBulk request.
    ///
    /// GetBulk rather than repeated GetNext: a switch with a few hundred
    /// forwarding entries would otherwise be a few hundred round trips, which
    /// is slow enough to notice on a 30-second poll.
    public static func encodeGetBulk(community: String,
                                     requestID: Int,
                                     nonRepeaters: Int = 0,
                                     maxRepetitions: Int,
                                     oids: [OID]) -> [UInt8] {
        var bindings: [UInt8] = []
        for oid in oids {
            bindings += BER.encodeSequence(BER.encodeOID(oid) + BER.encodeNull())
        }

        var pdu: [UInt8] = []
        pdu += BER.encodeInteger(requestID)
        pdu += BER.encodeInteger(nonRepeaters)      // error-status slot reused
        pdu += BER.encodeInteger(maxRepetitions)    // error-index slot reused
        pdu += BER.encodeSequence(bindings)

        var message: [UInt8] = []
        message += BER.encodeInteger(version2c)
        message += BER.encodeOctetString(community)
        message += BER.encodeTLV(tag: BERTag.getBulkRequest, value: pdu)
        return BER.encodeSequence(message)
    }

    public static func encodeGet(community: String, requestID: Int, oids: [OID]) -> [UInt8] {
        var bindings: [UInt8] = []
        for oid in oids {
            bindings += BER.encodeSequence(BER.encodeOID(oid) + BER.encodeNull())
        }
        var pdu: [UInt8] = []
        pdu += BER.encodeInteger(requestID)
        pdu += BER.encodeInteger(0)     // error-status
        pdu += BER.encodeInteger(0)     // error-index
        pdu += BER.encodeSequence(bindings)

        var message: [UInt8] = []
        message += BER.encodeInteger(version2c)
        message += BER.encodeOctetString(community)
        message += BER.encodeTLV(tag: BERTag.getRequest, value: pdu)
        return BER.encodeSequence(message)
    }

    public static func decodeResponse(_ bytes: [UInt8]) throws -> SNMPResponse {
        let envelope = try BER.expect(BERTag.sequence, in: bytes, at: 0)
        var cursor = envelope.valueStart

        let version = try BER.expect(BERTag.integer, in: bytes, at: cursor)
        cursor = version.end
        let community = try BER.expect(BERTag.octetString, in: bytes, at: cursor)
        cursor = community.end

        let pdu = try BER.readElement(bytes, at: cursor)
        guard pdu.tag == BERTag.response else {
            throw BERError.unexpectedTag(expected: BERTag.response, found: pdu.tag)
        }
        cursor = pdu.valueStart

        let requestID = try BER.expect(BERTag.integer, in: bytes, at: cursor)
        cursor = requestID.end
        let errorStatus = try BER.expect(BERTag.integer, in: bytes, at: cursor)
        cursor = errorStatus.end
        let errorIndex = try BER.expect(BERTag.integer, in: bytes, at: cursor)
        cursor = errorIndex.end

        let bindingList = try BER.expect(BERTag.sequence, in: bytes, at: cursor)
        var bindings: [VariableBinding] = []
        var position = bindingList.valueStart
        let limit = bindingList.valueStart + bindingList.valueLength

        while position < limit {
            let binding = try BER.expect(BERTag.sequence, in: bytes, at: position)
            let oidElement = try BER.expect(BERTag.objectIdentifier, in: bytes, at: binding.valueStart)
            let oid = try BER.decodeOIDBody(oidElement.value(in: bytes))
            let valueElement = try BER.readElement(bytes, at: oidElement.end)
            bindings.append(VariableBinding(oid: oid, value: try decodeValue(valueElement, in: bytes)))
            position = binding.end
        }

        return SNMPResponse(requestID: try BER.decodeIntegerBody(requestID.value(in: bytes)),
                            errorStatus: try BER.decodeIntegerBody(errorStatus.value(in: bytes)),
                            errorIndex: try BER.decodeIntegerBody(errorIndex.value(in: bytes)),
                            bindings: bindings)
    }

    private static func decodeValue(_ element: BER.Element, in bytes: [UInt8]) throws -> SNMPValue {
        let body = element.value(in: bytes)
        switch element.tag {
        case BERTag.integer:          return .integer(try BER.decodeIntegerBody(body))
        case BERTag.octetString:      return .octetString(body)
        case BERTag.objectIdentifier: return .objectIdentifier(try BER.decodeOIDBody(body))
        case BERTag.null:             return .null
        case BERTag.counter32:        return .counter32(BER.decodeUnsignedBody(body))
        case BERTag.gauge32:          return .gauge32(BER.decodeUnsignedBody(body))
        case BERTag.timeTicks:        return .timeTicks(BER.decodeUnsignedBody(body))
        case BERTag.counter64:        return .counter64(BER.decodeUnsignedBody(body))
        case BERTag.ipAddress:
            guard body.count == 4 else { throw BERError.malformed("IpAddress must be 4 bytes") }
            return .ipAddress(IPv4Address(body[0], body[1], body[2], body[3]))
        case BERTag.noSuchObject:     return .noSuchObject
        case BERTag.noSuchInstance:   return .noSuchInstance
        case BERTag.endOfMibView:     return .endOfMibView
        default:                      return .unsupported(tag: element.tag, bytes: body)
        }
    }
}
