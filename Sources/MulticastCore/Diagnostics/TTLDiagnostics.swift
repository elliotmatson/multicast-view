import Foundation

public enum TTLDiagnostics {
    /// TTL 1 means the first router drops the packet. On a routable group that
    /// is the usual reason a stream works on one VLAN and not another.
    ///
    /// It is not reported for 224.0.0.0/24 or for routing-plane traffic, where
    /// TTL 1 is exactly right. For the discovery protocols whose specs call for
    /// a small TTL -- SSDP, mDNS, LLMNR, SLP -- it is reported as information
    /// rather than a warning, so the panel does not cry wolf on every network.
    public static func diagnose(_ stream: StreamSnapshot) -> Diagnostic? {
        guard stream.ttl == 1 else { return nil }
        guard !stream.key.group.isLinkLocalControl else { return nil }
        guard stream.identity.family != .routing else { return nil }

        let expected = isLinkLocalByDesign(stream.identity)
        let where_ = "\(stream.key.group):\(stream.key.portText) from \(stream.key.source)"

        if expected {
            return Diagnostic(
                id: "ttl1.\(stream.key.group).\(stream.key.source).\(stream.key.portText)",
                severity: .info,
                title: "TTL 1 on \(where_)",
                detail: "This will not cross a router. For \(stream.identity.name) that is normal: it is "
                      + "meant to stay on the local segment, and crossing VLANs is handled by a relay or "
                      + "a boundary clock rather than by multicast routing.")
        }

        return Diagnostic(
            id: "ttl1.\(stream.key.group).\(stream.key.source).\(stream.key.portText)",
            severity: .warning,
            title: "TTL 1 on routable group \(where_)",
            detail: "\(stream.identity.displayText) is being sent with TTL 1, so the first router drops "
                  + "it. This is the usual reason a stream works on one VLAN and not another. "
                  + "Raise the sender's multicast TTL if this stream is meant to be routed.")
    }

    /// Protocols whose normal, correct operation uses a TTL that will not
    /// cross a router. Reporting these as warnings would mean a warning on
    /// every network, every time -- which trains you to ignore the panel.
    static func isLinkLocalByDesign(_ identity: StreamIdentity) -> Bool {
        if identity.family == .discovery { return true }
        // PTP is normally kept inside one L2 domain, with boundary clocks
        // rather than multicast routing between VLANs. TTL 1 is the norm.
        if identity.name.hasPrefix("PTP") { return true }
        return false
    }

    /// Warnings are reported one per stream, because each is a separate thing
    /// to go and fix. The "this is normal" notes are collapsed into a single
    /// line: twenty green banners saying SSDP is behaving push the findings
    /// that matter off the screen, which is how a panel gets ignored.
    public static func diagnose(_ streams: [StreamSnapshot]) -> [Diagnostic] {
        var warnings: [Diagnostic] = []
        var expected: [StreamSnapshot] = []

        for stream in streams {
            guard let diagnostic = diagnose(stream) else { continue }
            if diagnostic.severity == .info { expected.append(stream) } else { warnings.append(diagnostic) }
        }

        warnings.sort { $0.id < $1.id }

        guard !expected.isEmpty else { return warnings }

        var names: [String] = []
        for stream in expected where !names.contains(stream.identity.name) {
            names.append(stream.identity.name)
        }
        names.sort()

        warnings.append(Diagnostic(
            id: "ttl1.expected",
            severity: .info,
            title: "TTL 1 on \(expected.count) stream\(expected.count == 1 ? "" : "s") where that is normal",
            detail: "\(names.joined(separator: ", ")) are meant to stay on the local segment, so a TTL "
                  + "that will not cross a router is correct. Listed here only so the count is not "
                  + "mistaken for a fault; the TTL column shows which streams these are."))
        return warnings
    }

}
