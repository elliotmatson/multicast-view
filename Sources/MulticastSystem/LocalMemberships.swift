import Foundation
import Darwin
import MulticastCore

/// Which multicast groups this Mac has joined, and on which interface.
///
/// Uses getifmaddrs(3) rather than parsing `netstat -gn`: the same data, with
/// no subprocess and no text format that can change underneath us.
///
/// The interface column exists because of a specific macOS behaviour: the
/// system joins multicast on the interface with the lowest-metric default
/// route, which is very often not the AV network. A Mac with Wi-Fi up and a
/// Thunderbolt adapter on the Dante VLAN will happily join over Wi-Fi and
/// silently receive nothing.
public enum LocalMemberships {

    public static func current() -> [LocalMembership] {
        var head: UnsafeMutablePointer<ifmaddrs>?
        guard getifmaddrs(&head) == 0, head != nil else { return [] }
        defer { freeifmaddrs(head) }

        var result: [LocalMembership] = []
        var seen = Set<LocalMembership>()
        var cursor = head

        while let entry = cursor {
            defer { cursor = entry.pointee.ifma_next }

            // ifma_name is an AF_LINK sockaddr_dl; the interface name is inside
            // sdl_data and is sdl_nlen bytes long, with no terminator.
            guard let namePointer = entry.pointee.ifma_name,
                  Int32(namePointer.pointee.sa_family) == AF_LINK,
                  let interfaceName = interfaceName(from: namePointer)
            else { continue }

            guard let addressPointer = entry.pointee.ifma_addr,
                  Int32(addressPointer.pointee.sa_family) == AF_INET
            else { continue }

            let group = addressPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                IPv4Address(raw: UInt32(bigEndian: pointer.pointee.sin_addr.s_addr))
            }
            guard group.isMulticast else { continue }

            let membership = LocalMembership(group: group, interfaceName: interfaceName)
            if seen.insert(membership).inserted { result.append(membership) }
        }

        return result.sorted { lhs, rhs in
            lhs.interfaceName == rhs.interfaceName
                ? lhs.group < rhs.group
                : lhs.interfaceName.localizedStandardCompare(rhs.interfaceName) == .orderedAscending
        }
    }

    private static func interfaceName(from pointer: UnsafeMutablePointer<sockaddr>) -> String? {
        pointer.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { link in
            let length = Int(link.pointee.sdl_nlen)
            guard length > 0, length <= 64 else { return nil }
            return withUnsafePointer(to: link.pointee.sdl_data) { dataPointer in
                dataPointer.withMemoryRebound(to: UInt8.self, capacity: length) { bytes in
                    String(decoding: UnsafeBufferPointer(start: bytes, count: length), as: UTF8.self)
                }
            }
        }
    }
}
