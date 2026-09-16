import Foundation

/// Turns the once-a-second picture of "what is true now" into a timeline of
/// "what changed, and when".
///
/// This is the part that answers the question the whole app exists for: the
/// audio dropped out at 10:40 on Sunday and nobody could reproduce it at 2pm.
/// A live table cannot answer that; a record of transitions can.
public final class SessionLog {
    /// How often to write a rate sample even when nothing changed, so a dip in
    /// bandwidth is visible in the record.
    public var sampleInterval: Double
    /// In-memory ring for the UI. The file on disk keeps everything.
    public let capacity: Int
    /// A stream must be silent this long before its stop is recorded, so a
    /// momentarily idle stream does not produce a stop/start pair every second.
    public var streamStopGrace: Double

    private var events: [SessionEvent] = []
    private var nextIdentifier: UInt64 = 0
    private var activeFindings: [String: Diagnostic] = [:]
    private var knownStreams: [StreamKey: StreamIdentity] = [:]
    private var lastSampleAt: Double = -.greatestFiniteMagnitude
    private var lastQuerierSignature: String?
    private var lastDropCount: UInt32 = 0

    public init(capacity: Int = 2000, sampleInterval: Double = 10, streamStopGrace: Double = 0) {
        self.capacity = max(1, capacity)
        self.sampleInterval = sampleInterval
        self.streamStopGrace = streamStopGrace
    }

    public var recent: [SessionEvent] { events.reversed() }
    public var count: Int { events.count }

    public func reset() {
        events.removeAll()
        activeFindings.removeAll()
        knownStreams.removeAll()
        lastSampleAt = -.greatestFiniteMagnitude
        lastQuerierSignature = nil
        lastDropCount = 0
    }

    // MARK: - Recording

    @discardableResult
    public func begin(interface: String, sampleRate: Int, bufferMegabytes: Int, at now: Double) -> [SessionEvent] {
        reset()
        var fields = ["interface": interface, "buffer_mb": "\(bufferMegabytes)"]
        if sampleRate > 1 { fields["sample_rate"] = "1-in-\(sampleRate)" }
        return emit([SessionEvent(id: nextID(), timestamp: now, kind: .sessionStart,
                                  summary: "Capture started on \(interface)",
                                  detail: sampleRate > 1 ? "Sampled 1-in-\(sampleRate); counts are scaled up." : nil,
                                  fields: fields)])
    }

    @discardableResult
    public func end(at now: Double) -> [SessionEvent] {
        emit([SessionEvent(id: nextID(), timestamp: now, kind: .sessionEnd,
                           summary: "Capture stopped")])
    }

    /// Called once a second with the current picture. Returns only what is new.
    @discardableResult
    public func update(streams: [StreamSnapshot],
                       diagnostics: [Diagnostic],
                       queriers: [QuerierRecord],
                       totalBitsPerSecond: Double,
                       totalPacketsPerSecond: Double,
                       droppedPackets: UInt32,
                       at now: Double) -> [SessionEvent] {
        var produced: [SessionEvent] = []
        produced += findingTransitions(diagnostics, at: now)
        produced += streamTransitions(streams, at: now)
        produced += querierTransition(queriers, at: now)
        produced += dropTransition(droppedPackets, at: now)
        produced += periodicSample(streams: streams,
                                   totalBitsPerSecond: totalBitsPerSecond,
                                   totalPacketsPerSecond: totalPacketsPerSecond,
                                   at: now)
        return emit(produced)
    }

    // MARK: - Transitions

    private func findingTransitions(_ diagnostics: [Diagnostic], at now: Double) -> [SessionEvent] {
        var produced: [SessionEvent] = []
        var current: [String: Diagnostic] = [:]
        // Informational notes are the app agreeing that things are fine; they
        // would bury the record.
        for diagnostic in diagnostics where diagnostic.severity > .info {
            current[diagnostic.id] = diagnostic
        }

        for (id, diagnostic) in current {
            guard let existing = activeFindings[id] else {
                produced.append(SessionEvent(id: nextID(), timestamp: now, kind: .findingRaised,
                                             severity: diagnostic.severity,
                                             summary: diagnostic.title, detail: diagnostic.detail,
                                             fields: ["finding": id]))
                continue
            }
            // A finding whose wording changed is worth re-recording; one whose
            // wording is identical is the same ongoing condition.
            if existing.title != diagnostic.title {
                produced.append(SessionEvent(id: nextID(), timestamp: now, kind: .findingRaised,
                                             severity: diagnostic.severity,
                                             summary: diagnostic.title, detail: diagnostic.detail,
                                             fields: ["finding": id, "changed": "yes"]))
            }
        }

        for (id, diagnostic) in activeFindings where current[id] == nil {
            produced.append(SessionEvent(id: nextID(), timestamp: now, kind: .findingCleared,
                                         severity: .info,
                                         summary: "Cleared: \(diagnostic.title)",
                                         fields: ["finding": id]))
        }

        activeFindings = current
        return produced.sorted { $0.summary < $1.summary }
    }

    /// Discovery traffic is announcements, not streams: mDNS and SSDP go quiet
    /// between bursts and come back, so recording each one starting and
    /// stopping fills the record with churn and buries the one line that
    /// matters -- the moment the desk's audio flow stopped.
    static func hasLifecycleWorthRecording(_ identity: StreamIdentity) -> Bool {
        identity.family != .discovery
    }

    private func streamTransitions(_ streams: [StreamSnapshot], at now: Double) -> [SessionEvent] {
        var produced: [SessionEvent] = []
        var current: [StreamKey: StreamIdentity] = [:]
        for stream in streams where SessionLog.hasLifecycleWorthRecording(stream.identity) {
            current[stream.key] = stream.identity
        }

        for (key, identity) in current where knownStreams[key] == nil {
            produced.append(SessionEvent(id: nextID(), timestamp: now, kind: .streamAppeared,
                                         summary: "\(identity.displayText) started \u{2014} \(key.group):\(key.portText) from \(key.source)",
                                         fields: streamFields(key: key, identity: identity)))
        }

        for (key, identity) in knownStreams where current[key] == nil {
            // A stream leaving the table means it went silent past the timeout.
            // On an AV network that is usually the thing you came to find.
            produced.append(SessionEvent(id: nextID(), timestamp: now, kind: .streamStopped,
                                         severity: .warning,
                                         summary: "\(identity.displayText) stopped \u{2014} \(key.group):\(key.portText) from \(key.source)",
                                         fields: streamFields(key: key, identity: identity)))
        }

        knownStreams = current
        return produced.sorted { $0.summary < $1.summary }
    }

    private func streamFields(key: StreamKey, identity: StreamIdentity) -> [String: String] {
        var fields = [
            "group": key.group.description,
            "source": key.source.description,
            "port": key.portText,
            "protocol": identity.name,
        ]
        if let detail = identity.detail { fields["detail"] = detail }
        if let vlan = key.vlan { fields["vlan"] = String(vlan) }
        return fields
    }

    private func querierTransition(_ queriers: [QuerierRecord], at now: Double) -> [SessionEvent] {
        let signature = queriers.map(\.id).sorted().joined(separator: "|")
        defer { lastQuerierSignature = signature }
        guard let previous = lastQuerierSignature else { return [] }
        guard previous != signature else { return [] }

        let described = queriers
            .sorted { ($0.vlan ?? 0) < ($1.vlan ?? 0) }
            .map { "\($0.vlanText): \($0.displayName)" }
            .joined(separator: ", ")
        return [SessionEvent(id: nextID(), timestamp: now, kind: .querierChanged,
                             summary: queriers.isEmpty
                                ? "No queriers heard any more"
                                : "Queriers changed \u{2014} now \(described)",
                             fields: ["queriers": "\(queriers.count)"])]
    }

    private func dropTransition(_ dropped: UInt32, at now: Double) -> [SessionEvent] {
        defer { lastDropCount = dropped }
        guard dropped > lastDropCount else { return [] }
        let added = dropped - lastDropCount
        return [SessionEvent(id: nextID(), timestamp: now, kind: .captureDrops, severity: .warning,
                             summary: "Capture dropped \(added) more packets (\(dropped) total)",
                             detail: "Rates recorded around this time are understated.",
                             fields: ["dropped_total": "\(dropped)", "dropped_delta": "\(added)"])]
    }

    private func periodicSample(streams: [StreamSnapshot],
                                totalBitsPerSecond: Double,
                                totalPacketsPerSecond: Double,
                                at now: Double) -> [SessionEvent] {
        guard now - lastSampleAt >= sampleInterval else { return [] }
        lastSampleAt = now

        // Per group rather than per stream: a two-hour service with seventy
        // streams would otherwise be half a million lines, and the group is
        // the identifier you act on anyway.
        var byGroup: [IPv4Address: Double] = [:]
        for stream in streams { byGroup[stream.key.group, default: 0] += stream.bitsPerSecond }
        let ranked = byGroup.sorted { $0.value > $1.value }.prefix(12)

        var fields: [String: String] = [
            "total_bps": String(format: "%.0f", totalBitsPerSecond),
            "total_pps": String(format: "%.1f", totalPacketsPerSecond),
            "streams": "\(streams.count)",
        ]
        for (group, rate) in ranked {
            fields["g_\(group)"] = String(format: "%.0f", rate)
        }

        return [SessionEvent(id: nextID(), timestamp: now, kind: .sample,
                             summary: "\(streams.count) streams, \(Int(totalBitsPerSecond / 1000)) kbit/s",
                             fields: fields)]
    }

    // MARK: - Plumbing

    private func nextID() -> UInt64 {
        nextIdentifier += 1
        return nextIdentifier
    }

    private func emit(_ produced: [SessionEvent]) -> [SessionEvent] {
        guard !produced.isEmpty else { return [] }
        events.append(contentsOf: produced)
        if events.count > capacity { events.removeFirst(events.count - capacity) }
        return produced
    }
}
