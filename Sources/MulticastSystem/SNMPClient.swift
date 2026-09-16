import Foundation
import Darwin
import MulticastCore

public struct SNMPSwitch: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var community: String
    public var isEnabled: Bool

    public init(id: UUID = UUID(), name: String = "", host: String = "",
                community: String = "public", isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.host = host
        self.community = community
        self.isEnabled = isEnabled
    }

    public var displayName: String { name.isEmpty ? host : name }
    public var isUsable: Bool { isEnabled && !host.trimmingCharacters(in: .whitespaces).isEmpty }
}

public enum SNMPClientError: Error, LocalizedError {
    case badHost(String)
    case socketFailed(errno: Int32)
    case timedOut
    case sendFailed(errno: Int32)
    case agentError(SNMPErrorStatus)
    case decode(Error)

    public var errorDescription: String? {
        switch self {
        case .badHost(let host):    return "Could not resolve \(host)"
        case .socketFailed(let e):  return "Socket error: \(String(cString: strerror(e)))"
        case .timedOut:             return "No response (check the community string and that SNMP is enabled)"
        case .sendFailed(let e):    return "Send failed: \(String(cString: strerror(e)))"
        case .agentError(let s):    return "The agent returned \(s)"
        case .decode(let e):        return "Malformed response: \(e)"
        }
    }
}

/// SNMPv2c over UDP 161, implemented directly. No net-snmp, no snmpwalk
/// subprocess, nothing to install on the machine.
public final class SNMPClient {
    public struct Options {
        public var port: UInt16 = 161
        public var timeout: TimeInterval = 2
        public var retries: Int = 1
        /// GetBulk max-repetitions. Higher means fewer round trips, but a
        /// response large enough to fragment is counter-productive.
        public var maxRepetitions: Int = 25
        /// Hard ceiling on rows, so a huge table cannot stall a poll.
        public var rowLimit: Int = 5000

        public init() {}
    }

    public var options: Options
    private var requestCounter = Int.random(in: 1...100_000)

    public init(options: Options = Options()) {
        self.options = options
    }

    // MARK: - Public API

    /// Reads a switch's multicast forwarding table.
    ///
    /// The generic Q-BRIDGE table is tried first; if it comes back empty,
    /// Cisco's equivalent is tried. UniFi exposes very little here -- an empty
    /// result from a UniFi switch is a known limitation of the switch, not a
    /// failure of this poll.
    public func fetchForwarding(from device: SNMPSwitch) throws -> [GroupForwarding] {
        let generic = try walk(host: device.host, community: device.community,
                               subtree: QBridgeMIB.groupEgressPorts)
        var rows = forwardingRows(from: generic, subtree: QBridgeMIB.groupEgressPorts, device: device)
        if rows.isEmpty {
            let cisco = try walk(host: device.host, community: device.community,
                                 subtree: QBridgeMIB.ciscoGroupEgressPorts)
            rows = forwardingRows(from: cisco, subtree: QBridgeMIB.ciscoGroupEgressPorts, device: device)
        }
        return rows
    }

    public func fetchSystemName(from device: SNMPSwitch) throws -> String? {
        let response = try exchange(host: device.host,
                                    payload: SNMPMessage.encodeGet(community: device.community,
                                                                   requestID: nextRequestID(),
                                                                   oids: [QBridgeMIB.sysName]))
        guard let binding = response.bindings.first, let octets = binding.value.octets else { return nil }
        return String(decoding: octets, as: UTF8.self)
    }

    private func forwardingRows(from bindings: [VariableBinding], subtree: OID,
                                device: SNMPSwitch) -> [GroupForwarding] {
        var rows: [GroupForwarding] = []
        for binding in bindings {
            guard let suffix = binding.oid.suffix(after: subtree),
                  let index = QBridgeIndex.parse(suffix),
                  let bitmap = binding.value.octets
            else { continue }
            guard index.mac.isIPv4Multicast else { continue }
            rows.append(GroupForwarding(switchName: device.displayName, vlan: index.vlan,
                                        mac: index.mac, ports: PortList.ports(from: bitmap)))
        }
        return rows
    }

    // MARK: - Walk

    /// GetBulk rather than repeated GetNext. A switch with a few hundred
    /// forwarding entries would otherwise be a few hundred round trips, which
    /// is slow enough to notice on a 30-second poll.
    public func walk(host: String, community: String, subtree: OID) throws -> [VariableBinding] {
        var collected: [VariableBinding] = []
        var cursor = subtree
        var previous: OID?

        while collected.count < options.rowLimit {
            let payload = SNMPMessage.encodeGetBulk(community: community,
                                                    requestID: nextRequestID(),
                                                    maxRepetitions: options.maxRepetitions,
                                                    oids: [cursor])
            let response = try exchange(host: host, payload: payload)
            if let error = response.error {
                // An agent that does not implement the table answers with
                // noSuchName rather than an empty list. That is not fatal.
                if error == .noSuchName { break }
                throw SNMPClientError.agentError(error)
            }
            guard !response.bindings.isEmpty else { break }

            var finished = false
            for binding in response.bindings {
                switch SNMPWalk.evaluate(binding: binding, subtree: subtree, previous: previous) {
                case .notFinished:
                    collected.append(binding)
                    previous = binding.oid
                    cursor = binding.oid
                case .leftSubtree, .endOfMibView, .didNotAdvance, .agentError:
                    // Leaving the subtree, endOfMibView, or a response that
                    // failed to advance lexicographically. The last of those is
                    // what stops an infinite loop against a broken agent.
                    finished = true
                }
                if finished { break }
                if collected.count >= options.rowLimit { finished = true; break }
            }
            if finished { break }
        }
        return collected
    }

    // MARK: - Transport

    private func nextRequestID() -> Int {
        requestCounter = (requestCounter &+ 1) & 0x7FFF_FFFF
        return requestCounter
    }

    private func exchange(host: String, payload: [UInt8]) throws -> SNMPResponse {
        var lastError: SNMPClientError = .timedOut
        for _ in 0...max(0, options.retries) {
            do {
                let data = try sendAndReceive(host: host, payload: payload)
                do {
                    return try SNMPMessage.decodeResponse(data)
                } catch {
                    throw SNMPClientError.decode(error)
                }
            } catch let error as SNMPClientError {
                lastError = error
                if case .timedOut = error { continue }
                throw error
            }
        }
        throw lastError
    }

    private func sendAndReceive(host: String, payload: [UInt8]) throws -> [UInt8] {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = options.port.bigEndian
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        if inet_pton(AF_INET, host, &address.sin_addr) != 1 {
            // Not a literal address; resolve it.
            guard let resolved = resolve(host: host) else { throw SNMPClientError.badHost(host) }
            address.sin_addr = resolved
        }

        let socketDescriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketDescriptor >= 0 else { throw SNMPClientError.socketFailed(errno: errno) }
        defer { close(socketDescriptor) }

        var timeout = timeval(tv_sec: Int(options.timeout),
                              tv_usec: Int32((options.timeout - Double(Int(options.timeout))) * 1_000_000))
        setsockopt(socketDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let sent = payload.withUnsafeBytes { buffer -> Int in
            withUnsafePointer(to: &address) { addressPointer in
                addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                    sendto(socketDescriptor, buffer.baseAddress, buffer.count, 0,
                           generic, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == payload.count else { throw SNMPClientError.sendFailed(errno: errno) }

        var response = [UInt8](repeating: 0, count: 65535)
        let received = response.withUnsafeMutableBytes { buffer -> Int in
            recvfrom(socketDescriptor, buffer.baseAddress, buffer.count, 0, nil, nil)
        }
        guard received > 0 else { throw SNMPClientError.timedOut }
        return Array(response[0..<received])
    }

    private func resolve(host: String) -> in_addr? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM,
                             ai_protocol: IPPROTO_UDP, ai_addrlen: 0,
                             ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(result) }
        guard let address = first.pointee.ai_addr else { return nil }
        return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
    }
}
