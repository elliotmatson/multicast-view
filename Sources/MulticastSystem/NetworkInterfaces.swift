import Foundation
import Darwin
import SystemConfiguration
import MulticastCore

public enum NetworkInterfaces {

    /// Every interface the system knows about, with the detail the picker needs.
    public static func all() -> [NetworkInterfaceInfo] {
        var byName: [String: Builder] = [:]

        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let name = String(cString: entry.pointee.ifa_name)
            let flags = Int32(entry.pointee.ifa_flags)

            var builder = byName[name] ?? Builder(name: name)
            builder.isUp = (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0
            builder.supportsMulticast = (flags & IFF_MULTICAST) != 0
            builder.isLoopback = (flags & IFF_LOOPBACK) != 0

            if let address = entry.pointee.ifa_addr {
                switch Int32(address.pointee.sa_family) {
                case AF_INET:
                    address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                        // sin_addr is network order; IPv4Address holds host order.
                        builder.addresses.append(IPv4Address(raw: UInt32(bigEndian: pointer.pointee.sin_addr.s_addr)))
                    }
                case AF_LINK:
                    address.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { pointer in
                        builder.macAddress = linkLayerAddress(pointer)
                    }
                default:
                    break
                }
            }
            byName[name] = builder
        }

        let described = systemDescriptions()
        return byName.values
            .map { builder in
                let description = described[builder.name]
                return NetworkInterfaceInfo(name: builder.name,
                                            displayName: description?.displayName,
                                            isUp: builder.isUp,
                                            supportsMulticast: builder.supportsMulticast,
                                            isLoopback: builder.isLoopback,
                                            isWireless: description?.isWireless ?? false,
                                            addresses: builder.addresses,
                                            macAddress: builder.macAddress)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private struct Builder {
        let name: String
        var isUp = false
        var supportsMulticast = false
        var isLoopback = false
        var addresses: [IPv4Address] = []
        var macAddress: MACAddress?
    }

    private struct Description {
        let displayName: String?
        let isWireless: Bool
    }

    /// Localized names like "Thunderbolt Ethernet Slot 1", and whether the
    /// interface is Wi-Fi. Neither can be worked out from getifaddrs alone.
    private static func systemDescriptions() -> [String: Description] {
        var result: [String: Description] = [:]
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return result }
        for interface in interfaces {
            guard let bsdName = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
            let displayName = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
            let type = SCNetworkInterfaceGetInterfaceType(interface) as String?
            let isWireless = type == (kSCNetworkInterfaceTypeIEEE80211 as String)
            result[bsdName] = Description(displayName: displayName, isWireless: isWireless)
        }
        return result
    }

    /// The MAC lives inside sdl_data, after sdl_nlen bytes of interface name.
    private static func linkLayerAddress(_ pointer: UnsafePointer<sockaddr_dl>) -> MACAddress? {
        let nameLength = Int(pointer.pointee.sdl_nlen)
        let addressLength = Int(pointer.pointee.sdl_alen)
        guard addressLength == 6 else { return nil }
        // Recent macOS hands out 02:00:00:00:00:00 instead of the real address
        // to anything without the matching entitlement. Reporting that as the
        // interface's MAC would be worse than reporting nothing.

        return withUnsafePointer(to: pointer.pointee.sdl_data) { dataPointer in
            dataPointer.withMemoryRebound(to: UInt8.self, capacity: nameLength + addressLength) { bytes in
                var octets: [UInt8] = []
                for index in 0..<addressLength { octets.append(bytes[nameLength + index]) }
                if octets == [0x02, 0x00, 0x00, 0x00, 0x00, 0x00] { return nil }
                return MACAddress(bytes: octets)
            }
        }
    }
}
