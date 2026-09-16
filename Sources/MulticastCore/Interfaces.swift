import Foundation

public enum InterfaceKind: String, Sendable {
    case wired
    case wireless
    /// Apple Wireless Direct Link -- AirDrop, Sidecar, Handoff.
    case appleWirelessDirect
    case vpn
    /// A VLAN sub-interface, e.g. vlan1 on top of en7.
    case vlan
    case loopback
    case virtual
    case other
}

public struct NetworkInterfaceInfo: Identifiable, Equatable, Sendable {
    public let name: String
    /// The name the system gives it, e.g. "Thunderbolt Ethernet Slot 1".
    public let displayName: String?
    public let isUp: Bool
    public let supportsMulticast: Bool
    public let isLoopback: Bool
    public let isWireless: Bool
    public let addresses: [IPv4Address]
    public let macAddress: MACAddress?

    public var id: String { name }

    public init(name: String, displayName: String? = nil, isUp: Bool, supportsMulticast: Bool,
                isLoopback: Bool, isWireless: Bool, addresses: [IPv4Address], macAddress: MACAddress?) {
        self.name = name
        self.displayName = displayName
        self.isUp = isUp
        self.supportsMulticast = supportsMulticast
        self.isLoopback = isLoopback
        self.isWireless = isWireless
        self.addresses = addresses
        self.macAddress = macAddress
    }

    public var kind: InterfaceKind { InterfaceAdvice.kind(for: name, isWireless: isWireless, isLoopback: isLoopback) }

    public var title: String {
        guard let displayName, !displayName.isEmpty, displayName != name else { return name }
        return "\(name) \u{2014} \(displayName)"
    }
}

public enum InterfaceAdvice {
    public static func kind(for name: String, isWireless: Bool = false, isLoopback: Bool = false) -> InterfaceKind {
        if isLoopback || name == "lo0" { return .loopback }
        if name.hasPrefix("awdl") || name.hasPrefix("llw") { return .appleWirelessDirect }
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") { return .vpn }
        if name.hasPrefix("vlan") { return .vlan }
        if name.hasPrefix("bridge") || name.hasPrefix("vmenet") || name.hasPrefix("anpi")
            || name.hasPrefix("ap") || name.hasPrefix("vnic") { return .virtual }
        if isWireless { return .wireless }
        if name.hasPrefix("en") { return .wired }
        return .other
    }

    /// Interfaces whose traffic will bury what you are looking for, or which
    /// cannot carry AV multicast at all.
    public static func isNoiseInterface(_ name: String) -> Bool {
        switch kind(for: name) {
        case .appleWirelessDirect, .vpn, .loopback, .virtual: return true
        case .wired, .wireless, .vlan, .other: return false
        }
    }

    /// Shown beside the interface in the picker.
    public static func warning(for interface: NetworkInterfaceInfo) -> String? {
        switch interface.kind {
        case .appleWirelessDirect:
            return "Apple Wireless Direct Link. Constant multicast chatter that buries real AV traffic "
                 + "-- the most common reason a Mac capture looks unreadable."
        case .vpn:
            return "VPN tunnel. Carries no local AV multicast."
        case .loopback:
            return "Loopback. Only this Mac's own traffic."
        case .virtual:
            return "Virtual interface. Unlikely to carry AV multicast."
        case .vlan:
            return "VLAN sub-interface. You will see only this VLAN, already untagged. "
                 + "Capturing on the parent interface instead shows every VLAN on the trunk, tagged."
        case .wireless:
            return "Wi-Fi. Multicast over Wi-Fi is rate-limited and unreliable; AV networks are wired."
        case .wired, .other:
            return nil
        }
    }

    /// Picks a sensible default: a live, multicast-capable wired interface that
    /// isn't en0. On a Mac the AV network is nearly always a Thunderbolt or USB
    /// adapter, and en0 is the built-in port or Wi-Fi.
    public static func preferredInterface(from interfaces: [NetworkInterfaceInfo]) -> NetworkInterfaceInfo? {
        let usable = interfaces.filter { interface in
            interface.isUp && interface.supportsMulticast && !interface.isLoopback
                && !isNoiseInterface(interface.name)
        }
        guard !usable.isEmpty else { return nil }

        func score(_ interface: NetworkInterfaceInfo) -> Int {
            var value = 0
            if !interface.isWireless { value += 8 }
            // A VLAN sub-interface is a narrower view than its parent, so it is
            // the second choice when both are available.
            if interface.kind != .vlan { value += 1 }
            if interface.name != "en0" { value += 4 }
            if !interface.addresses.isEmpty { value += 2 }
            return value
        }

        return usable.sorted { lhs, rhs in
            let (left, right) = (score(lhs), score(rhs))
            if left != right { return left > right }
            return lhs.name < rhs.name      // stable
        }.first
    }
}
