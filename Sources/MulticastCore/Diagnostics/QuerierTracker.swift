import Foundation

public struct QuerierRecord: Identifiable, Equatable, Sendable {
    public let address: IPv4Address
    /// The sender's MAC. Needed because an L2 switch acting as querier very
    /// often sends from 0.0.0.0: without the MAC, two such switches look like
    /// one querier and the duplicate-querier fault stays invisible.
    public let sourceMAC: MACAddress?
    /// The VLAN the query was tagged with. There must be one querier per VLAN,
    /// so queriers can only be counted within a VLAN, never across them.
    public let vlan: UInt16?
    public var queryCount: Int
    public var generalQueryCount: Int
    public var firstSeen: Double
    public var lastSeen: Double

    public init(address: IPv4Address, sourceMAC: MACAddress? = nil, vlan: UInt16? = nil,
                queryCount: Int, generalQueryCount: Int, firstSeen: Double, lastSeen: Double) {
        self.address = address
        self.sourceMAC = sourceMAC
        self.vlan = vlan
        self.queryCount = queryCount
        self.generalQueryCount = generalQueryCount
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }

    public var id: String { "\(vlan.map(String.init) ?? "-")/\(address)/\(sourceMAC?.description ?? "-")" }

    public var vlanText: String { vlan.map { "VLAN \($0)" } ?? "untagged" }

    /// How to name this querier in the UI.
    public var displayName: String {
        guard address == .unspecified else { return address.description }
        guard let sourceMAC else { return "0.0.0.0 (unknown sender)" }
        return "0.0.0.0 via \(sourceMAC)"
    }

    /// A querier sending from 0.0.0.0 is a switch rather than a router. Legal,
    /// and common, but worth saying out loud because it changes what to look
    /// for when there turns out to be more than one.
    public var isAddresslessSwitch: Bool { address == .unspecified }
}

/// Watches who is sending IGMP queries.
///
/// There must be exactly one querier per VLAN. Two switches both configured as
/// querier, or a querier fighting a router, makes membership tables flush
/// unpredictably -- which presents as dropouts nobody can reproduce afterwards.
/// With no querier at all, memberships simply age out and streams stop.
public final class QuerierTracker {
    /// A querier not heard from within this long is treated as gone. The IGMP
    /// default query interval is 125s, so this allows for one missed query.
    public var activeWindow: Double
    /// How long to wait after the capture starts before complaining that no
    /// querier has been heard. One query interval plus a margin.
    public var silenceGrace: Double

    private var records: [String: QuerierRecord] = [:]

    public init(activeWindow: Double = 260, silenceGrace: Double = 130) {
        self.activeWindow = activeWindow
        self.silenceGrace = silenceGrace
    }

    public func record(source: IPv4Address, sourceMAC: MACAddress? = nil, vlan: UInt16? = nil,
                       isGeneralQuery: Bool, at timestamp: Double) {
        let key = "\(vlan.map(String.init) ?? "-")/\(source)/\(sourceMAC?.description ?? "-")"
        if var existing = records[key] {
            existing.queryCount += 1
            if isGeneralQuery { existing.generalQueryCount += 1 }
            existing.lastSeen = timestamp
            records[key] = existing
        } else {
            records[key] = QuerierRecord(address: source, sourceMAC: sourceMAC, vlan: vlan,
                                         queryCount: 1, generalQueryCount: isGeneralQuery ? 1 : 0,
                                         firstSeen: timestamp, lastSeen: timestamp)
        }
    }

    public func reset() { records.removeAll() }

    /// Queriers heard from recently, loudest first.
    public func active(now: Double) -> [QuerierRecord] {
        records.values
            .filter { now - $0.lastSeen <= activeWindow }
            .sorted { lhs, rhs in
                lhs.queryCount == rhs.queryCount ? lhs.id < rhs.id : lhs.queryCount > rhs.queryCount
            }
    }

    /// `captureStarted` is when the capture began, so "no querier yet" is only
    /// reported once enough time has passed for one to have been expected.
    ///
    /// Queriers are judged one VLAN at a time. On a trunk or a mirror of one,
    /// every VLAN's querier shows up in the same capture, and counting them
    /// together would report a healthy network of ten VLANs as ten competing
    /// queriers.
    public func diagnostics(now: Double, captureStarted: Double?) -> [Diagnostic] {
        let current = active(now: now)

        if current.isEmpty {
            guard let captureStarted, now - captureStarted >= silenceGrace else { return [] }
            let elapsed = Int(now - captureStarted)
            return [Diagnostic(
                id: "querier.none",
                severity: .warning,
                title: "No IGMP querier heard in \(elapsed)s",
                detail: "With no querier, memberships age out and streams stop without anything "
                      + "appearing to change. Either no device is configured as querier on this VLAN, "
                      + "or this capture point cannot see its queries.")]
        }

        var byVLAN: [UInt16?: [QuerierRecord]] = [:]
        for record in current { byVLAN[record.vlan, default: []].append(record) }

        var contested: [(vlan: UInt16?, records: [QuerierRecord])] = []
        for (vlan, records) in byVLAN where records.count > 1 {
            contested.append((vlan, records.sorted { $0.queryCount > $1.queryCount }))
        }

        if !contested.isEmpty {
            contested.sort { ($0.vlan ?? 0) < ($1.vlan ?? 0) }
            let described = contested.map { entry -> String in
                let names = entry.records.map { record in
                    "\(record.displayName) (\(record.queryCount) quer\(record.queryCount == 1 ? "y" : "ies"))"
                }.joined(separator: ", ")
                let label = entry.vlan.map { "VLAN \($0)" } ?? "the untagged VLAN"
                return "\(label): \(names)"
            }.joined(separator: "; ")

            // A switch's snooping querier competing with a real router is the
            // common shape of this fault, and it has a specific fix, so say
            // that rather than the generic "pick one".
            var snoopingQuerierVLANs: [String] = []
            for entry in contested {
                let hasSwitchQuerier = entry.records.contains { $0.isAddresslessSwitch }
                let hasRouterQuerier = entry.records.contains { !$0.isAddresslessSwitch }
                if hasSwitchQuerier && hasRouterQuerier {
                    snoopingQuerierVLANs.append(entry.vlan.map { "VLAN \($0)" } ?? "the untagged VLAN")
                }
            }

            let advice: String
            if snoopingQuerierVLANs.isEmpty {
                advice = "Leave one device as querier on each of these VLANs and disable the rest."
            } else {
                advice = "On \(snoopingQuerierVLANs.joined(separator: " and ")) a switch is querying from "
                       + "0.0.0.0 while a router queries from its own address. The 0.0.0.0 sender is a "
                       + "switch's IGMP snooping querier, which exists to keep snooping working on a VLAN "
                       + "that has no multicast router. This VLAN has one, so the snooping querier is not "
                       + "needed here -- turn it off on that switch for this VLAN and let the router do it."
            }

            let worst = contested.map(\.records.count).max() ?? 2
            return [Diagnostic(
                id: "querier.multiple",
                severity: .critical,
                title: contested.count == 1
                    ? "\(worst) IGMP queriers on \(contested[0].vlan.map { "VLAN \($0)" } ?? "the untagged VLAN")"
                    : "Competing IGMP queriers on \(contested.count) VLANs",
                detail: "There must be exactly one querier per VLAN. Competing queriers flush membership "
                      + "tables unpredictably, which shows up as brief dropouts nobody can reproduce. "
                      + "\(described). \(advice)")]
        }

        // Exactly one per VLAN, which is what you want.
        if byVLAN.count == 1, let only = current.first {
            return [Diagnostic(
                id: "querier.single",
                severity: .info,
                title: "One IGMP querier: \(only.displayName)",
                detail: only.isAddresslessSwitch
                    ? "Exactly one querier, which is what you want. It sends from 0.0.0.0, so it is a "
                    + "switch acting as querier rather than a router. That is normal; it is tracked by "
                    + "its MAC address, so a second switch doing the same would still show up as two."
                    : "Exactly one querier, which is what you want.")]
        }

        let listed = current
            .sorted { ($0.vlan ?? 0) < ($1.vlan ?? 0) }
            .map { "\($0.vlanText): \($0.displayName)" }
            .joined(separator: ", ")
        return [Diagnostic(
            id: "querier.single",
            severity: .info,
            title: "One IGMP querier on each of \(byVLAN.count) VLANs",
            detail: "Exactly one querier per VLAN, which is what you want. \(listed).")]
    }
}
